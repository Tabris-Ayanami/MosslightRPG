extends SceneTree
## Production main-world rendering; real W / Space events and post-draw traces.
const OUTPUT := "res://docs/traversal/"
var app: Node
var game: Node
var actor: Node
var checks := 0
var failures := 0
var report: PackedStringArray = []
var traces: Dictionary = {}
var captures := 0
var frame_root := ""

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	var line := ("PASS " if ok else "FAIL ") + label
	print(line)
	report.append(line)

func key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await RenderingServer.frame_post_draw

func xyz(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func xy(v: Vector2) -> Array:
	return [v.x, v.y]

func capture(label: String) -> void:
	var image := root.get_texture().get_image()
	check(image.save_png(OUTPUT + "continuous_" + label + ".png") == OK, "capture " + label)
	captures += 1

func route(x: float, height: float, dash: bool) -> void:
	game._release_actions()
	actor.restore(game.GARDEN_ORIGIN + Vector3(x, -.1, 13.4))
	game.camera_yaw = 0
	game.target_camera_height = height
	await ticks(75)
	var label := "%s_%sm_%s" % ["stairs" if x > 1 else "leftbank", int(height), "space" if dash else "walk"]
	var record := (x > 1 and height == 18 and not dash) or (x == 0 and height == 8 and dash)
	var directory := frame_root.path_join(label)
	if record: DirAccess.make_dir_recursive_absolute(directory)
	var rows: Array = []
	var maximum_screen := 0.0
	var maximum_world := 0.0
	var maximum_frame := 0
	var dodge_frames := 0
	var middle_captured := false
	var prior: Vector3 = actor.global_position
	var prior_screen: Vector2 = game.world_to_screen(prior)
	var initial_hp: float = actor.resources.current("HP")
	var record_count := 0
	capture(label + "_before")
	key(KEY_W, true)
	for frame in range(300):
		if dash: key(KEY_SPACE, frame % 36 == 2)
		await ticks(1)
		var position: Vector3 = actor.global_position
		var screen: Vector2 = game.world_to_screen(position)
		var screen_step := screen.distance_to(prior_screen)
		var world_step := position.distance_to(prior)
		if screen_step > maximum_screen:
			maximum_screen = screen_step
			maximum_frame = frame
		maximum_world = maxf(maximum_world, world_step)
		if actor.combat.state == "DODGE": dodge_frames += 1
		rows.append({"frame": frame, "world": xyz(position - game.GARDEN_ORIGIN), "foot_screen": xy(screen), "head_screen": xy(game.world_to_screen(position + Vector3.UP * 1.5)), "screen_step": screen_step, "world_step": world_step, "camera": xyz(game.camera.global_position), "snap": xy(game.snap_offset), "state": actor.combat.state, "traversal": actor.surface_traversal.active, "swimming": actor.swimming, "wading": actor.wading})
		if not middle_captured and position.y > .55:
			capture(label + "_slope")
			middle_captured = true
		if record and frame % 2 == 0:
			root.get_texture().get_image().save_png(directory.path_join("frame_%04d.png" % record_count))
			record_count += 1
		prior = position
		prior_screen = screen
		if position.z - game.GARDEN_ORIGIN.z < 8.2: break
	key(KEY_W, false)
	key(KEY_SPACE, false)
	await ticks(2)
	check(actor.global_position.z - game.GARDEN_ORIGIN.z < 8.2 and not actor.swimming and not actor.wading, label + " reaches the dry bank through real input")
	check(not dash or dodge_frames > 0, label + " enters actual Space dodge when requested")
	check(is_equal_approx(initial_hp, actor.resources.current("HP")), label + " preserves HP")
	check(middle_captured, label + " captures the visible intermediate slope position")
	var scale := 18.0 / height
	check(maximum_screen < (20.0 if dash else 14.0) * scale, label + " has no large screen-space teleport")
	capture(label + "_after")
	var summary := "TRACE %s frames=%d max_screen=%.4fpx at=%d max_world=%.5fm dodge_frames=%d" % [label, rows.size(), maximum_screen, maximum_frame, maximum_world, dodge_frames]
	print(summary)
	report.append(summary)
	traces[label] = {"camera_height": height, "frames": rows.size(), "max_screen_step": maximum_screen, "max_world_step": maximum_world, "max_screen_frame": maximum_frame, "dodge_frames": dodge_frames, "frames_directory": directory if record else "", "recorded_frames": record_count, "rows": rows}

func run() -> void:
	root.size = Vector2i(1920, 1080)
	check(DisplayServer.get_name() != "headless", "GPU is active")
	app = load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	await ticks(3)
	app._finish_arrival()
	game = app.game
	actor = game.player
	app.ui.close_panel(true)
	app.ui.region_clock = 0
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	frame_root = OS.get_temp_dir().path_join("mosslight_shore_frames_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(frame_root)
	for height in [18.0, 8.0]:
		for x in [2.5, 0.0]:
			for dash in [false, true]:
				await route(x, height, dash)
	var result := "SHORE_MOTION_VISUAL_RESULT checks=%d failures=%d captures=%d routes=%d" % [checks, failures, captures, traces.size()]
	print(result)
	report.append(result)
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("Physics interpolation: " + str(ProjectSettings.get_setting("physics/common/physics_interpolation")))
	report.append("Frame root: " + frame_root)
	var file := FileAccess.open(OUTPUT + "continuous_render_trace.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(traces, "\t"))
	file.close()
	file = FileAccess.open(OUTPUT + "continuous_visual_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	file.close()
	game._release_actions()
	app.queue_free()
	await ticks(4)
	quit(0 if failures == 0 else 1)
