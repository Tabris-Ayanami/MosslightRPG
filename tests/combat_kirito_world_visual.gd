extends "res://tests/combat_charge_visual.gd"
## Actual main-world + pixel arena rendering, using production frontend and actors.
var app
var game
var foe
var hit_count := 0

func clear_pointer() -> void:
	var event := InputEventMouseMotion.new()
	event.position = POINTER
	event.global_position = POINTER
	Input.parse_input_event(event)
	await tick(3)

func watch_action(label: String, template: String = "") -> void:
	var left := false
	var right := false
	var frames := 0
	while arena.player.combat.runner.busy() and frames < 140:
		await tick()
		await RenderingServer.frame_post_draw
		var visual = arena.player.animation
		if visual._second_blade_trail.visible and visual.dual_pose_progress[1] >= .30 and not left:
			left = true
			await capture(label + "_left_b_1280")
		if visual._blade_trail.visible and visual.dual_pose_progress[0] >= .30 and not right:
			right = true
			await capture(label + "_right_a_1280")
		frames += 1
	verify(left and right, label + " both real hand-held sword segments render")
	if not template.is_empty():
		verify(arena.player.animation.dual_template == template, label + " renders shared " + template + " template")
	verify(arena.player.animation.hand_attachment_error < .001, label + " hand bones retain sword attachments")

func prepare_drill(kind: String) -> void:
	for action in InputMap.get_actions():
		Input.action_release(action)
	arena.defense_drill(kind)
	arena.ui.toggle_menu(false)
	arena.ui._toast_time = 0
	arena.toast_time = 0
	foe = arena.enemies[0]
	foe.ai_enabled = false
	foe.resources.configure("HP", 100000)
	arena.aim_override = foe.global_position
	await clear_pointer()
	await tick(12)

func run() -> void:
	root.size = Vector2i(1280, 720)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await tick(3)
	# Skip only cinematic elapsed time. Use the real frontend's arrival/binding path.
	app._enter_world(load("res://scenes/main.tscn"))
	await tick(3)
	app._finish_arrival()
	game = app.game
	arena = game.combat_world
	var player = game.player
	verify(is_instance_valid(player.animation.kirito), "main world uses the shared original Kirito actor")
	verify(player.loadout.combat_weapon().is_empty() and not player.animation._weapon.visible, "new Lv0 protagonist has no placeholder weapon in empty slots")
	verify(player.progression.choose_career("warrior"), "main world chooses warrior through normal progression")
	app.ui.close_panel(true)
	await clear_pointer()
	await tick(70)
	verify(game.pixel_material.shader.resource_path == "res://shaders/upscale.gdshader" and game.post_material.shader.resource_path == "res://shaders/reference_outline.gdshader", "main world retains original pixel upscale and outline shaders")
	await capture("kirito_main_world_default_1280")
	player.progression.add_experience(100000)
	verify(player.progression.choose_career("swordsman") and player.progression.choose_career("dual_swordsman"), "main world dual swords unlock through progression careers")
	verify(player.progression.learn_skill("warrior_whirlwind"), "main world learns real whirlwind skill")
	verify(player.loadout.assign_skill(0, 0, "warrior_whirlwind"), "main world assigns learned whirlwind to Q")
	for enemy in arena.enemies:
		enemy.set_physics_process(false)
	foe = arena.spawn_enemy("soldier", player.global_position + Vector3(.9, 0, -1.05))
	foe.set_physics_process(false)
	foe.resources.configure("HP", 100000)
	arena.locked_target = foe
	game.aim_override = foe.global_position
	game.camera_height = 8
	game.target_camera_height = 8
	await tick(36)
	verify(player.loadout.is_dual_wielding(), "main world simultaneously holds both swords")
	await capture("kirito_main_dual_ready_1280")
	frame_directory = OS.get_environment("TEMP").path_join("mosslight_kirito_world_frames_%d" % int(Time.get_unix_time_from_system()))
	DirAccess.make_dir_recursive_absolute(frame_directory)
	RenderingServer.frame_post_draw.connect(record_frame)
	recording = true
	await tick(10)
	player.combat.damage_dealt.connect(func(_result: Dictionary): hit_count += 1)
	await mouse(true)
	await mouse(false)
	await watch_action("kirito_main_weapon")
	verify(hit_count == 2, "main world mouse attack causes both actual sword hits")
	await tick(12)
	await key(KEY_Q, true)
	await key(KEY_Q, false)
	await watch_action("kirito_main_spin", "spin")
	verify(hit_count == 4, "main world Q adds two real skill hits")
	await tick(15)
	recording = false
	# The actual laboratory uses the same camera contract and the same visual class.
	app.queue_free()
	await tick(6)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	await tick(5)
	await prepare_drill("shield")
	verify(is_instance_valid(arena.player.animation.kirito), "arena default hero is the same Kirito adapter")
	verify(is_equal_approx(arena.renderer.camera_pitch_degrees, 34.69515353) and arena.renderer.pixel_material.shader.resource_path == "res://shaders/upscale.gdshader", "arena shares the main world camera pitch and pixel shader")
	await capture("kirito_arena_default_1280")
	arena.renderer.camera_height = 8
	arena.renderer.target_camera_height = 8
	await tick(24)
	recording = true
	await mouse(true, true)
	verify(arena.player.animation.precision_glow_active, "real right press opens precise glow on Kirito")
	await capture("kirito_arena_shield_precise_1280")
	await tick(20)
	verify(arena.player.combat.state == "GUARD" and not arena.player.animation.precision_glow_active, "held shield becomes ordinary guard with original clothes visible")
	await capture("kirito_arena_shield_hold_1280")
	await mouse(false, true)
	await tick(15)
	await prepare_drill("counter")
	await key(KEY_R, true)
	await key(KEY_R, false)
	await tick(22)
	verify(arena.player.animation.current_animation == "counter_stance_ready", "real R raises the actual Kirito fujian stance")
	await capture("kirito_arena_fujian_ready_1280")
	verify(foe.combat.use_action(foe.enemy_action), "real enemy action attacks the fujian stance")
	var waited := 0
	while arena.player.combat.runner.current_action.get("id", "") != "fujian_counter" and waited < 90:
		await tick()
		waited += 1
	verify(arena.player.combat.runner.current_action.get("id", "") == "fujian_counter", "incoming attack triggers actual counter reaction")
	await tick(6)
	await capture("kirito_arena_fujian_counter_1280")
	await tick(35)
	await prepare_drill("dual")
	await mouse(true)
	await wait_charge(.7)
	verify(arena.player.combat.state == "CHARGING", "real held input shows dual charging on Kirito")
	await capture("kirito_arena_charge_1280")
	await mouse(false)
	await watch_action("kirito_arena_charge_release")
	await tick(15)
	recording = false
	root.size = Vector2i(960, 540)
	await tick(5)
	await capture("kirito_arena_960")
	var summary := "COMBAT_KIRITO_WORLD_RESULT checks=%d failures=%d captures=%d" % [checks, failures, images.size()]
	print(summary)
	report.append(summary)
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("VideoFrames: " + frame_directory)
	report.append("RecordedFrames: %d at 30 fps" % recorded_frames)
	var file := FileAccess.open(OUTPUT + "kirito_world_visual_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	quit(0 if failures == 0 else 1)
