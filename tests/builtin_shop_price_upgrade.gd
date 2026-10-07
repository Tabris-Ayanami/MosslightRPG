extends SceneTree
## Repository-only compatibility checks. No App, global Database construction,
## preferences or user save directory; all disk fixtures live in unique OS temp.
const Repository = preload("res://rpg/save_repository.gd")
const Source = preload("res://rpg/save_source_context.gd")
const Bundle = preload("res://rpg/content_bundle.gd")
const Database = preload("res://combat/combat_database.gd")
const Release = preload("res://rpg/content_release.gd")
const State = preload("res://rpg/world_state.gd")
const SHOP := "economy.shop.village_supply"
const WALLET := "economy.wallet"
var temporary_root := ""
var checks := 0
var failures: Array[String] = []
var catalogs: Dictionary = {}
var current_worlds: Dictionary = {}
var old_worlds: Dictionary = {}

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	temporary_root = OS.get_temp_dir().path_join("mosslight-builtin-price-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	for name: String in Bundle.CATALOGS:
		catalogs[name] = JSON.parse_string(FileAccess.get_file_as_string("res://data/combat/" + name + ".json"))
	for name: String in ["shops", "quests"]:
		current_worlds[name] = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/" + name + ".json"))
	var historical := Bundle.source_world_data("shops", Bundle.LEGACY_SHOPS_V1_SHA)
	verify(historical.ok, "fixed historical shops baseline is readable")
	if not historical.ok: finish(); return
	old_worlds = current_worlds.duplicate(true)
	old_worlds.shops = historical.data
	var old_context: RefCounted = Source.from_catalogs(catalogs, old_worlds, {})
	var current_context: RefCounted = Source.from_catalogs(catalogs, current_worlds, {})
	var old := Repository.new(temporary_root.path_join("adventures"), old_context)
	var current := Repository.new(old.directory, current_context)
	var created: Dictionary = old.create("价格升级旧冒险", 0)
	verify(created.ok, "isolated historical repository creates a valid adventure")
	if not created.ok: finish(); return
	var snapshot := populated_snapshot(created.snapshot, old_context)
	verify(old.validate_snapshot(snapshot).is_empty(), "historical snapshot validates with purchased stock, hurt resources and rewarded quest")
	if not old.validate_snapshot(snapshot).is_empty(): finish(); return
	verify(not current.validate_snapshot(snapshot).is_empty(), "current strict validator alone rejects shop catalog v1")
	var frozen := snapshot.duplicate(true)
	var result: Dictionary = current.migrate_snapshot(snapshot)
	verify(result.ok, "ordinary in-memory migration accepts known builtin v1-to-v2 prices: " + str(result.error))
	if not result.ok: finish(); return
	var expected := snapshot.duplicate(true)
	expected.world_state.objects[SHOP].catalog_version = 2
	verify(same(result.snapshot, expected), "only the stored shop catalog_version changes")
	verify(same(snapshot, frozen), "migration does not mutate the caller's snapshot")
	for field: String in ["inventory", "progression", "loadout", "attributes", "resources", "combat", "world", "created_at_local", "created_at_unix", "saved_at_local", "saved_at_unix"]:
		verify(same(result.snapshot[field], snapshot[field]), "migration preserves " + field)
	verify(same(result.snapshot.world_state.objects[WALLET], snapshot.world_state.objects[WALLET]), "wallet balance and revision are unchanged; no historical price refund")
	verify(same(result.snapshot.world_state.objects[SHOP].stock, snapshot.world_state.objects[SHOP].stock), "remaining stock stays consumed without refill")
	verify(result.snapshot.world_state.objects["quest.village_patrol"].status == "rewarded" and same(result.snapshot.world_state.counters, snapshot.world_state.counters), "rewarded quest and encounter counters do not replay")
	verify(current.validate_snapshot(result.snapshot).is_empty(), "upgraded snapshot passes the complete target validator")
	verify(same(current.migrate_snapshot(result.snapshot).snapshot, result.snapshot), "upgrade is idempotent")
	verify(same(old.migrate_snapshot(snapshot).snapshot, snapshot), "detached old v1 context keeps old record and prices unchanged")
	var schema4 := snapshot.duplicate(true)
	schema4.version = 4
	schema4.erase("content_set")
	verify(same(current.migrate_snapshot(schema4).snapshot, expected), "existing schema v4 builtin upgrade composes with the known price correction")
	var no_record := snapshot.duplicate(true)
	no_record.world_state.objects.erase(SHOP)
	no_record.world_state.objects.erase(WALLET)
	var no_record_result: Dictionary = current.migrate_snapshot(no_record)
	verify(no_record_result.ok and same(no_record_result.snapshot, no_record), "unvisited shop does not create a wallet or stock record")
	_disk_roundtrip(old, current, snapshot, expected)
	_negative_snapshots(current, snapshot)
	_target_boundaries(snapshot)
	_identity_boundaries(snapshot)
	verify(not Database.content_started() and not Release.is_active(), "all tests leave global Database and ContentRelease inactive")
	finish()

func populated_snapshot(seed: Dictionary, context: RefCounted) -> Dictionary:
	var snapshot := seed.duplicate(true)
	snapshot.loadout.level = 1
	snapshot.loadout.career_ids = ["warrior"]
	snapshot.loadout.learned_skills = ["warrior_thrust"]
	snapshot.loadout.sets[0] = {"weapon": "iron_longsword", "skills": ["warrior_thrust", "", ""]}
	snapshot.attributes = context.careers.warrior.stats.duplicate(true)
	snapshot.inventory.stacks = {"iron_longsword": 1, "healing_potion": 3, "spell_potion": 2}
	snapshot.inventory.quickslots = ["healing_potion", "spell_potion", "", ""]
	snapshot.progression.starter_granted = true
	snapshot.progression.experience = 25
	snapshot.progression.enemy_kills = {"soldier": 1}
	snapshot.progression.claimed_rewards = {"historical-receipt": true}
	snapshot.resources = {"HP": 17.0, "Stamina": 1.0, "Energy": 5.0}
	snapshot.combat = {"cooldowns": {"warrior_thrust": 1.0}, "stamina_clock": 0.4, "energy_clock": 0.2}
	var world := State.new()
	world.record_event("enemy_defeated", "soldier")
	world.set_object("quest.village_patrol", {"status": "rewarded", "baselines": {"clear_soldiers": 0}})
	world.set_object("quest.forest_investigation", {"status": "active", "baselines": {"break_guard": 0, "silence_ogre": 0}})
	world.set_flag("journal.tracked_quest", "forest_investigation")
	world.set_object("encounter.forest.heavy_guard_01", {"version": 1, "generation": 2, "phase": "pending", "remaining": 0.0})
	world.set_object(WALLET, {"version": 1, "balance": 73, "revision": 4})
	var stock: Dictionary = {}
	for id: String in context.world_catalog("shops").village_supply.goods:
		stock[id] = context.world_catalog("shops").village_supply.goods[id].stock
	stock.spell_potion = 6
	stock.healing_potion = 3
	world.set_object(SHOP, {"version": 1, "catalog_version": 1, "stock": stock})
	snapshot.world_state = world.export_state()
	return snapshot

func _disk_roundtrip(old: RefCounted, current: RefCounted, snapshot: Dictionary, expected: Dictionary) -> void:
	verify(old._commit(snapshot).ok, "ordinary historical save writes the old-price adventure")
	var primary: String = old.directory.path_join("slot_01.json")
	var backup := primary + ".bak"
	var primary_hash := FileAccess.get_sha256(primary)
	var backup_hash := FileAccess.get_sha256(backup)
	var read: Dictionary = current.read_verified_file(primary)
	verify(read.ok and read.file_sha256 == primary_hash and same(read.snapshot, expected), "verified read reports source byte hash while returning the upgraded copy")
	var loaded: Dictionary = current.load_slot(0)
	verify(loaded.ok and same(loaded.snapshot, expected), "ordinary load_slot sees the same upgraded state")
	verify(current.slot(0).valid and current.list_slots()[0].valid, "slot metadata and complete slot listing accept the old builtin adventure")
	verify(FileAccess.get_sha256(primary) == primary_hash and FileAccess.get_sha256(backup) == backup_hash, "read/list leave primary and backup byte-for-byte untouched")
	verify(_disk_snapshot(primary).world_state.objects[SHOP].catalog_version == 1, "on-disk primary remains v1 until an explicit ordinary save")
	verify(current._commit(loaded.snapshot).ok, "ordinary save persists the already upgraded live snapshot")
	verify(FileAccess.get_sha256(backup) == primary_hash, "ordinary save backs up the exact old v1 primary bytes")
	verify(_disk_snapshot(primary).world_state.objects[SHOP].catalog_version == 2 and _disk_snapshot(backup).world_state.objects[SHOP].catalog_version == 1, "normal backup rotation retains the historical record version")
	var fresh := Repository.new(current.directory, current.database)
	verify(same(fresh.load_slot(0).snapshot, expected), "fresh repository reload preserves inventory, wallet and resource values")
	verify(current.read_verified_file(backup).ok and same(current.read_verified_file(backup).snapshot, expected), "read-only backup inspection upgrades in memory without rewriting its v1 bytes")
	var damaged := snapshot.duplicate(true)
	damaged.slot = 1
	damaged.world_state.objects[SHOP].stock.spell_potion = 9
	var damaged_path: String = old.directory.path_join("slot_02.json")
	_write_snapshot(damaged_path, damaged)
	var damaged_hash := FileAccess.get_sha256(damaged_path)
	verify(not current.read_verified_file(damaged_path).ok and not current.load_slot(1).ok and not current.slot(1).valid, "correctly signed but invalid historical stock is rejected through every read entry point")
	verify(FileAccess.get_sha256(damaged_path) == damaged_hash and FileAccess.get_sha256(backup) == primary_hash, "failed reads neither repair corrupt data nor alter historical backup")

func _negative_snapshots(repository: RefCounted, original: Dictionary) -> void:
	var cases := [
		[["world_state", "objects", SHOP, "catalog_version"], 0, "unknown zero catalog version"],
		[["world_state", "objects", SHOP, "catalog_version"], 3, "unknown future catalog version"],
		[["world_state", "objects", SHOP, "catalog_version"], true, "boolean catalog version"],
		[["world_state", "objects", SHOP, "version"], 2, "invalid shop record version"],
		[["world_state", "objects", SHOP, "stock", "spell_potion"], 9, "stock exceeds historical capacity"],
		[["world_state", "objects", SHOP, "stock", "spell_potion"], -1, "negative historical stock"],
		[["world_state", "objects", SHOP, "stock", "spell_potion"], true, "boolean historical stock"],
		[["world_state", "objects", SHOP, "stock", "unknown_item"], 0, "unknown stock item"],
		[["world_state", "objects", WALLET, "balance"], -1, "invalid old wallet balance"],
		[["world_state", "objects", WALLET, "revision"], 2147483648, "overflowed old wallet revision"],
		[["world_state", "objects", "economy.unknown"], {}, "unknown economy record"],
		[["inventory", "stacks", "unknown_item"], 1, "unrelated invalid inventory"],
		[["resources", "HP"], -1, "unrelated invalid resource"],
		[["progression", "experience"], -1, "unrelated invalid progression"],
		[["content_set"], [], "malformed content identity"],
		[["world_state", "objects", SHOP], [], "malformed shop record"],
	]
	for entry: Array in cases:
		var candidate := original.duplicate(true)
		_set_path(candidate, entry[0], entry[1])
		var before := candidate.duplicate(true)
		verify(not repository.migrate_snapshot(candidate).ok and same(candidate, before), "reject without repairing: " + str(entry[2]))
	for path: Array in [["world_state", "objects", WALLET], ["world_state", "objects", SHOP, "stock", "spell_potion"], ["world_state", "objects", SHOP, "stock"]]:
		var candidate := original.duplicate(true)
		_erase_path(candidate, path)
		verify(not repository.migrate_snapshot(candidate).ok, "missing historical field remains invalid: " + str(path))

func _target_boundaries(snapshot: Dictionary) -> void:
	var cases := [
		[["shops", "village_supply", "goods", "spell_potion", "buy_price"], 16, "unregistered new buy price"],
		[["shops", "village_supply", "goods", "spell_potion", "sell_price"], 5, "unregistered new sell price"],
		[["shops", "village_supply", "goods", "spell_potion", "stock"], 9, "changed shelf capacity"],
		[["shops", "village_supply", "goods", "healing_potion", "buy_price"], 19, "changed other item price"],
		[["shops", "village_supply", "name"], "另一商店", "changed shop metadata"],
		[["shops", "village_supply", "catalog_version"], 3, "unregistered target catalog version"],
	]
	for entry: Array in cases:
		var worlds := current_worlds.duplicate(true)
		_set_path(worlds, entry[0], entry[1])
		var repository := Repository.new(temporary_root.path_join("target-boundary"), Source.from_catalogs(catalogs, worlds, {}))
		verify(not repository.migrate_snapshot(snapshot).ok, "no implicit migration for " + str(entry[2]))
	var fewer_directions := current_worlds.duplicate(true)
	fewer_directions.shops.village_supply.goods.spell_potion.erase("sell_price")
	var repository := Repository.new(temporary_root.path_join("direction-boundary"), Source.from_catalogs(catalogs, fewer_directions, {}))
	verify(not repository.migrate_snapshot(snapshot).ok, "changed trading direction requires explicit content migration")

func _identity_boundaries(snapshot: Dictionary) -> void:
	var identity := {"bundle_sha256": "a".repeat(64)}
	var external_source := snapshot.duplicate(true)
	external_source.content_set = identity.duplicate(true)
	var external_target := Repository.new(temporary_root.path_join("external-target"), Source.from_catalogs(catalogs, current_worlds, identity))
	verify(not external_target.migrate_snapshot(external_source).ok, "matching nonempty identities cannot silently change old shop versions")
	verify(not external_target.migrate_snapshot(snapshot).ok, "builtin source cannot silently adopt external target content")
	var builtin := Repository.new(temporary_root.path_join("builtin-target"), Source.from_catalogs(catalogs, current_worlds, {}))
	verify(not builtin.migrate_snapshot(external_source).ok, "external source cannot silently become builtin")
	var external_old := Repository.new(temporary_root.path_join("external-old"), Source.from_catalogs(catalogs, old_worlds, identity))
	verify(same(external_old.migrate_snapshot(external_source).snapshot, external_source), "matching historical external context retains its own v1 catalog")

func _set_path(value: Dictionary, path: Array, replacement: Variant) -> void:
	var parent := value
	for index in range(path.size() - 1): parent = parent[path[index]]
	parent[path.back()] = replacement

func _erase_path(value: Dictionary, path: Array) -> void:
	var parent := value
	for index in range(path.size() - 1): parent = parent[path[index]]
	parent.erase(path.back())

func _write_snapshot(path: String, snapshot: Dictionary) -> void:
	var payload := JSON.stringify(snapshot)
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "isolated fixture path must be writable")
	file.store_string(JSON.stringify({"format": "mosslight_adventure", "version": snapshot.version, "payload_json": payload, "sha256": payload.sha256_text()}))
	file.close()

func _disk_snapshot(path: String) -> Dictionary:
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	return JSON.parse_string(envelope.payload_json)

func same(left: Variant, right: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))

func verify(condition: bool, description: String) -> void:
	checks += 1
	print("PASS " if condition else "FAIL ", description)
	if not condition: failures.append(description)

func finish() -> void:
	print("TEMP_FIXTURES ", temporary_root)
	print("BUILTIN_SHOP_PRICE_UPGRADE %d/%d" % [checks - failures.size(), checks])
	for failure: String in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
