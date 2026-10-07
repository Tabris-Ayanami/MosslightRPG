extends SceneTree
## Actual frontend + authored props. All settings/save writes stay in one OS-temp directory.
const Objects = preload("res://rpg/world_objects.gd")
const WorldState = preload("res://rpg/world_state.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
var checks := 0
var failures: Array[String] = []
var workspace := ""
var app: Node
var game: Node
var repo: RefCounted
var service: RefCounted
var props: Array[Node3D] = []
var chest: Node3D
var forest: Node3D
var shrine: Node3D
var observer_results: Array[bool] = []
var baseline: Dictionary = {}
var reward_before := 0

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func ticks(count: int) -> void:
	for index in range(count):
		await physics_frame
		await process_frame

func key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		await ticks(2)

func approach(prop: Node3D) -> void:
	game.player.global_position = prop.global_position + Vector3(0, .06, 1.25)
	game.player.velocity = Vector3.ZERO
	await ticks(6)

func screenshot(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	game.smooth_target = game.player.global_position + game._camera_lead()
	game.camera.look_at_from_position(game.smooth_target + game.camera_offset, game.smooth_target)
	await ticks(8)
	await RenderingServer.frame_post_draw
	var folder := "res://docs/world-objects/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	check(root.get_texture().get_image().save_png(folder + label + ".png") == OK, "Forward+ screenshot saved: " + label)

func inventory_observer() -> void:
	observer_results.append(game.player.inventory.count("healing_potion") == reward_before + 2)
	observer_results.append(game.world_state.get_object(chest.persistent_id).get("opened", false))
	observer_results.append(Guard.busy(game.world_state))
	observer_results.append(not service.interact(chest))
	observer_results.append(not service.setup(game))
	service.dispose()
	observer_results.append(service.populate().is_empty())
	observer_results.append(not repo.restore(baseline, game.player, game).ok)
	observer_results.append(not game.quests.accept("village_patrol"))
	var saved: Dictionary = repo.save(0, "世界物体回归", game.player, game)
	observer_results.append(saved.ok and saved.snapshot.world_state.objects[chest.persistent_id].opened and int(saved.snapshot.inventory.stacks.healing_potion) == reward_before + 2)

func resource_observer(_id: String, _current: float, _maximum: float) -> void:
	observer_results.append(game.world_state.get_object(shrine.persistent_id).get("activated", false))
	observer_results.append(game.player.combat.cooldowns.is_empty() and game.player.combat.state == "NORMAL")
	observer_results.append(game.checkpoint == game.player.spawn_point and game.checkpoint.is_equal_approx(game.reference_map.to_global(Vector3(1.6, 2.35, 4.8))))
	for resource in ["HP", "Stamina", "Qi", "SpellSlot"]:
		observer_results.append(is_equal_approx(game.player.resources.current(resource), game.player.resources.max_value(resource)))
	observer_results.append(Guard.busy(game.world_state) and not service.interact(shrine))
	var saved: Dictionary = repo.save(0, "世界物体回归", game.player, game)
	observer_results.append(saved.ok and saved.snapshot.world_state.objects[shrine.persistent_id].activated)

func run() -> void:
	create_timer(100, true).timeout.connect(func(): printerr("WORLD_OBJECTS timeout"); quit(1))
	workspace = OS.get_temp_dir().path_join("mosslight-world-objects-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(workspace)
	Preferences.settings_path = workspace.path_join("preferences.cfg")
	repo = Repository.new(workspace.path_join("adventures"))
	check(repo.create("世界物体回归", 0).ok, "test adventure is created only in OS-temp")
	var empty: Dictionary = repo.create("另一段物体冒险", 1).snapshot
	root.size = Vector2i(1280, 720)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = repo
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.close_panel(true)
	app.ui.modulate.a = 1
	app.ui.region_clock = 0
	game = app.game
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	await ticks(12)
	service = game.world_objects
	props = service.populate()
	check(props.size() == 3, "main world contains the two authored chests and one waystone")
	if props.size() != 3:
		await finish()
		return
	for prop in props:
		match prop.persistent_id:
			"prop.village_supply_chest": chest = prop
			"prop.forest_exploration_chest": forest = prop
			"prop.garden_waystone": shrine = prop
		check(prop.grounded and prop.global_position.y > 1.9 and prop.global_position.y < 2.6, "prop rests on reliable land: " + prop.persistent_id)
		check(not prop.find_children("*", "StaticBody3D", true, false).is_empty(), "prop has physical collision: " + prop.persistent_id)
		check(prop.get_world_3d() == game.player.get_world_3d(), "prop shares actual gameplay world: " + prop.persistent_id)
	check(service.populate() == props, "repeated population retains the same three instances")
	if "--placement-preview" in OS.get_cmdline_user_args():
		var candidates := [Vector3(40, 2.22, -4), Vector3(43.5, 2.22, -1.8), Vector3(45, 2.22, 3), Vector3(36.3, 2.22, -2)]
		for index in range(candidates.size()):
			forest.global_position = game.reference_map.to_global(candidates[index])
			await approach(forest)
			await screenshot("preview-forest-%d" % index)
		await finish()
		return
	check(game.player.progression.choose_career("warrior"), "real canonical player receives a valid starter loadout")
	baseline = repo.save(0, "世界物体回归", game.player, game).snapshot
	check(Objects.validate_snapshot(baseline.world_state, repo.database).is_empty(), "static validator accepts absent records as fresh objects")
	var invalid: Dictionary = baseline.world_state.duplicate(true)
	for record in [{"version": 1, "kind": "chest", "opened": "yes"}, {"version": 2, "kind": "chest", "opened": true}, {"version": 1, "kind": "shrine", "opened": true}, {"version": 1, "kind": "chest", "opened": true, "items": {}}]:
		invalid.objects[chest.persistent_id] = record
		check(not Objects.validate_snapshot(invalid, repo.database).is_empty(), "strict state rejects malformed fields: " + str(record))
	invalid = baseline.world_state.duplicate(true)
	invalid.objects["prop.unknown"] = {"version": 1, "kind": "chest", "opened": true}
	check(not Objects.validate_snapshot(invalid, repo.database).is_empty(), "unknown permanent prop ID requires migration")
	check(not service.interact(chest) and not chest.opened, "direct distant interaction cannot claim rewards")
	await approach(chest)
	check(game.nearest_interactable() == chest, "actual village F targeting selects supply chest")
	await screenshot("01-village-closed")
	game.paused = true
	check(not service.interact(chest), "paused gameplay cannot interact through direct service calls")
	game.paused = false
	game.player.combat.state = "HITSTUN"
	check(not service.interact(chest), "incapacitated player cannot bypass readiness")
	game.player.combat.state = "NORMAL"
	Guard.acquire(game.world_state, "test.other")
	check(not service.interact(chest), "shared adventure guard refuses overlapping mutations")
	Guard.release(game.world_state, "test.other")
	game.player.inventory.stacks.healing_potion = 1000000
	var old_world: Dictionary = game.world_state.export_state()
	check(not service.interact(chest) and not chest.opened and game.world_state.export_state() == old_world and game.player.inventory.count("healing_potion") == 1000000, "overflow failure changes neither stacks nor opened state")
	check(repo.restore(baseline, game.player, game).ok, "restore resets transaction fixtures")
	await approach(chest)
	var full: Dictionary = baseline.world_state.duplicate(true)
	for index in range(WorldState.MAX_OBJECTS): full.objects["test.capacity.%d" % index] = {}
	check(game.world_state.import_state(full), "prepare bounded full world state")
	var before_stacks: Dictionary = game.player.inventory.stacks.duplicate(true)
	check(not service.interact(chest) and not chest.opened and game.player.inventory.stacks == before_stacks and game.world_state.export_state() == full, "full world capacity refuses reward without consuming chest")
	check(repo.restore(baseline, game.player, game).ok, "restore removes capacity fixtures")
	await approach(chest)
	reward_before = game.player.inventory.count("healing_potion")
	game.player.inventory.changed.connect(inventory_observer)
	await key(KEY_F)
	game.player.inventory.changed.disconnect(inventory_observer)
	check(chest.opened and game.player.inventory.count("healing_potion") == reward_before + 2, "physical F opens the authored chest and grants real inventory once")
	check(observer_results.size() > 0 and observer_results.all(func(value: bool): return value), "inventory observers save complete reward and cannot reenter dispose setup restore or quests")
	check(not Guard.busy(game.world_state), "guard releases after all chest callbacks")
	await create_timer(.4).timeout
	check(is_equal_approx(chest.lid.rotation.x, -1.2), "real lid completes its opening animation")
	await key(KEY_F)
	check(game.player.inventory.count("healing_potion") == reward_before + 2, "repeated physical F never duplicates loot")
	await screenshot("02-village-opened")
	await approach(forest)
	check(game.nearest_interactable() == forest, "actual forest F targeting selects exploration chest")
	var controlled_unit: Node = game.combat_world.spawn_enemy("soldier", forest.global_position + Vector3(0, .08, 1.3))
	controlled_unit.set_physics_process(false)
	check(game.combat_world.control.possess(controlled_unit, 60), "real possession supplies another controlled actor for chest approach")
	game.player.global_position = forest.global_position + Vector3.RIGHT * 12
	check(game.nearest_interactable() == forest, "chest proximity follows controlled actor while canonical player is distant")
	var bombs: int = game.player.inventory.count("fire_bomb")
	await key(KEY_F)
	check(forest.opened and game.player.inventory.count("fire_bomb") == bombs + 1, "forest chest grants its distinct authored reward")
	check(controlled_unit.inventory.count("fire_bomb") == 0, "possessed unit never receives the canonical adventure's chest inventory")
	game.combat_world.control.cancel_all()
	controlled_unit.queue_free()
	await approach(forest)
	await screenshot("03-forest-opened")
	await approach(shrine)
	check(game.player.form.apply_enemy_form("fire_elemental", 60), "real temporary form prepares waystone exclusion")
	check(not service.interact(shrine) and game.player.form.active and not shrine.activated and service.last_error.contains("原形"), "waystone refuses form without cancelling it or activating checkpoint")
	check(game.player.form.restore(), "player can explicitly return to canonical form")
	controlled_unit = game.combat_world.spawn_enemy("soldier", shrine.global_position + Vector3(0, .08, 1.3))
	controlled_unit.set_physics_process(false)
	check(game.combat_world.control.possess(controlled_unit, 60), "real possession prepares waystone exclusion")
	check(not service.interact(shrine) and game.controlled_actor() == controlled_unit and not shrine.activated and service.last_error.contains("身体"), "waystone refuses possession without changing control or activation")
	game.combat_world.control.cancel_all()
	controlled_unit.queue_free()
	await ticks(2)
	game.player.resources.change("HP", -35)
	game.player.resources.change("Stamina", -2)
	game.player.combat.cooldowns["test.cooldown"] = 20.0
	game.checkpoint = Vector3(0, 2.35, 80)
	observer_results.clear()
	game.player.resources.resource_changed.connect(resource_observer)
	await key(KEY_F)
	game.player.resources.resource_changed.disconnect(resource_observer)
	check(shrine.activated and game.world_state.get_object(shrine.persistent_id).activated, "physical F activates the authored waystone")
	check(observer_results.size() > 0 and observer_results.all(func(value: bool): return value), "every resource callback sees restored resources combat checkpoint and activation together")
	check(not Guard.busy(game.world_state), "guard releases after all waystone callbacks")
	await screenshot("04-waystone-activated")
	game.player.resources.change("HP", -10)
	game.player.combat.queued_command = {"expires": 100000.0, "test": true}
	game.player.combat.guard_key_held = true
	game.player.combat.guard_pointer_held = true
	check(service.interact(shrine) and game.player.resources.current("HP") == game.player.resources.max_value("HP"), "activated waystone remains repeatably restorative")
	check(game.player.combat.queued_command.is_empty() and not game.player.combat.guard_key_held and not game.player.combat.guard_pointer_held, "waystone explicitly clears queued and held combat intent despite blocked reset signals")
	game.player.resources.set_block_signals(true)
	check(service.interact(shrine) and game.player.resources.is_blocking_signals(), "waystone preserves a caller's preexisting signal block")
	game.player.resources.set_block_signals(false)
	var saved: Dictionary = repo.save(0, "世界物体回归", game.player, game)
	check(saved.ok, "real inventory checkpoint and object facts persist together on disk")
	var inventory: Dictionary = game.player.inventory.export_state()
	service.refresh()
	check(game.player.inventory.export_state() == inventory and is_equal_approx(chest.lid.rotation.x, -1.2), "refresh replays appearance without granting any reward")
	check(repo.restore(empty, game.player, game).ok and not chest.opened and not forest.opened and not shrine.activated, "switching adventures clears all previous object appearance")
	check(is_zero_approx(chest.lid.rotation.x), "fresh adventure closes a previously opened lid immediately")
	check(repo.restore(repo.load_slot(0).snapshot, game.player, game).ok and chest.opened and forest.opened and shrine.activated, "fresh disk read restores all three actual scene instances")
	check(game.player.inventory.export_state() == inventory, "loading opened props never duplicates items")
	invalid = saved.snapshot.duplicate(true)
	invalid.world_state.objects[chest.persistent_id].opened = "true"
	check(not repo.restore(invalid, game.player, game).ok and chest.opened and game.player.inventory.export_state() == inventory, "invalid semantic prop state fails before touching the live adventure")
	# Recreate all prop nodes, retaining the same adventure service/state.
	service.dispose()
	chest.interact(game)
	check(game.player.inventory.export_state() == inventory, "stale disposed prop cannot fall back to prototype rewards")
	await ticks(2)
	check(service.setup(game), "disposed service can bind the same valid adventure again")
	props = service.populate()
	await ticks(5)
	var recreated := true
	for prop in props: recreated = recreated and (prop.opened if prop.kind == "chest" else prop.activated)
	check(props.size() == 3 and recreated, "destroying and recreating nodes restores permanent IDs and consumed states")
	await finish()

func finish() -> void:
	if is_instance_valid(app): app.queue_free()
	await ticks(5)
	check(not paused, "teardown leaves the tree unpaused")
	Preferences.settings_path = Preferences.DEFAULT_PATH
	clean_tree(workspace)
	print("WORLD_OBJECTS ", checks - failures.size(), "/", checks, " passed")
	for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)

func clean_tree(path: String) -> void:
	var allowed := workspace.simplify_path().replace("\\", "/")
	var target := path.simplify_path().replace("\\", "/")
	if allowed.is_empty() or not allowed.get_file().begins_with("mosslight-world-objects-") or (target != allowed and not target.begins_with(allowed + "/")): return
	var directory := DirAccess.open(path)
	if directory == null: return
	for filename in directory.get_files(): DirAccess.remove_absolute(path.path_join(filename))
	for child in directory.get_directories(): clean_tree(path.path_join(child))
	DirAccess.remove_absolute(path)
