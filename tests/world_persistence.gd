extends SceneTree
## Real disk migration and a real main scene; never opens player save directories.
const Repository = preload("res://rpg/save_repository.gd")
const WorldState = preload("res://rpg/world_state.gd")
var checks := 0
var failures: Array[String] = []
var workspace := ""
var game: Node
var observed_snapshot: Dictionary = {}
var observer_checks: Array[bool] = []
var observer_counts: Dictionary = {}
var inside_observer := false

func _initialize() -> void:
	preload("res://rpg/game_preferences.gd").settings_path = OS.get_temp_dir().path_join("mosslight-world-prefs-%d.cfg" % OS.get_process_id())
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
	print("PASS " if ok else "FAIL ", message)

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func write_snapshot(path: String, snapshot: Dictionary, envelope_version := -1) -> void:
	var payload := JSON.stringify(snapshot)
	var envelope := {"format":"mosslight_adventure", "version":snapshot.version if envelope_version < 0 else envelope_version,
		"payload_json":payload, "sha256":payload.sha256_text()}
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(envelope))
	file.close()

func run() -> void:
	workspace = OS.get_temp_dir().path_join("mosslight-world-persistence-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var repo := Repository.new(workspace)
	var created: Dictionary = repo.create("世界状态回归")
	check(created.ok and created.snapshot.version == Repository.VERSION, "new adventures use current envelope and payload")
	check(WorldState.new().validate_state(created.snapshot.world_state).is_empty(), "new adventure starts with a valid empty world")
	check(created.snapshot.content_set == {}, "built-in adventure records no external content dependency")
	var version_four: Dictionary = created.snapshot.duplicate(true)
	version_four.version = 4
	version_four.erase("content_set")
	var version_four_before := version_four.duplicate(true)
	var upgraded_four: Dictionary = repo.migrate_snapshot(version_four)
	check(upgraded_four.ok and upgraded_four.snapshot.content_set == {} and version_four == version_four_before, "v4 migration pins built-in content without rewriting the input")
	var injected_four := version_four.duplicate(true)
	injected_four.content_set = {"bundle_sha256":"unreviewed"}
	check(not repo.migrate_snapshot(injected_four).ok, "legacy envelope cannot smuggle an external content dependency")
	var wrong_content: Dictionary = created.snapshot.duplicate(true)
	wrong_content.content_set = {"bundle_sha256":"missing content"}
	check(not repo.migrate_snapshot(wrong_content).ok, "missing or changed content is rejected before gameplay validation")
	var legacy: Dictionary = created.snapshot.duplicate(true)
	legacy.erase("world_state")
	legacy.erase("race_id")
	legacy.erase("content_set")
	legacy.resources = {"HP":100.0,"Stamina":3.0,"Qi":0.0,"SpellSlot":0.0}
	legacy.version = 1
	var legacy_before: String = JSON.stringify(legacy)
	var migration: Dictionary = repo.migrate_snapshot(legacy)
	check(migration.ok and migration.snapshot.version == Repository.VERSION, "pure v1 migration produces current schema")
	check(JSON.stringify(legacy) == legacy_before, "migration leaves caller's legacy data untouched")
	var path: String = repo._path(0)
	write_snapshot(path, legacy)
	var old_bytes := FileAccess.get_file_as_bytes(path)
	var reopened := Repository.new(workspace)
	check(reopened.load_slot(0).ok and reopened.load_slot(0).snapshot.version == Repository.VERSION, "a fresh repository reads actual v1 disk files")
	check(FileAccess.get_file_as_bytes(path) == old_bytes, "listing/loading legacy adventure never rewrites disk")
	check(reopened.slot(0).valid and not reopened.validate_new_name("世界状态回归").is_empty(), "legacy slots retain metadata and name uniqueness")
	var bad := legacy.duplicate(true)
	bad.world_state = {}
	check(not repo.migrate_snapshot(bad).ok, "v1 cannot smuggle unknown world state fields")
	bad = legacy.duplicate(true)
	bad.inventory.stacks["nonexistent_item"] = 1
	check(not repo.migrate_snapshot(bad).ok, "migration still validates all original gameplay data")
	write_snapshot(path, legacy, 2)
	check(not reopened.load_slot(0).ok, "envelope and payload versions must agree")
	write_snapshot(path, legacy)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(30)
	game.sound.muted = true
	game.combat_world.encounters_started = true
	game.player.set_physics_process(false)
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	check(repo.restore(legacy, game.player, game).ok, "legacy snapshot restores directly into the real game")
	check(game.world_state.set_flag("chapter.prologue.started", true), "real game owns writable persistent quest flags")
	check(game.world_state.set_object("watergarden.chest.01", {"opened":true,"loot_claimed":true}), "persistent object state accepts stable IDs")
	check(game.world_state.record_event("enemy_defeated", "soldier", 1, "encounter.forest.01:1"), "world events update persistent counters")
	check(not game.world_state.record_event("enemy_defeated", "soldier", 1, "encounter.forest.01:1"), "same completed occurrence cannot count twice")
	var saved: Dictionary = repo.save(0, "世界状态回归", game.player, game)
	check(saved.ok, "real player and world state save together")
	check(FileAccess.get_file_as_bytes(path + ".bak") == old_bytes, "first successful save preserves original v1 backup")
	var disk: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(disk.version == Repository.VERSION, "successful save publishes current schema on disk")
	var expected: Dictionary = game.world_state.export_state()
	game.world_state.set_flag("chapter.prologue.started", false)
	game.world_state.set_object("watergarden.chest.01", {"opened":false})
	check(repo.restore(repo.load_slot(0).snapshot, game.player, game).ok, "current disk snapshot restores successfully")
	check(game.world_state.export_state() == expected, "all persistent flags objects counters and dedup records roundtrip")
	var empty: Dictionary = repo.create("另一段冒险", 1)
	check(repo.restore(empty.snapshot, game.player, game).ok and game.world_state.export_state() == WorldState.new().export_state(), "switching adventures removes all previous world state")
	check(repo.restore(saved.snapshot, game.player, game).ok and game.world_state.export_state() == expected, "returning to original adventure restores its own state")
	bad = saved.snapshot.duplicate(true)
	bad.world_state.flags["invalid flag with spaces"] = true
	var before_inventory: Dictionary = game.player.inventory.export_state()
	var before_position: Vector3 = game.player.global_position
	check(not repo.restore(bad, game.player, game).ok, "bad persistent state is rejected before live changes")
	check(game.world_state.export_state() == expected and game.player.inventory.export_state() == before_inventory and game.player.global_position == before_position, "failed restore is atomic for both player and world")
	bad = saved.snapshot.duplicate(true)
	bad.world_state.version = 99
	check(not repo.restore(bad, game.player, game).ok, "future world schema is not silently downgraded")
	bad = saved.snapshot.duplicate(true)
	bad.version = 99
	check(not repo.migrate_snapshot(bad).ok, "future adventure version is not silently downgraded")
	check_atomic_restore(repo, empty.snapshot)
	game.queue_free()
	await ticks(3)
	# Cleanup is restricted to the unique directory allocated by this process.
	var temp_root := OS.get_temp_dir().simplify_path().replace("\\", "/").trim_suffix("/") + "/"
	if workspace.simplify_path().replace("\\", "/").begins_with(temp_root) and workspace.get_file().begins_with("mosslight-world-persistence-"):
		var dir := DirAccess.open(workspace)
		for filename in dir.get_files(): DirAccess.remove_absolute(workspace.path_join(filename))
		DirAccess.remove_absolute(workspace)
	print("WORLD_PERSISTENCE ", checks - failures.size(), "/", checks, " passed")
	quit(0 if failures.is_empty() else 1)

func same_json(left: Dictionary, right: Dictionary) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))

func restore_observer(kind: String, repo: RefCounted) -> void:
	# A failing implementation must fail the assertion instead of recursing forever.
	if inside_observer:
		observer_checks.append(false)
		return
	inside_observer = true
	observer_counts[kind] = int(observer_counts.get(kind, 0)) + 1
	var actor: Node = game.player
	observer_checks.append(same_json(actor.inventory.export_state(), observed_snapshot.inventory)
		and same_json(actor.progression.export_state(), observed_snapshot.progression)
		and same_json(actor.loadout.export_state(), observed_snapshot.loadout)
		and same_json(game.world_state.export_state(), observed_snapshot.world_state)
		and actor.display_name == observed_snapshot.name and actor.race_id == observed_snapshot.race_id
		and actor.global_position.is_equal_approx(Vector3(observed_snapshot.world.position[0], observed_snapshot.world.position[1], observed_snapshot.world.position[2])))
	for resource in Repository.RESOURCES:
		observer_checks.append(is_equal_approx(actor.resources.current(resource), float(observed_snapshot.resources[resource])))
	observer_checks.append(not game.quests.claim("village_patrol"))
	observer_checks.append(not game.quests.accept("forest_investigation"))
	observer_checks.append(not repo.save(int(observed_snapshot.slot), observed_snapshot.name, actor, game).ok)
	# The guard must also cover an independently constructed repository instance.
	var alternate := Repository.new(workspace)
	observer_checks.append(not alternate.restore(observed_snapshot, actor, game).ok)
	observer_checks.append(not alternate.save(int(observed_snapshot.slot), observed_snapshot.name, actor, game).ok)
	inside_observer = false

func check_atomic_restore(repo: RefCounted, empty_snapshot: Dictionary) -> void:
	var actor: Node = game.player
	# Career selection now honors the live actor's input eligibility. No frame runs
	# between these calls, so physics still stays frozen during persistence checks.
	actor.set_physics_process(true)
	check(actor.progression.choose_career("warrior") and game.quests.accept("village_patrol"), "prepare old adventure with an active quest")
	actor.set_physics_process(false)
	actor.race_id = "elf"
	actor.global_position += Vector3(2, 0, -1)
	game.world_state.record_event("enemy_defeated", "soldier")
	var ready: Dictionary = repo.save(0, "世界状态回归", actor, game)
	check(ready.ok and game.quests.status("village_patrol") == "ready", "prepare a persisted claimable quest for restore observers")
	var inventory_observer := restore_observer.bind("inventory", repo)
	var quest_observer := restore_observer.bind("quests", repo)
	var resource_observer := func(_id: String, _current: float, _maximum: float): restore_observer("resources", repo)
	actor.inventory.changed.connect(inventory_observer)
	game.quests.changed.connect(quest_observer)
	actor.resources.resource_changed.connect(resource_observer)
	for target in [empty_snapshot, ready.snapshot]:
		observed_snapshot = target
		observer_checks.clear()
		observer_counts.clear()
		var disk_before := FileAccess.get_file_as_bytes(repo._path(int(target.slot)))
		check(repo.restore(target, actor, game).ok, "restore commits fully before synchronous observers")
		check(observer_checks.size() > 0 and observer_checks.all(func(value: bool): return value), "every callback sees complete state and cannot claim save or restore reentrantly")
		check(observer_counts.get("inventory", 0) == 1 and observer_counts.get("quests", 0) == 1, "restore emits one final inventory and quest refresh")
		check(FileAccess.get_file_as_bytes(repo._path(int(target.slot))) == disk_before, "synchronous save attempts cannot overwrite disk during restore")
		check(same_json(actor.inventory.export_state(), target.inventory) and same_json(game.world_state.export_state(), target.world_state), "observer attempts cannot add old quest rewards or modify restored flags")
	observed_snapshot = empty_snapshot
	observer_checks.clear()
	observer_counts.clear()
	for object in [actor.stats, actor.inventory, game.quests]: object.set_block_signals(true)
	check(repo.restore(empty_snapshot, actor, game).ok, "restore accepts components whose signals were already blocked")
	check(actor.stats.is_blocking_signals() and actor.inventory.is_blocking_signals() and game.quests.is_blocking_signals(), "restore preserves preexisting signal blocking")
	check(not actor.resources.is_blocking_signals() and not game.world_state.is_blocking_signals(), "restore releases only its own signal blocks")
	check(observer_counts.get("inventory", 0) == 0 and observer_counts.get("quests", 0) == 0 and observer_checks.all(func(value: bool): return value), "previously blocked observers stay silent while other final observers are safe")
	for object in [actor.stats, actor.inventory, game.quests]: object.set_block_signals(false)
	actor.inventory.changed.disconnect(inventory_observer)
	game.quests.changed.disconnect(quest_observer)
	actor.resources.resource_changed.disconnect(resource_observer)
	check(repo.restore(ready.snapshot, actor, game).ok and game.quests.claim("village_patrol"), "restore releases guards so normal quest rewards resume afterward")
	check(repo.save(0, "世界状态回归", actor, game).ok, "normal saving resumes after restore completes")
