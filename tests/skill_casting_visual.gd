extends SceneTree
## Real 1080p frontend/main rendering, catalog skills and pointer projection.
## The visual fixture enables the existing sandbox loadout; production content
## and renderer settings are unchanged. Preferences and saves are isolated.
const Preferences = preload("res://rpg/game_preferences.gd")
const OUTPUT := "res://docs/combat/"
var app: Node
var game: Node
var player: Node
var checks := 0
var failures := 0
var captures := 0
var origin: Vector3
var events := 0

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	print("PASS " if ok else "FAIL ", label)
func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
func move_pointer(at: Vector2) -> void:
	if DisplayServer.get_name() != "headless":
		root.grab_focus()
		Input.warp_mouse(at)
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)
	await ticks(3)
func aim(point: Vector3) -> void:
	game.aim_override = null
	await move_pointer(game.world_to_screen(point))
	print("POINTER_TRACE ", {"expected": game.world_to_screen(point), "actual": game.get_viewport().get_mouse_position(), "world": game.combat_world.refresh_aim(), "target": point, "focus": root.has_focus()})
func click_at(at: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	await move_pointer(at)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = button
		event.pressed = down
		Input.parse_input_event(event)
		await ticks(2)
func cancel() -> void:
	await click_at(Vector2(960, 400), MOUSE_BUTTON_RIGHT)
	key(KEY_Q, false)
	await ticks(2)
func prepare(career: String, id: String) -> void:
	player.input_router.cancel()
	key(KEY_Q, false)
	var definition: Dictionary = game.combat_world.database.careers[career]
	player.loadout.select_career(str(definition.get("base_career", career)))
	player.loadout.set_level(maxi(1, int(definition.get("required_level", 1))))
	if career != definition.get("base_career", career): player.loadout.select_career(career)
	player.global_position = origin
	player.velocity = Vector3.ZERO
	player.combat.reset()
	game.combat_world.locked_target = null
	check(player.loadout.assign_skill(0, 0, id), "prepare real catalog skill " + id)
	await ticks(4)
func shot(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var pixels := root.get_texture().get_image()
	check(pixels.get_size() == Vector2i(1920, 1080) and pixels.save_png(OUTPUT + "casting-" + label + "-1080.png") == OK, "1080p main-game capture " + label)
	captures += 1
func hold_preview(point: Vector3) -> void:
	await aim(point + Vector3.UP * .8 if player.skill_at(0).get("targeting", "") == "TARGET" else point)
	key(KEY_Q, true)
	await ticks(3)
	check(player.skill_casting.active() and player.skill_casting.indicator.visible, "physical held Q exposes the main-world preview")

func run() -> void:
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-casting-visual-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	root.size = Vector2i(1920, 1080)
	if DisplayServer.get_name() != "headless": root.grab_focus()
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = app.SAVE_REPOSITORY.new(Preferences.settings_path + "-adventures")
	root.add_child(app)
	current_scene = app
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	await ticks(3)
	app._finish_arrival()
	game = app.game
	player = game.player
	app.ui.close_panel(true)
	app.ui.modulate.a = 1
	app.ui.career_picker = false
	app.ui.region_clock = 0
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	player.loadout.sandbox_mode = true
	player.combat.skill_used.connect(func(_id: String): events += 1)
	await ticks(45)
	origin = player.global_position
	var right: Vector3 = game.combat_world.camera_right()
	await prepare("warrior", "warrior_whirlwind")
	await hold_preview(player.global_position + right * 3)
	check(player.skill_casting.preview.valid and events == 0, "main game holds a valid blue circle without spending a skill")
	await shot("circle")
	await cancel()
	await prepare("warrior", "warrior_thrust")
	await hold_preview(player.global_position + right * 3)
	var direction: Vector3 = player.skill_casting.preview.intent.direction
	check(direction.dot(right) > .98, "actual pointer projection aims the skill to camera-right")
	await aim(player.global_position - right * 3)
	check(player.skill_casting.preview.intent.direction.dot(-right) > .98, "held preview follows actual mouse movement across the main pixel viewport")
	await aim(player.global_position + right * 3)
	await shot("line")
	await cancel()
	await prepare("warrior", "warrior_impact")
	await hold_preview(player.global_position + right * 3)
	await shot("cone")
	await cancel()
	await prepare("mage", "mage_fireball")
	await hold_preview(player.global_position + right * 5)
	await shot("projectile")
	await cancel()
	await prepare("mage", "mage_earth_spike")
	await hold_preview(player.global_position + right * 4)
	await shot("ground-line")
	await cancel()
	await prepare("evoker", "evoker_ice_storm")
	await hold_preview(player.global_position + right * 4)
	await shot("ground-circle")
	await cancel()
	await prepare("conjurer", "conjurer_dreamwalk")
	var soldier: Node = game.combat_world.spawn_enemy("soldier", player.global_position + right * 3.5)
	soldier.set_physics_process(false)
	await hold_preview(soldier.global_position)
	check(player.skill_casting.preview.valid and player.skill_casting.preview.intent.target.get_ref() == soldier, "real mouse hover selects an eligible soldier for the target ring")
	await shot("target")
	await cancel()
	var boss: Node = game.combat_world.spawn_enemy("ogre", player.global_position - right * 4)
	boss.set_physics_process(false)
	await hold_preview(boss.global_position)
	check(not player.skill_casting.preview.valid and player.skill_casting.preview.intent.target is WeakRef and player.skill_casting.preview.intent.target.get_ref() == boss, "over-level hovered target has explicit invalid feedback")
	await shot("invalid-target")
	await cancel()
	check(events == 0, "all cancelled visual previews leave real skill execution untouched")
	app.ui.settings_tab = 1
	app.ui.show_panel("settings")
	await ticks(70)
	var first: Button = app.ui.modal.get_node("CastMode0")
	await click_at(app.ui.get_global_transform() * first.get_global_rect().get_center())
	await ticks(4)
	check(Preferences.get_cast_mode("skill_q") == "precise" and Preferences.get_cast_mode("skill_e") == "quick" and Preferences.get_cast_mode("skill_r") == "quick", "actual settings-page click changes Q independently")
	var third: Button = app.ui.modal.get_node("CastMode2")
	await click_at(app.ui.get_global_transform() * third.get_global_rect().get_center())
	await ticks(4)
	check(Preferences.get_cast_mode("skill_q") == "precise" and Preferences.get_cast_mode("skill_e") == "quick" and Preferences.get_cast_mode("skill_r") == "precise", "actual settings page supports mixed precise/quick/precise slots")
	await move_pointer(Vector2(50, 950))
	await shot("settings")
	app.ui.close_panel(true)
	await ticks(3)
	await prepare("warrior", "warrior_whirlwind")
	await aim(player.global_position + right * 3)
	key(KEY_Q, true)
	await ticks(2)
	key(KEY_Q, false)
	await ticks(2)
	check(player.skill_casting.active() and events == 0, "saved precise Q retains selection in the resumed main game")
	await shot("precise-circle")
	await click_at(game.world_to_screen(player.global_position + right * 3))
	check(events == 1 and not player.skill_casting.active(), "main-world left-click confirms the selected skill exactly once")
	game._release_actions()
	app.queue_free()
	await ticks(4)
	DirAccess.remove_absolute(Preferences.settings_path)
	Preferences.settings_path = Preferences.DEFAULT_PATH
	print("SKILL_CASTING_VISUAL_RESULT checks=%d failures=%d captures=%d renderer=%s" % [checks, failures, captures, RenderingServer.get_video_adapter_name()])
	quit(0 if failures == 0 else 1)
