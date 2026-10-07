extends SceneTree
## Actual frontend/main scene. UI clicks, keyboard interaction, world movement,
## camera and temporary unit ownership are exercised through production routes.
const OUTPUT := "res://docs/combat/"
const Preferences = preload("res://rpg/game_preferences.gd")
var app: Node
var game: Node
var hero: Node
var unit: Node
var checks := 0
var failures := 0
var captures := 0
var report: PackedStringArray = []
var hero_actions: Array[String] = []
var unit_actions: Array[String] = []

func _initialize() -> void: call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func check(ok: bool, label: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	var line := ("PASS " if ok else "FAIL ") + label
	print(line)
	report.append(line)

func key(code: Key) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		root.push_input(event, true)
		await ticks(2)

func click(button: Control) -> void:
	var position: Vector2 = button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	await ticks(1)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.global_position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
		await ticks(2)

func confirm_world() -> void:
	var position := Vector2(960, 400)
	var motion := InputEventMouseMotion.new()
	motion.position = position
	Input.parse_input_event(motion)
	await ticks(2)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.global_position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await ticks(2)

func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var success := root.get_texture().get_image().save_png(OUTPUT + "unit_world_" + label + ".png") == OK
	check(success, "GPU capture " + label)
	captures += 1 if success else 0

func run() -> void:
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-casting-unit-world-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	root.size = Vector2i(1920, 1080)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = app.SAVE_REPOSITORY.new(Preferences.settings_path + "-adventures")
	root.add_child(app)
	current_scene = app
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	await ticks(3)
	app._finish_arrival()
	game = app.game
	hero = game.player
	app.ui.close_panel(true)
	app.ui.career_picker = false
	app.ui.region_clock = 0
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	check(hero.progression.choose_career("warrior") and hero.progression.learn_skill("warrior_thrust") and hero.loadout.assign_skill(0, 0, "warrior_thrust"), "live frontend adventure prepares the hero's separate warrior skill")
	await ticks(20)
	check(app.ui.rpg == hero and app.ui.hud_actor() == hero and app.ui.minimap.player_node == hero, "frontend initially binds identity, HUD and minimap to the hero")
	unit = game.combat_world.spawn_enemy("soldier", hero.global_position + Vector3(12, 0, -2))
	unit.brain.aggressive = false
	var original_faction: String = unit.faction_id
	hero.combat.runner.action_started.connect(func(action: Dictionary): hero_actions.append(str(action.get("id", ""))))
	unit.combat.runner.action_started.connect(func(action: Dictionary): unit_actions.append(str(action.get("id", ""))))
	check(game.combat_world.control.possess(unit, 60), "normal control component possesses the actual soldier unit")
	await ticks(90)
	check(app.ui.hud_actor() == unit and app.ui.minimap.player_node == unit and game.controlled_actor() == unit, "HUD, minimap and world all track the possessed body")
	check(app.ui.rpg == hero and app.ui.rpg_state.race_id == hero.race_id and app.ui.rpg_state.level == hero.loadout.level, "character-sheet identity and progression stay bound to the original hero")
	check(hero.control_mode == "none" and unit.control_mode == "human", "possession grants one human controller and disables the original body")
	check(app.ui.quick_buttons[&"skill_q"].disabled, "an unprepared soldier skill slot is empty rather than showing the hero's Q")
	var camera_target: Vector3 = unit.global_position
	camera_target.y = 2.2
	camera_target += game._camera_lead()
	check(game.smooth_target.distance_to(camera_target) < .2 and game.smooth_target.distance_to(hero.global_position + game._camera_lead()) > 6, "live camera follows the controlled body's position instead of original hero")
	game.aim_override = unit.global_position + Vector3.RIGHT * 4
	check(game.action_aim_direction().dot(Vector3.RIGHT) > .999, "action aim direction originates at the controlled body")
	await ticks(2)
	check(game.combat_world.aim_point.distance_to(game.aim_override) < .01, "world combat receives current controlled-body aim point")
	check(not hero.combat.request_skill(0) and not hero.combat.weapon_action("PRIMARY_TAP") and hero_actions.is_empty(), "original none-controlled body cannot start skill or weapon actions")
	# The soldier template has empty QER. Supply one valid innate action in
	# this unit's runtime definition to exercise the generic per-unit HUD route.
	var skill: Dictionary = unit.action_for("PRIMARY_TAP")
	skill.id = "world_soldier_skill_probe"
	skill.name = "士兵独立技能"
	skill.is_skill = true
	skill.cooldown = 1.0
	unit.innate_skills.assign([skill])
	check(unit.inventory.add_item("healing_potion", 2) and unit.inventory.assign_quick_slot(0, "healing_potion"), "controlled unit owns its own potion stack and quick slot")
	unit.resources.change("HP", -unit.resources.max_value("HP") * .5)
	await ticks(3)
	check(not app.ui.quick_buttons[&"skill_q"].disabled and app.ui.quick_buttons[&"skill_q"].tooltip_text.begins_with(skill.name + "\n") and app.ui.quick_buttons[&"quick_item_1"].quantity == "2", "HUD reflects controlled unit skill and inventory values")
	await click(app.ui.quick_buttons[&"skill_q"])
	check(unit.skill_casting.active() and unit_actions.is_empty(), "controlled unit HUD starts selection without acting on the parked hero")
	await confirm_world()
	check(skill.id in unit_actions and hero_actions.is_empty(), "actual native Q button click starts only the possessed unit's skill")
	await ticks(90)
	check(unit_actions.size() == 1 and hero_actions.is_empty(), "holding pointer over HUD after clicking adds no stray normal attack")
	var before_hp: float = unit.resources.current("HP")
	var hero_inventory: Dictionary = hero.inventory.export_state()
	await click(app.ui.quick_buttons[&"quick_item_1"])
	check(unit.resources.current("HP") > before_hp and unit.inventory.count("healing_potion") == 1, "actual potion button consumes and heals the controlled unit")
	check(hero.inventory.export_state() == hero_inventory and hero_actions.is_empty(), "controlled quick-item use leaves original inventory and actions unchanged")
	await capture("possessed_hud_1080")
	# The real character page pauses both controlled body and lease timer.
	await key(KEY_X)
	check(app.ui.panel == "character" and game.paused and paused and app.ui.rpg == hero, "physical C opens original hero's sheet and pauses the controlled world")
	var paused_at: Vector3 = unit.global_position
	var paused_time: float = game.combat_world.control.remaining
	var paused_camera: Transform3D = game.camera.global_transform
	Input.action_press("move_up")
	await ticks(24)
	Input.action_release("move_up")
	check(unit.global_position.distance_to(paused_at) < .001 and is_equal_approx(game.combat_world.control.remaining, paused_time), "book pause freezes movement and possession duration")
	check(game.camera.global_transform.is_equal_approx(paused_camera), "book pause freezes camera follow")
	app.ui.close_panel(true)
	await ticks(3)
	check(not game.paused and not paused and game.combat_world.control.controlled_actor() == unit, "closing book resumes the same controlled body")
	# Move only the possessed soldier to the authored village ladder. Original
	# hero remains far away, so successful interaction proves correct F routing.
	var ladder: Node3D = game.reference_map.get_node("NorthernVillage/VillageHouseLadder")
	unit.global_position = ladder.bottom_exit() + Vector3.UP * .02
	unit.velocity = Vector3.ZERO
	unit.combat.reset()
	await ticks(12)
	check(game.nearest_interactable() == ladder and hero.global_position.distance_to(ladder.bottom_exit()) > 10, "nearest interaction is measured from possessed soldier, far from the hero")
	await key(KEY_F)
	check(unit.ladder.active and not hero.ladder.active and unit.get_meta("traversal_locked", false), "physical F attaches the possessed soldier to the real village ladder")
	var entry_y: float = unit.global_position.y
	Input.action_press("move_up")
	await ticks(50)
	Input.action_release("move_up")
	check(unit.ladder.active and unit.global_position.y > entry_y + .75, "real W climbs the soldier upward through shared Actor traversal")
	check(hero_actions.is_empty() and hero.control_mode == "none", "climbing never reactivates original hero input")
	await capture("possessed_ladder_1080")
	game.combat_world.control.release()
	check(not unit.ladder.active and not unit.get_meta("traversal_locked", false) and unit.control_mode == "ai", "releasing possession clears the soldier's active ladder and traversal lock")
	await ticks(3)
	check(app.ui.hud_actor() == hero and app.ui.minimap.player_node == hero and hero.control_mode == "human" and unit.faction_id == original_faction, "release returns HUD/minimap/input to hero and original allegiance to soldier")
	# All actors share floating movement; use the intentionally deep lake area.
	var water_y: float = game.reference_map.get_node("Lake").global_position.y
	unit.global_position = game.GARDEN_ORIGIN + Vector3(75, water_y - .8, -30)
	unit.velocity = Vector3.ZERO
	unit.combat.reset()
	check(game.combat_world.control.possess(unit, 30) and game.is_in_deep_water(unit.global_position), "second possession starts in the real deep-water test location")
	var swimming_hp: float = unit.resources.current("HP")
	var swimming_start: Vector3 = unit.global_position
	Input.action_press("move_up")
	await ticks(70)
	Input.action_release("move_up")
	check(unit.swimming and unit.wading and unit.global_position.y >= water_y - .705 and unit.global_position.y <= water_y - .43, "possessed soldier receives shared buoyancy at water surface")
	check(unit.resources.current("HP") == swimming_hp and not unit.dead and unit.global_position.distance_to(swimming_start) > .5, "real swimming moves the controlled unit while preserving its HP")
	await capture("possessed_water_1080")
	game.combat_world.control.cancel_all()
	game._release_actions()
	app.queue_free()
	await ticks(4)
	finish()

func finish() -> void:
	var result := "UNIT_WORLD_INTEGRATION_RESULT checks=%d failures=%d captures=%d" % [checks, failures, captures]
	print(result)
	report.append(result)
	report.append("UTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	var file := FileAccess.open(OUTPUT + "unit_world_integration_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	file.close()
	DirAccess.remove_absolute(Preferences.settings_path)
	Preferences.settings_path = Preferences.DEFAULT_PATH
	quit(0 if failures == 0 else 1)
