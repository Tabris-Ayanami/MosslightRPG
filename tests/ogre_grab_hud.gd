extends SceneTree
## Production frontend, real catalog-native ogre Q, and actual HUD/keyboard input.
## Does not add a runtime skill or change a production definition.
const OUTPUT := "res://docs/combat/"
const Preferences = preload("res://rpg/game_preferences.gd")
var app: Node
var game: Node
var hero: Node
var ogre: Node
var checks := 0
var failures := 0
var captures := 0
var report: PackedStringArray = []
var ogre_actions: Array[Dictionary] = []
var hero_actions: Array[String] = []

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	var line := ("PASS " if ok else "FAIL ") + label
	report.append(line)
	print(line)
func hover(button: Control) -> void:
	var event := InputEventMouseMotion.new()
	event.position = button.get_global_rect().get_center()
	event.global_position = event.position
	root.push_input(event, true)
	await ticks(2)
func click(button: Control) -> void:
	await hover(button)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = button.get_global_rect().get_center()
		event.global_position = event.position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
		await ticks(2)
func key_q() -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = KEY_Q
		event.keycode = KEY_Q
		event.pressed = pressed
		Input.parse_input_event(event)
		await ticks(2)

func click_world(button := MOUSE_BUTTON_LEFT) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(960, 400)
	motion.global_position = motion.position
	Input.parse_input_event(motion)
	await ticks(2)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = root.get_final_transform() * Vector2(960, 400)
		event.global_position = event.position
		event.button_index = button
		event.pressed = pressed
		Input.parse_input_event(event)
		await ticks(2)

func run() -> void:
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-ogre-casting-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	root.size = Vector2i(1920, 1080)
	root.gui_embed_subwindows = true
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
	check(hero.progression.choose_career("warrior") and hero.progression.learn_skill("warrior_thrust") and hero.loadout.assign_skill(0, 0, "warrior_thrust"), "hero learns and prepares its own persistent Q through normal progression")
	await ticks(20)
	var hero_skill: Dictionary = hero.skill_at(0)
	var hero_loadout: Dictionary = hero.loadout.export_state()
	var hero_tooltip: String = app.ui.quick_buttons[&"skill_q"].tooltip_text
	hero.combat.runner.action_started.connect(func(action: Dictionary): hero_actions.append(str(action.get("id", ""))))
	ogre = game.combat_world.spawn_enemy("ogre", hero.global_position + Vector3(3, 0, 0))
	ogre.ai_enabled = false
	ogre.combat.runner.action_started.connect(func(action: Dictionary): ogre_actions.append(action.duplicate(true)))
	var native: Dictionary = ogre.skill_at(0)
	check(native.get("id", "") == "ogre_grab" and native.get("name", "") == "食人魔抓取" and native.get("is_skill", false), "unmodified ogre template exposes its real native grab in Q")
	var secondary: Dictionary = ogre.action_for("SECONDARY_TAP")
	check(native.get("attack_kind", "") == "GRAB" and not secondary.is_empty() and secondary.get("id", "") != native.get("id", "") and secondary.get("attack_kind", "") != "GRAB", "Q owns the native grab while right mouse has a distinct non-grab attack")
	check(game.combat_world.control.possess(ogre, 60), "real control service transfers input to the actual ogre")
	var victim: Node = game.combat_world.spawn_enemy("soldier", ogre.global_position + Vector3(0, 0, -1.6))
	victim.ai_enabled = false
	game.aim_override = victim.global_position
	game.combat_world.locked_target = victim
	game.camera_height = 11
	game.target_camera_height = 11
	await ticks(70)
	var q_button: Control = app.ui.quick_buttons[&"skill_q"]
	check(app.ui.hud_actor() == ogre and app.ui.rpg == hero and hero.control_mode == "none", "HUD follows ogre while the character sheet stays bound to the parked hero")
	check(not q_button.disabled and q_button.kind == "fist" and q_button.caption == "Q", "live Q button is enabled and draws the native fist icon")
	var tip: String = q_button.tooltip_text
	check(tip.begins_with("食人魔抓取\n") and "抓取" in tip and "格挡" in tip and "范围" in tip and "2.6" in tip and not "鼠标右键" in tip, "native Q tooltip names grab, block behavior and actual range without a right-mouse alias")
	print("OGRE_HUD_TOOLTIP ", JSON.stringify(tip))
	await hover(q_button)
	await ticks(55)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var ok := root.get_texture().get_image().save_png(OUTPUT + "ogre_grab_hud_1080.png") == OK
		check(ok, "capture actual 1080p main-world ogre HUD with hovered Q")
		captures += 1 if ok else 0
	await click(q_button)
	check(ogre.skill_casting.active() and ogre_actions.is_empty(), "native HUD grab enters blue selection before world confirmation")
	await click_world()
	check(ogre_actions.size() == 1 and ogre_actions[0].get("id", "") == "ogre_grab" and ogre_actions[0].get("is_skill", false) and ogre.combat.runner.current_action.get("attack_kind", "") == "GRAB", "clicking the actual HUD Q starts exactly one real native grab")
	check(hero_actions.is_empty(), "HUD click never invokes the original hero's Q")
	await ticks(210)
	check(ogre_actions.size() == 1 and not ogre.combat.runner.busy(), "hovering the clicked HUD adds no stray attack after grab completes")
	await key_q()
	check(ogre_actions.size() == 2 and ogre_actions[1].get("id", "") == "ogre_grab" and ogre_actions[1].get("is_skill", false), "physical Q routes to the same real native grab")
	await ticks(210)
	await click_world(MOUSE_BUTTON_RIGHT)
	check(ogre_actions.size() == 3 and ogre_actions[2].get("id", "") == secondary.get("id", "") and ogre_actions[2].get("attack_kind", "") != "GRAB", "physical right mouse starts its distinct heavy attack instead of the Q grab")
	await ticks(150)
	game.combat_world.control.release()
	await ticks(5)
	check(app.ui.hud_actor() == hero and hero.control_mode == "human" and hero.skill_at(0) == hero_skill and hero.loadout.export_state() == hero_loadout, "release returns HUD and original prepared hero Q without modifying its loadout")
	check(app.ui.quick_buttons[&"skill_q"].kind == "sword" and app.ui.quick_buttons[&"skill_q"].tooltip_text == hero_tooltip and not app.ui.quick_buttons[&"skill_q"].disabled, "restored hero HUD displays its original skill icon and tooltip")
	await key_q()
	check(hero_actions == ["warrior_thrust"] and ogre_actions.size() == 3, "physical Q after release executes only the original hero skill")
	game._release_actions()
	app.queue_free()
	await ticks(4)
	var result := "OGRE_GRAB_HUD_RESULT checks=%d failures=%d captures=%d" % [checks, failures, captures]
	print(result)
	report.append(result)
	report.append("UTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("Input: production HUD mouse events and Input.parse_input_event physical Q/right mouse; not OS hardware injection.")
	var file := FileAccess.open(OUTPUT + "ogre_grab_hud_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	file.close()
	DirAccess.remove_absolute(Preferences.settings_path)
	Preferences.settings_path = Preferences.DEFAULT_PATH
	quit(0 if failures == 0 else 1)
