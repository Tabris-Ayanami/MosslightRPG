extends SceneTree
## Deterministic GPU evidence from the saved production map; never rebuilds it.
var game: Node
var output := "res://docs/canopy-refinement"

func _initialize() -> void:
	call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await process_frame

func shot(label: String, position: Vector3, height: float, yaw := 0.3947911197, time := 0, wind := 0, weather := 0, focus: Variant = null, wind_phase := 12.0) -> void:
	game.set_process(true)
	game.player.restore(game.GARDEN_ORIGIN + position)
	game.player.set_physics_process(false)
	game.camera_height = height
	game.target_camera_height = height
	game.camera_yaw = yaw
	game.smooth_target = game.player.global_position + game._camera_lead()
	game.weather.clock = 10.0
	game.weather.wind_phase = wind_phase
	game.weather.set_time(time, true)
	game.weather.set_weather(weather, true)
	game.weather.set_wind(wind, true)
	game.weather.snow_cover = 0.85 if weather == 4 else 0.0
	game.weather.wetness = 0.45 if weather == 4 else 0.0
	game.weather._apply_environment()
	await ticks(25)
	game.set_process(false)
	if focus != null:
		# Keep the complete crown in frame while retaining the game's actual
		# pixel snapping, outline pass, reflection, and orthographic projection.
		game.smooth_target = focus
		game._process(0.0)
	await ticks(4)
	await RenderingServer.frame_post_draw
	var capture := root.get_texture().get_image()
	var destination := output.path_join(label + ".png")
	var error := capture.save_png(destination)
	if error != OK:
		push_error("Could not save " + destination)
		quit(1)
	print("CANOPY_CAPTURE ", label, " ", capture.get_size(), " ", destination)
	if label == "forest-close":
		await measure_performance()

func measure_performance() -> void:
	var cpu_ms := 0.0
	var gpu_ms := 0.0
	var frame_ms := 0.0
	var objects := 0.0
	var draw_calls := 0.0
	var viewport_rid: RID = game.viewport.get_viewport_rid()
	var previous := Time.get_ticks_usec()
	for i in range(24):
		await process_frame
		var now := Time.get_ticks_usec()
		frame_ms += float(now - previous) / 1000.0
		previous = now
		cpu_ms += float(RenderingServer.call("viewport_get_measured_render_time_cpu", viewport_rid))
		gpu_ms += float(RenderingServer.call("viewport_get_measured_render_time_gpu", viewport_rid))
		objects += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		draw_calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var metrics := {
		"capture": "forest-close", "samples": 24,
		"frame_interval_ms": frame_ms / 24.0,
		"main_viewport_render_cpu_ms": cpu_ms / 24.0,
		"main_viewport_render_gpu_ms": gpu_ms / 24.0,
		"total_rendered_objects": objects / 24.0,
		"total_draw_calls": draw_calls / 24.0,
		"note": "24 stationary frames, weather frozen; CPU/GPU measurements cover the main 3D viewport."
	}
	var report := FileAccess.open(output.path_join("performance.json"), FileAccess.WRITE)
	if report:
		report.store_string(JSON.stringify(metrics, "\t"))
	print("CANOPY_PERFORMANCE ", JSON.stringify(metrics))

func orchard_shot(label: String, height := 8.0, yaw := 0.3947911197, time := 0, wind := 0, weather := 0, wind_phase := 12.0) -> void:
	var tree: Node3D = game.reference_map.get_node("AncientTrees/BranchingTree_184")
	var tree_height: float = tree.get_meta("tree_height", 6.2)
	var focus := tree.global_position + Vector3(0, tree_height * 0.58, 0)
	await shot(label, tree.global_position - game.GARDEN_ORIGIN, height, yaw, time, wind, weather, focus, wind_phase)

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Canopy screenshots require the GPU.")
		quit(1)
		return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	root.size = Vector2i(1280, 720)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted = true
	game.show_interface = false
	game.hud.hide()
	game.player.hide()
	# Freeze gameplay while capturing the real map; unrelated actor ticks can
	# move NPCs between runs and are not part of this vegetation comparison.
	for actor: Node in game.world.find_children("*", "CharacterBody3D", true, false):
		actor.set_physics_process(false)
	game.weather.set_process(false)
	game.weather.automatic_day_cycle = false
	game._resize()
	RenderingServer.call("viewport_set_measure_render_time", game.viewport.get_viewport_rid(), true)
	await ticks(30)
	print("CANOPY_SCENE_LOADED")
	await shot("forest-close", Vector3(41, 2.35, 3), 10.0)
	await shot("forest-wide", Vector3(35, 2.35, -1), 16.0)
	await shot("garden", Vector3(1.6, 2.35, 4.8), 13.0)
	await orchard_shot("orchard-close")
	if not "--quick" in OS.get_cmdline_user_args():
		for direction in range(4):
			await orchard_shot("orchard-orbit-%02d" % direction, 8.0, 0.3947911197 + TAU * direction / 4.0)
		await orchard_shot("orchard-zoom-8", 8.0)
		await orchard_shot("orchard-zoom-32", 32.0)
		await orchard_shot("orchard-dusk", 8.0, 0.3947911197, 1)
		await orchard_shot("orchard-night", 8.0, 0.3947911197, 2)
		await orchard_shot("orchard-gale", 8.0, 0.3947911197, 0, 2)
		await orchard_shot("orchard-gale-next", 8.0, 0.3947911197, 0, 2, 0, 12.6)
		await orchard_shot("orchard-snow", 8.0, 0.3947911197, 0, 0, 4)
	print("CANOPY_SHOWCASE_COMPLETE")
	game.queue_free()
	game = null
	await ticks(12)
	quit()
