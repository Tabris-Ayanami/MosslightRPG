extends SceneTree
## Real actor + isolated disk envelopes; never reads or writes user adventures.
const Repository = preload("res://rpg/save_repository.gd")
const Races = preload("res://rpg/race_catalog.gd")
const WorldState = preload("res://rpg/world_state.gd")
var game: Node
var actor: Node
var checks := 0
var failures: Array[String] = []
var workspace := ""

func _initialize() -> void:
	preload("res://rpg/game_preferences.gd").settings_path = OS.get_temp_dir().path_join("mosslight-race-prefs-%d.cfg" % OS.get_process_id())
	call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func same_json(a: Dictionary, b: Dictionary) -> bool:
	# JSON parses numbers as floats and erases typed Array annotations. Compare
	# serialized meaning, while rejection checks above compare live values exactly.
	return JSON.parse_string(JSON.stringify(a)) == JSON.parse_string(JSON.stringify(b))
func write_snapshot(path: String, snapshot: Dictionary) -> void:
	var payload := JSON.stringify(snapshot)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"format": "mosslight_adventure", "version": snapshot.version, "payload_json": payload, "sha256": payload.sha256_text()}))
	file.close()
func state() -> Dictionary:
	var resources := {}
	for id in Repository.RESOURCES: resources[id] = actor.resources.current(id)
	return {"race_id": actor.race_id, "name": actor.display_name, "inventory": actor.inventory.export_state(),
		"progression": actor.progression.export_state(), "loadout": actor.loadout.export_state(),
		"attributes": actor.stats.base.duplicate(true), "position": actor.global_position,
		"resources": resources, "world_state": game.world_state.export_state(), "combat": actor.combat.state}
func unchanged_rejection(repository: RefCounted, snapshot: Dictionary, label: String) -> void:
	var before := state()
	var result: Dictionary = repository.restore(snapshot, actor, game)
	check(not result.ok and not result.error.is_empty() and state() == before, label)

func run() -> void:
	workspace = OS.get_temp_dir().path_join("mosslight-race-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var repository := Repository.new(workspace)
	var created: Dictionary = repository.create("种族身份回归")
	check(created.ok and created.snapshot.version == Repository.VERSION and created.snapshot.race_id == Races.DEFAULT_ID, "new current-version adventure explicitly stores human identity")
	check(Races.IDS.size() == 12 and Races.is_valid("human") and Races.is_valid("giant") and Races.options().size() == 12, "identity catalog exposes twelve valid choices including giant and human default")
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(20)
	actor = game.player
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	actor.set_physics_process(false)
	check(actor.race_id == "human", "actual protagonist starts with human identity")
	check(actor.progression.choose_career("warrior") and actor.progression.grant_trait("azure_edge", "测试祝福", "祝福") and actor.progression.learn_skill("warrior_thrust") and actor.loadout.assign_skill(0, 0, "warrior_thrust"), "fixture uses real learned progression, prepared skill and an acquired trait")
	game.world_state.set_flag("village.gate_open", true)
	game.world_state.set_object("chest.race_regression", {"opened": true, "loot": ["healing_potion", 2]})
	game.world_state.record_event("enemy_defeated", "soldier", 2, "race-regression-event")
	var expected_world: Dictionary = game.world_state.export_state()
	var expected_growth: Dictionary = actor.progression.export_state()
	var expected_inventory: Dictionary = actor.inventory.export_state()
	var expected_loadout: Dictionary = actor.loadout.export_state()
	var populated: Dictionary = {}
	for id in Races.IDS:
		actor.race_id = id
		var saved: Dictionary = repository.save(0, "种族身份回归", actor, game)
		var loaded: Dictionary = Repository.new(workspace).load_slot(0)
		actor.race_id = "human" if id != "human" else Races.IDS[1]
		var restored: Dictionary = repository.restore(loaded.get("snapshot", {}), actor, game)
		check(saved.ok and loaded.ok and restored.ok and actor.race_id == id and loaded.snapshot.race_id == id, "disk save/load/restore preserves catalog identity: " + id)
		populated = loaded.snapshot.duplicate(true)
	check(same_json(game.world_state.export_state(), expected_world) and same_json(actor.progression.export_state(), expected_growth) and same_json(actor.inventory.export_state(), expected_inventory) and same_json(actor.loadout.export_state(), expected_loadout), "twelve identity roundtrips preserve world facts, acquired traits, owned inventory and prepared skills")
	var valid_bytes := FileAccess.get_file_as_bytes(workspace.path_join("slot_01.json"))
	actor.race_id = "unknown_race"
	var rejected_save: Dictionary = repository.save(0, "种族身份回归", actor, game)
	check(not rejected_save.ok and FileAccess.get_file_as_bytes(workspace.path_join("slot_01.json")) == valid_bytes, "saving unknown actor identity refuses before touching the valid disk file")
	actor.race_id = "human"
	for invalid in ["", "Human", "human ", "unknown_race", null, 0, [], {}]:
		var bad := populated.duplicate(true)
		bad.race_id = invalid
		unchanged_rejection(repository, bad, "invalid race rejects atomically: " + JSON.stringify(invalid))
	var missing := populated.duplicate(true)
	missing.erase("race_id")
	unchanged_rejection(repository, missing, "current version cannot silently default a missing identity")
	for version in [1, 2, 3]:
		var legacy := populated.duplicate(true)
		legacy.version = version
		legacy.erase("content_set")
		legacy.slot = version
		legacy.resources = {"HP": populated.resources.HP, "Stamina": populated.resources.Stamina,
			"Qi": populated.resources.Energy / 20.0, "SpellSlot": 0.0}
		if version < 3: legacy.erase("race_id")
		if version == 1: legacy.erase("world_state")
		var expected_race: String = str(populated.race_id) if version == 3 else "human"
		var legacy_before := legacy.duplicate(true)
		var path := workspace.path_join("slot_%02d.json" % (version + 1))
		write_snapshot(path, legacy)
		var old_bytes := FileAccess.get_file_as_bytes(path)
		var migrated: Dictionary = repository.migrate_snapshot(legacy)
		var loaded: Dictionary = Repository.new(workspace).load_slot(version)
		check(migrated.ok and loaded.ok and loaded.snapshot.version == Repository.VERSION and loaded.snapshot.race_id == expected_race and is_equal_approx(loaded.snapshot.resources.Energy, populated.resources.Energy) and legacy == legacy_before and FileAccess.get_file_as_bytes(path) == old_bytes, "legacy v%d migrates identity and real old resource fields through disk and pure API without rewriting source" % version)
		var expected: Dictionary = WorldState.new().export_state() if version == 1 else expected_world
		check(same_json(loaded.snapshot.world_state, expected) and same_json(loaded.snapshot.progression, expected_growth) and same_json(loaded.snapshot.inventory, expected_inventory) and same_json(loaded.snapshot.loadout, expected_loadout), "legacy v%d preserves growth/loadout and v2 world facts while v1 supplies empty world facts" % version)
		actor.race_id = Races.IDS[1]
		var restored: Dictionary = repository.restore(legacy, actor, game)
		check(restored.ok and actor.race_id == expected_race and same_json(game.world_state.export_state(), expected), "direct legacy v%d restore applies its correct identity and world state" % version)
		var injected := legacy.duplicate(true)
		injected.race_id = "unknown_race"
		unchanged_rejection(repository, injected, "legacy v%d rejects injected identity instead of discarding an unknown field" % version)
		# Name uniqueness is enforced by real saves. The migrated disk fixture has
		# its own slot but shares this test adventure's name; test publication in
		# an isolated one-file directory to exercise the normal upgrade path.
		var upgrade_dir := workspace.path_join("upgrade_v%d" % version)
		DirAccess.make_dir_recursive_absolute(upgrade_dir)
		write_snapshot(upgrade_dir.path_join("slot_%02d.json" % (version + 1)), legacy)
		var upgrade_repo := Repository.new(upgrade_dir)
		var upgraded: Dictionary = upgrade_repo.save(version, legacy.name, actor, game)
		var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(upgrade_dir.path_join("slot_%02d.json" % (version + 1))))
		check(upgraded.ok and envelope.version == Repository.VERSION and upgrade_repo.load_slot(version).snapshot.race_id == expected_race, "normal save publishes legacy v%d as a checksummed current envelope" % version)
	var bad_disk := populated.duplicate(true)
	bad_disk.slot = 3
	bad_disk.race_id = "unsupported_race"
	write_snapshot(workspace.path_join("slot_04.json"), bad_disk)
	check(not repository.load_slot(3).ok and repository.slot(3).occupied and not repository.slot(3).valid, "checksummed unknown race remains an occupied invalid slot rather than loading or being overwritten")
	clean(workspace)
	game.queue_free()
	await process_frame
	print("RACE_PERSISTENCE_RESULT checks=", checks, " failures=", failures.size())
	quit(1 if not failures.is_empty() else 0)

func clean(path: String) -> void:
	if path != workspace and not path.begins_with(workspace + "/"): return
	var dir := DirAccess.open(path)
	if dir == null: return
	for filename in dir.get_files(): DirAccess.remove_absolute(path.path_join(filename))
	for dirname in dir.get_directories(): clean(path.path_join(dirname))
	DirAccess.remove_absolute(path)
