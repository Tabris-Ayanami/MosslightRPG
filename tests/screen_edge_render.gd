extends SceneTree
## Same animated world, same GPU frame, normal and expanded frustums.
## Compare actual alpha foliage, water and postprocess at the screen edge.
var game: Node
var failed := 0
func _initialize(): call_deferred("run")
func ticks(n):
	for i in range(n): await process_frame
func run():
	if DisplayServer.get_name() == "headless":
		push_error("Screen-edge render regression requires GPU.")
		quit(1)
		return
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted = true
	await ticks(40)
	if "--night-gale" in OS.get_cmdline_user_args():
		game.weather.set_time(2,true)
		game.weather.set_wind(2,true)
	game.set_process(false)
	game.player.visible = false
	# Remove effects whose output intentionally depends on the viewport bounds.
	game.reflection_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	game.garden_environment.ssao_enabled = false
	game.garden_sun.shadow_enabled = false
	game.water_material.set_shader_parameter("use_reflection", false)
	game.water_material.set_shader_parameter("refraction_pixels", 0.0)
	var normal_size := Vector2i(644, 364)
	game.viewport.size = normal_size
	game.camera.size = 23.0
	var expanded := SubViewport.new()
	expanded.size = normal_size + Vector2i(256, 256)
	expanded.world_3d = game.viewport.find_world_3d()
	expanded.mesh_lod_threshold = 0.0
	expanded.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(expanded)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = 23.0 * 620.0 / 364.0
	camera.near = game.camera.near
	camera.far = game.camera.far
	camera.environment = game.garden_environment
	expanded.add_child(camera)
	camera.current = true
	var targets: Array[Vector3] = [Vector3(3,2.2,-44), Vector3(11,2.2,-44), Vector3(1.6,2.2,0), Vector3(40,2.2,3)]
	for i in range(targets.size()):
		var at: Vector3 = game.GARDEN_ORIGIN + targets[i]
		game.camera.look_at_from_position(at + Vector3(10,18,24), at)
		camera.global_transform = game.camera.global_transform
		await ticks(8)
		await RenderingServer.frame_post_draw
		var normal: Image = game.viewport.get_texture().get_image()
		var wide: Image = expanded.get_texture().get_image()
		var mismatches := 0
		var compared := 0
		for y in range(3, normal_size.y - 3):
			for x in range(3, normal_size.x - 3):
				if x > 52 and x < normal_size.x - 52 and y > 52 and y < normal_size.y - 52: continue
				var a := normal.get_pixel(x, y)
				var b := wide.get_pixel(x + 128, y + 128)
				compared += 1
				if Vector3(a.r,a.g,a.b).distance_to(Vector3(b.r,b.g,b.b)) > .1: mismatches += 1
		var ok := mismatches < float(compared) * .005
		if not ok: failed += 1
		print("PASS " if ok else "FAIL ", "screen edge pose ", i, ": ", mismatches, "/", compared, " differing material pixels")
	print("SCREEN_EDGE_RESULT ", targets.size() - failed, "/", targets.size())
	expanded.queue_free()
	await ticks(2)
	game.queue_free()
	await ticks(3)
	quit(1 if failed else 0)
