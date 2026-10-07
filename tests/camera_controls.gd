extends SceneTree
## Real mouse events, camera geometry, aiming and camera-relative movement.
## Add -- --capture to save GPU views; omit --headless for image capture.
var game: Node
var checks := 0
var failures: Array[String] = []
var capture := false

func _initialize() -> void:
	call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func mouse_button(button: MouseButton, pressed: bool, factor := 1.0) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.factor = factor
	if capture:
		game._unhandled_input(event)
	else:
		Input.parse_input_event(event)
	await ticks(2)

func mouse_motion(delta: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.relative = delta
	event.screen_relative = delta
	event.button_mask = MOUSE_BUTTON_MASK_MIDDLE if game.camera_dragging else 0
	if capture:
		game._unhandled_input(event)
	else:
		Input.parse_input_event(event)
	await ticks(2)

func pitch() -> float:
	return rad_to_deg(asin(game.camera.global_basis.z.y))

func aiming_matches_projection() -> bool:
	var target: Vector3 = game.player.global_position + game.camera_forward() * 4 + Vector3.UP * .3
	var screen: Vector2 = game.world_to_screen(target)
	var recovered: Variant = game.screen_to_world(screen, target.y)
	return recovered != null and recovered.distance_to(target) < .002

func shot(label: String) -> void:
	if not capture:
		return
	await ticks(24)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/camera/" + label + ".png")

func run() -> void:
	capture = "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless"
	if capture:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/camera"))
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	# Capturing the desktop pointer can add OS warp events during a GPU run.
	# Keep the same handler/assertions, isolating scripted events from physical motion.
	if capture:
		game.set_process_unhandled_input(false)
	game.sound.muted = true
	await ticks(24)
	var original_pitch := pitch()
	var original_size: float = game.camera.size
	var original_y: float = game.camera.global_position.y
	check(absf(original_pitch - 34.69515353) < .001, "default downward angle is 34.695 degrees from horizontal")
	await mouse_button(MOUSE_BUTTON_WHEEL_UP, true)
	await ticks(40)
	check(game.camera_height < 17 and game.camera.global_position.y < original_y - 1, "wheel up lowers the actual camera")
	check(game.camera.size < original_size, "orthographic view zooms in with camera height")
	check(absf(pitch() - original_pitch) < .001, "zoom preserves the downward viewing angle")
	await mouse_button(MOUSE_BUTTON_WHEEL_DOWN, true)
	await ticks(40)
	check(absf(game.camera_height - 18) < .01, "wheel down reverses the height change")
	await mouse_button(MOUSE_BUTTON_WHEEL_UP, true, 200)
	await ticks(60)
	check(game.target_camera_height == game.MIN_CAMERA_HEIGHT and absf(game.camera_height - 8) < .01, "zoom in stops at the minimum height")
	check(aiming_matches_projection(), "aim ray matches rendered target when zoomed in")
	await shot("near")
	await mouse_button(MOUSE_BUTTON_WHEEL_DOWN, true, 200)
	await ticks(60)
	check(game.target_camera_height == game.MAX_CAMERA_HEIGHT and absf(game.camera_height - 32) < .01, "zoom out stops at the maximum height")
	check(aiming_matches_projection(), "aim ray matches rendered target when zoomed out")
	await shot("far")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_F2
	key.pressed = true
	game._unhandled_input(key)
	await ticks(2)
	check(absf(game.camera_height - 32) < .01 and absf(game.reflection_camera.size - game.camera.size) < .001, "pixel-resolution switch preserves zoom and reflection scale")
	game._unhandled_input(key)
	game.target_camera_height = 18.0
	await ticks(60)
	var yaw: float = game.camera_yaw
	await mouse_motion(Vector2(400, 300))
	check(is_equal_approx(game.camera_yaw, yaw), "free mouse motion does not rotate the camera")
	await mouse_button(MOUSE_BUTTON_MIDDLE, true)
	check(game.camera_dragging, "middle press begins orbit dragging")
	await mouse_motion(Vector2(360, 0))
	await ticks(60)
	check(absf(angle_difference(yaw, game.camera_yaw) + PI / 2) < .001, "horizontal middle drag rotates camera by yaw")
	yaw = game.camera_yaw
	await mouse_motion(Vector2(0, 500))
	check(is_equal_approx(game.camera_yaw, yaw) and absf(pitch() - original_pitch) < .001, "vertical drag changes neither yaw nor pitch")
	var all_pitches_fixed := true
	var all_aims_match := true
	var all_reflections_match := true
	for quarter in range(4):
		await mouse_motion(Vector2(360, 0))
		await ticks(45)
		all_pitches_fixed = all_pitches_fixed and absf(pitch() - original_pitch) < .001 and absf(game.camera.global_basis.x.y) < .001
		all_aims_match = all_aims_match and aiming_matches_projection()
		var mirrored_forward: Vector3 = -game.camera.global_basis.z
		mirrored_forward.y *= -1
		all_reflections_match = all_reflections_match and mirrored_forward.distance_to(-game.reflection_camera.global_basis.z) < .001
		await shot("orbit_%d" % (quarter * 90))
	check(absf(angle_difference(yaw, game.camera_yaw)) < .001, "full 360 degree drag wraps continuously to the same heading")
	check(all_pitches_fixed, "all orbit quadrants keep the same pitch with zero roll")
	check(all_aims_match, "mouse aiming stays aligned throughout the orbit")
	check(all_reflections_match, "water reflection orientation follows every orbit quadrant")
	await mouse_button(MOUSE_BUTTON_MIDDLE, false)
	check(not game.camera_dragging and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "middle release ends dragging and restores the cursor")
	await mouse_motion(Vector2(250, 50))
	check(absf(angle_difference(yaw, game.camera_yaw)) < .001, "camera stops turning after middle release")
	var player: CharacterBody3D = game.player
	var start := player.global_position
	var screen_forward: Vector3 = game.camera_forward()
	Input.action_press("move_up")
	await ticks(28)
	game._release_actions()
	var travel := player.global_position - start
	check(travel.dot(screen_forward) > 1.8 and absf(travel.dot(game.camera_right())) < .1, "W still moves toward screen top after orbiting")
	await mouse_button(MOUSE_BUTTON_MIDDLE, true)
	game._focus_lost()
	check(not game.camera_dragging and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "focus loss releases the captured mouse")
	await mouse_button(MOUSE_BUTTON_MIDDLE, true)
	key.physical_keycode = KEY_ESCAPE
	game._unhandled_input(key)
	check(game.paused and not game.camera_dragging, "Escape pauses and releases orbit dragging")
	var zoom: float = game.target_camera_height
	await mouse_button(MOUSE_BUTTON_WHEEL_UP, true)
	await mouse_button(MOUSE_BUTTON_MIDDLE, true)
	check(game.target_camera_height == zoom and not game.camera_dragging, "paused camera ignores wheel and middle press")
	game._unhandled_input(key)
	check(not game.hud.visible, "camera controls do not reveal HUD or help text")
	await mouse_button(MOUSE_BUTTON_MIDDLE, true)
	game.queue_free()
	await process_frame
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "quitting while dragging also releases the cursor")
	print("CAMERA_TEST_RESULT %d/%d passed" % [checks - failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
