extends "res://tests/content_bundle.gd"
## Bundle-boundary checks: authenticated bytes, derived snapshots and all-or-none
## activation. Fixture files use OS-temp; no user preferences or saves are opened.

func run() -> void:
	temp_root = OS.get_temp_dir().path_join("mosslight-acquisition-bundle-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	verify(DirAccess.make_dir_absolute(temp_root) == OK, "create exclusive acquisition fixture directory")
	source = fixture()
	if source.is_empty():
		finish()
		return
	var legacy: Dictionary = Bundle.load_directory(write_case(source))
	verify(legacy.ok and legacy.bundle.world_catalogs().has("shops") and legacy.bundle.world_catalogs().has("quests"), "legacy bundle inherits complete world definitions")
	var item := "runtime_test:tonic"
	var world_hashes: Dictionary = {}
	for name: String in Bundle.WORLD_CATALOGS:
		world_hashes[name] = Bundle.digest(FileAccess.get_file_as_bytes("res://data/world/" + name + ".json"))
	source.manifest["acquisition"] = {"format_version": 1, "world_base_sha256": world_hashes,
		"shops": {"village_supply": {item: {"stock": 6, "buy_price": 30, "sell_price": 8}}},
		"quests": {"village_patrol": {item: 1}}, "enemy_drops": {"heavy_guard": {item: 1}}}
	var path := write_case(source)
	var loaded: Dictionary = Bundle.load_directory(path)
	verify(loaded.ok, "acquisition bundle validates: " + loaded.error)
	if not loaded.ok:
		finish()
		return
	var bundle: RefCounted = loaded.bundle
	verify(not source.catalogs.progression.heavy_guard.drops.has(item), "raw catalogs retain base drops without preapplying extension")
	verify(bundle.catalogs().progression.heavy_guard.drops[item] == 1, "compiled acquisition derives one enemy drop")
	verify(bundle.world_catalogs().shops.village_supply.goods[item].stock == 6 and bundle.world_catalogs().quests.village_patrol.rewards.items[item] == 1, "world snapshot contains shop and quest acquisition")
	verify(bundle.catalogs().progression.heavy_guard.experience == source.catalogs.progression.heavy_guard.experience and bundle.catalogs().progression.heavy_guard.equipment_rotation == source.catalogs.progression.heavy_guard.equipment_rotation, "enemy XP and original rotation stay intact")
	var repeated: Dictionary = Bundle.load_directory(path)
	verify(repeated.ok and repeated.bundle.catalogs() == bundle.catalogs() and repeated.bundle.world_catalogs() == bundle.world_catalogs(), "repeated load cannot apply additive drops twice")
	var detached: Dictionary = bundle.world_catalogs()
	detached.shops.village_supply.goods[item].stock = 999
	detached.quests.clear()
	verify(bundle.world_catalogs().shops.village_supply.goods[item].stock == 6 and not bundle.world_catalogs().quests.is_empty(), "world definitions are detached deep copies")

	reject("non-object acquisition", func(m: Dictionary): m.manifest.acquisition = [])
	reject("unsupported acquisition version", func(m: Dictionary): m.manifest.acquisition.format_version = 2)
	reject("boolean acquisition version", func(m: Dictionary): m.manifest.acquisition.format_version = true)
	reject("unknown acquisition field", func(m: Dictionary): m.manifest.acquisition.inject = {})
	reject("missing world fingerprint", func(m: Dictionary): m.manifest.acquisition.world_base_sha256.erase("quests"))
	reject("unknown world fingerprint", func(m: Dictionary): m.manifest.acquisition.world_base_sha256.enemies = "a".repeat(64))
	reject("wrong world fingerprint", func(m: Dictionary): m.manifest.acquisition.world_base_sha256.shops = "0".repeat(64))
	reject("invalid fingerprint type", func(m: Dictionary): m.manifest.acquisition.world_base_sha256.quests = 3)
	reject("unknown merchant", func(m: Dictionary): m.manifest.acquisition.shops = {"missing": {item: {"stock": 1, "buy_price": 30}}})
	reject("unknown quest", func(m: Dictionary): m.manifest.acquisition.quests = {"missing": {item: 1}})
	reject("unknown enemy", func(m: Dictionary): m.manifest.acquisition.enemy_drops = {"missing": {item: 1}})
	reject("foreign namespace", func(m: Dictionary): m.manifest.acquisition.quests.village_patrol = {"missing:tonic": 1})
	reject("base item override", func(m: Dictionary): m.manifest.acquisition.quests.village_patrol = {"healing_potion": 10})
	reject("fractional reward", func(m: Dictionary): m.manifest.acquisition.enemy_drops.heavy_guard[item] = 1.5)
	reject("boolean reward", func(m: Dictionary): m.manifest.acquisition.quests.village_patrol[item] = true)
	reject("arbitrage", func(m: Dictionary): m.manifest.acquisition.shops.village_supply[item].sell_price = 31)
	reject("empty acquisition", func(m: Dictionary):
		m.manifest.acquisition.shops = {}
		m.manifest.acquisition.quests = {}
		m.manifest.acquisition.enemy_drops = {})

	var selected := Database.configure_content_bundle(path)
	verify(selected.ok, "valid acquisition selects one immutable content identity")
	var broken: Dictionary = source.duplicate(true)
	broken.manifest.acquisition.world_base_sha256.quests = "0".repeat(64)
	verify(not Database.configure_content_bundle(write_case(broken)).ok, "failed later selection cannot publish invalid acquisition")
	var db := Database.new()
	var second := Database.new()
	verify(db.identity() == selected.identity and second.identity() == selected.identity and db.errors.is_empty(), "all databases retain successful identity after rejection")
	var shop_copy := db.world_catalog("shops")
	shop_copy.village_supply.goods[item].stock = 0
	db.progression.heavy_guard.drops[item] = 2
	verify(db.world_catalog("shops").village_supply.goods[item].stock == 6 and second.progression.heavy_guard.drops[item] == 1, "database world queries and combat instances remain independent")
	write_bytes(path.path_join("bundle.json"), "{}".to_utf8_buffer())
	verify(second.world_catalog("quests").village_patrol.rewards.items[item] == 1 and second.progression.heavy_guard.drops[item] == 1, "selected world and drop snapshot survive source mutation")
	verify(not Database.configure_content_bundle(path).ok, "constructed acquisition database rejects hot replacement")
	print("ACQUISITION_BUNDLE")
	finish()
