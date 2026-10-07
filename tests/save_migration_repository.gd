extends SceneTree
## Repository-only migration boundaries. No App, actor, preferences or user://
## save directory is opened. All fixture writes use a unique OS-temp child.
const Repository = preload("res://rpg/save_repository.gd")
const Database = preload("res://combat/combat_database.gd")
const Quests = preload("res://rpg/quest_service.gd")
const State = preload("res://rpg/world_state.gd")
var workspace := ""
var checks := 0
var failures: Array[String] = []

class Context extends RefCounted:
	var careers: Dictionary
	var weapons: Dictionary
	var skills: Dictionary
	var passives: Dictionary
	var equipment: Dictionary
	var enemies: Dictionary
	var status_effects: Dictionary
	var actions: Dictionary
	var combat_feel: Dictionary
	var reactions: Dictionary
	var items: Dictionary
	var progression: Dictionary
	var worlds: Dictionary = {}
	var selected: Dictionary = {}
	var tamper_path := ""
	func _init(marker := "") -> void:
		for name in Database.CATALOGS:
			set(name, JSON.parse_string(FileAccess.get_file_as_string("res://data/combat/" + name + ".json")))
		for name in ["shops", "quests"]:
			worlds[name] = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/" + name + ".json"))
		if not marker.is_empty(): selected = {"bundle_sha256": marker.repeat(64)}
	func identity() -> Dictionary:
		if not tamper_path.is_empty():
			var file := FileAccess.open(tamper_path, FileAccess.WRITE)
			file.store_string("changed by read-race fixture")
			file.close()
			tamper_path = ""
		return selected.duplicate(true)
	func is_active() -> bool: return not selected.is_empty()
	func world_catalog(name: String) -> Dictionary: return worlds.get(name, {}).duplicate(true)

class InterleavedRepository extends Repository:
	var peer: RefCounted
	var peer_refused := false
	var late_target := ""
	var fail_write := false
	var corrupt_temp := false
	var written_temp := ""
	func _write_copy_file(path: String, envelope: String) -> String:
		written_temp = path
		if fail_write: return "deliberate isolated write failure"
		var reason := super._write_copy_file(path, envelope)
		if peer != null: peer_refused = not peer.create("并发写入", 1).ok
		if not late_target.is_empty():
			var file := FileAccess.open(late_target, FileAccess.WRITE)
			file.store_string("foreign slot bytes")
			file.close()
		if corrupt_temp:
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string("foreign temporary bytes")
			file.close()
		return reason

func _initialize() -> void: call_deferred("run")
func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func write_text(path: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.close()

func write_snapshot(path: String, snapshot: Dictionary) -> void:
	var payload := JSON.stringify(snapshot)
	write_text(path, JSON.stringify({"format": "mosslight_adventure", "version": snapshot.version, "payload_json": payload, "sha256": payload.sha256_text()}))

func complete_snapshot(seed: Dictionary, context: RefCounted) -> Dictionary:
	var snapshot := seed.duplicate(true)
	snapshot.created_at_local = "2025-01-02T03:04:05+08:00"
	snapshot.created_at_unix = 1735758245
	snapshot.saved_at_local = snapshot.created_at_local
	snapshot.saved_at_unix = snapshot.created_at_unix
	snapshot.loadout.level = 1
	snapshot.loadout.career_ids = ["warrior"]
	snapshot.loadout.learned_skills = ["warrior_thrust"]
	snapshot.loadout.sets[0] = {"weapon": "iron_longsword", "skills": ["warrior_thrust", "", ""]}
	snapshot.attributes = context.careers.warrior.stats.duplicate(true)
	snapshot.inventory.stacks = {"iron_longsword": 1, "healing_potion": 2}
	snapshot.inventory.quickslots = ["healing_potion", "", "", ""]
	snapshot.progression.starter_granted = true
	snapshot.progression.experience = 25
	snapshot.progression.enemy_kills = {"soldier": 1}
	snapshot.progression.claimed_rewards = {"old-receipt": true}
	snapshot.resources = {"HP": 17.0, "Stamina": 1.0, "Energy": 5.0}
	snapshot.combat = {"cooldowns": {"warrior_thrust": 1.0}, "stamina_clock": 0.4, "energy_clock": 0.2}
	var world := State.new()
	world.record_event("enemy_defeated", "soldier")
	world.set_object("quest.village_patrol", {"status": "rewarded", "baselines": {"clear_soldiers": 0}})
	world.set_object("quest.forest_investigation", {"status": "active", "baselines": {"break_guard": 0, "silence_ogre": 0}})
	world.set_flag("journal.tracked_quest", "forest_investigation")
	world.set_object("encounter.forest.heavy_guard_01", {"version": 1, "generation": 2, "phase": "pending", "remaining": 0.0})
	world.set_object("economy.wallet", {"version": 1, "balance": 73, "revision": 4})
	var stock: Dictionary = {}
	for id in context.worlds.shops.village_supply.goods: stock[id] = context.worlds.shops.village_supply.goods[id].stock
	stock.healing_potion = 3
	world.set_object("economy.shop.village_supply", {"version": 1, "catalog_version": int(context.worlds.shops.village_supply.catalog_version), "stock": stock})
	snapshot.world_state = world.export_state()
	return snapshot

func run() -> void:
	workspace = OS.get_temp_dir().path_join("mosslight-migration-repository-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var old := Context.new("a")
	verify(not Database.content_started(), "fixture begins before any global Database construction")
	var source := Repository.new(workspace.path_join("source"), old)
	verify(source.database == old and not Database.content_started(), "detached repository injects context without constructing or freezing global Database")
	var created: Dictionary = source.create("旧冒险", 0)
	verify(created.ok, "create isolated old-context snapshot: " + created.error)
	if not created.ok: finish(); return
	var snapshot := complete_snapshot(created.snapshot, old)
	verify(source.validate_snapshot(snapshot).is_empty(), "representative old snapshot validates with consumed stock, rewarded quest, pending encounter and injured resources: " + source.validate_snapshot(snapshot))
	if not source.validate_snapshot(snapshot).is_empty(): finish(); return
	var primary := source.directory.path_join("slot_01.json")
	var backup := primary + ".bak"
	write_snapshot(primary, snapshot)
	var backup_snapshot := snapshot.duplicate(true)
	backup_snapshot.inventory.stacks.healing_potion = 1
	write_snapshot(backup, backup_snapshot)
	var source_sha := FileAccess.get_sha256(primary)
	var backup_sha := FileAccess.get_sha256(backup)
	var read: Dictionary = source.read_verified_file(primary)
	verify(read.ok and read.file_sha256 == source_sha and read.snapshot.inventory.stacks.healing_potion == 2, "selected source is schema-verified and reports SHA of exact envelope bytes")
	var frozen := Database.new()
	var frozen_identity: Dictionary = frozen.identity()
	verify(source.read_verified_file(primary).ok and frozen.identity() == frozen_identity, "old context remains usable after target Database freezes without changing its identity")
	var target_context := Context.new("b")
	var target := Repository.new(workspace.path_join("target"), target_context)
	verify(not target.read_verified_file(primary).ok, "target identity cannot directly accept an unconverted old snapshot")
	var candidate := snapshot.duplicate(true)
	candidate.content_set = target_context.identity()
	var before := candidate.duplicate(true)
	var copied: Dictionary = target.create_copy(candidate, "  冒险副本  ", 7)
	verify(copied.ok and copied.slot == 7 and copied.snapshot.name == "冒险副本", "copy creates exactly the chosen empty target slot: " + copied.error)
	if copied.ok:
		for field in ["inventory", "progression", "loadout", "attributes", "resources", "combat", "world", "world_state", "race_id", "created_at_local", "created_at_unix"]:
			verify(copied.snapshot[field] == candidate[field], "copy preserves historical state without grants or normalization: " + field)
		verify(float(copied.snapshot.saved_at_unix) > float(candidate.saved_at_unix) and absf(float(copied.snapshot.saved_at_unix) - Time.get_unix_time_from_system()) < 5, "copy updates save timestamp while retaining original creation time")
		verify(target.load_slot(7).ok and not FileAccess.file_exists(target.directory.path_join("slot_08.json.bak")), "copy reads back from disk and creates no backup rotation")
		var copied_path: String = target.directory.path_join("slot_08.json")
		var copied_hash := FileAccess.get_sha256(copied_path)
		var next_save: Dictionary = copied.snapshot.duplicate(true)
		next_save.resources.HP = 16.0
		verify(target._commit(next_save).ok and FileAccess.get_sha256(copied_path + ".bak") == copied_hash and target.load_slot(7).snapshot.resources.HP == 16.0, "ordinary save still rotates the verified previous bytes under the shared directory lock")
		verify(not DirAccess.dir_exists_absolute(target.directory.path_join(".write-lock")), "ordinary save releases the same write lock after backup rotation")
	verify(candidate == before and FileAccess.get_sha256(primary) == source_sha and FileAccess.get_sha256(backup) == backup_sha, "copy leaves caller data, source primary and source backup byte-for-byte unchanged")
	verify(not target.create_copy(candidate, "重复槽", 7).ok and not target.create_copy(candidate, "冒险副本", 8).ok, "existing target and duplicate target name are rejected")
	_boundaries(source, target, candidate, primary, backup)
	_quest_checks(source, snapshot, old)
	_interleaved(candidate, target_context)
	verify(FileAccess.get_sha256(primary) == source_sha and FileAccess.get_sha256(backup) == backup_sha and frozen.identity() == frozen_identity, "all repository boundaries retain original source bytes and frozen global identity")
	finish()

func _boundaries(source: RefCounted, target: RefCounted, candidate: Dictionary, primary: String, backup: String) -> void:
	for suffix in [".bak", ".tmp"]:
		var occupied: String = target.directory.path_join("slot_04.json" + suffix)
		write_text(occupied, "existing reserved bytes")
		verify(not target.create_copy(candidate, "预留槽", 3).ok and FileAccess.get_file_as_string(occupied) == "existing reserved bytes", "backup/temp alone reserves a slot without being modified: " + suffix)
		DirAccess.remove_absolute(occupied)
	for suffix in ["", ".bak", ".tmp"]:
		var occupied: String = target.directory.path_join("slot_04.json" + suffix)
		DirAccess.make_dir_absolute(occupied)
		verify(not target.create_copy(candidate, "目录占用", 3).ok and DirAccess.dir_exists_absolute(occupied), "directories also reserve primary/backup/temp paths: " + suffix)
		DirAccess.remove_absolute(occupied)
	for name in ["", "../escape", "name:bad"]: verify(not target.create_copy(candidate, name, 2).ok, "invalid copy name rejected: " + name)
	for slot in [-2, 20]: verify(not target.create_copy(candidate, "越界", slot).ok, "invalid copy slot rejected: " + str(slot))
	var bad := candidate.duplicate(true)
	bad.inventory.stacks.unknown_item = 1
	verify(not target.create_copy(bad, "未知物品", 2).ok and not FileAccess.file_exists(target.directory.path_join("slot_03.json")), "invalid target state fails before creating a slot")
	verify(not source.read_verified_file("relative.json").ok, "source reader requires an explicit absolute path")
	var corrupt := workspace.path_join("corrupt.json")
	write_text(corrupt, "{truncated")
	write_text(corrupt + ".bak", FileAccess.get_file_as_string(primary))
	verify(not source.read_verified_file(corrupt).ok and FileAccess.get_file_as_string(corrupt) == "{truncated", "selected corrupt primary is not silently replaced or repaired using its backup")
	verify(source.read_verified_file(backup).ok and source.read_verified_file(backup).snapshot.inventory.stacks.healing_potion == 1, "an explicitly chosen verified backup remains readable")
	var race_path := workspace.path_join("changed-during-read.json")
	write_text(race_path, FileAccess.get_file_as_string(primary))
	source.database.tamper_path = race_path
	verify(not source.read_verified_file(race_path).ok, "source mutation between byte capture and semantic validation is rejected")
	var v4: Dictionary = source.read_verified_file(primary).snapshot
	v4.version = 4
	v4.erase("content_set")
	var builtin_context := Context.new()
	var legacy_repo := Repository.new(workspace.path_join("legacy"), builtin_context)
	var migrated: Dictionary = legacy_repo.migrate_snapshot(v4)
	verify(migrated.ok and migrated.snapshot.version == 5 and migrated.snapshot.content_set.is_empty(), "existing schema v4-to-v5 builtin migration remains supported")
	var full := Repository.new(workspace.path_join("full"), target.database)
	for index in range(Repository.SLOT_COUNT): write_text(full.directory.path_join("slot_%02d.json.tmp" % (index + 1)), "reserved")
	verify(not full.create_copy(candidate, "没有空槽").ok and not DirAccess.dir_exists_absolute(full.directory.path_join(".write-lock")), "twenty occupied backup/temp slots reject automatic copy selection before acquiring a write lock")

func _quest_checks(repository: RefCounted, snapshot: Dictionary, context: RefCounted) -> void:
	verify(Quests.validate_snapshot(snapshot.world_state, context).is_empty(), "pure quest validation accepts actual completed and active records without actors")
	var bad := snapshot.duplicate(true)
	bad.world_state.objects["quest.missing"] = {"status": "active", "baselines": {}}
	verify(not repository.validate_snapshot(bad).is_empty(), "repository now rejects unknown quest records before restore")
	bad = snapshot.duplicate(true)
	bad.world_state.counters.clear()
	verify(not repository.validate_snapshot(bad).is_empty(), "rewarded quest cannot omit its required completion event")
	bad = snapshot.duplicate(true)
	bad.world_state.objects["quest.forest_investigation"].baselines.break_guard = 4
	verify(not repository.validate_snapshot(bad).is_empty(), "future event baselines are rejected through standalone repository validation")
	var legacy := State.new()
	legacy.record_event("enemy_defeated", "soldier", 2)
	legacy.set_object("quest.village_patrol", {"status": "rewarded", "baselines": {"clear_soldiers": 1}})
	verify(Quests.validate_snapshot(legacy.export_state(), context).is_empty(), "pure quest validator retains historical patrol nonzero-baseline compatibility")

func _interleaved(candidate: Dictionary, context: RefCounted) -> void:
	var folder := workspace.path_join("interleaved")
	var guarded := InterleavedRepository.new(folder, context)
	guarded.peer = Repository.new(folder, context)
	verify(guarded.create_copy(candidate, "锁保护副本", 0).ok and guarded.peer_refused, "normal create cannot bypass another repository's active copy write lock")
	verify(not DirAccess.dir_exists_absolute(folder.path_join(".write-lock")), "successful transaction releases its own directory lock")
	var late := InterleavedRepository.new(workspace.path_join("late-slot"), context)
	late.late_target = late.directory.path_join("slot_01.json")
	verify(not late.create_copy(candidate, "晚到目标", 0).ok and FileAccess.get_file_as_string(late.late_target) == "foreign slot bytes", "slot appearing during readback is never overwritten")
	verify(not FileAccess.file_exists(late.written_temp), "failed occupied-slot publish removes only its exact owned temporary payload")
	var fault := InterleavedRepository.new(workspace.path_join("write-failure"), context)
	fault.fail_write = true
	verify(not fault.create_copy(candidate, "写失败", 0).ok and not FileAccess.file_exists(fault.directory.path_join("slot_01.json")), "write failure publishes no target")
	verify(not DirAccess.dir_exists_absolute(fault.directory.path_join(".write-lock")), "write failure releases owned lock for retry")
	var damaged := InterleavedRepository.new(workspace.path_join("foreign-temp"), context)
	damaged.corrupt_temp = true
	verify(not damaged.create_copy(candidate, "坏临时文件", 0).ok and FileAccess.get_file_as_string(damaged.written_temp) == "foreign temporary bytes", "failed readback cannot delete temporary bytes replaced by another writer")
	var busy := Repository.new(workspace.path_join("foreign-lock"), context)
	write_text(busy.directory.path_join(".write-lock/owner"), "another writer")
	verify(not busy.create_copy(candidate, "已有锁", 0).ok and FileAccess.get_file_as_string(busy.directory.path_join(".write-lock/owner")) == "another writer", "pre-existing lock is neither acquired nor removed")

func finish() -> void:
	print("SAVE MIGRATION REPOSITORY: %d/%d" % [checks - failures.size(), checks])
	print("ISOLATED FIXTURES: " + workspace)
	for failure in failures: push_error(failure)
	quit(1 if not failures.is_empty() else 0)
