extends SceneTree
## GPU art review. Weather images use explicit coverage presets, not time-lapse.
var game: Node
func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n): await process_frame
func aim(at: Vector3, size: float, yaw := .3947911197) -> void:
	var target: Vector3 = game.GARDEN_ORIGIN + at
	game.camera.size = size
	game.camera.look_at_from_position(target + Vector3(0,18,26).rotated(Vector3.UP,yaw), target)
	var reflected: Vector3 = game.camera.global_position
	reflected.y = 1.2 - reflected.y
	var direction: Vector3 = -game.camera.global_basis.z
	direction.y = -direction.y
	game.reflection_camera.size = size
	game.reflection_camera.look_at_from_position(reflected, reflected + direction, Vector3.DOWN)
	game.water_material.set_shader_parameter("reflection_vp", game.reflection_camera.get_camera_projection() * Projection(game.reflection_camera.global_transform.affine_inverse()))
func save(label: String) -> void:
	await ticks(8)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/roads/" + label + ".png")
	print("ROAD_CAPTURE ", label)
func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Road art review requires the real GPU renderer.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://docs/roads")
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted = true
	game.set_process(false)
	game.player.set_physics_process(false)
	game.player.visible = false
	game.weather.set_process(false)
	await ticks(16)
	aim(Vector3(0,2.2,-29),13)
	await save("entrance")
	aim(Vector3(0,2.2,-39.5),19)
	await save("market")
	aim(Vector3(31,2.2,-1),16)
	await save("woodland")
	aim(Vector3(0,2.2,-29),13,2.7)
	await save("entrance-orbit")
	game.weather.set_weather(2,true)
	game.weather.wetness = 1
	game.weather._process(0)
	aim(Vector3(0,2.2,-29),13)
	await save("wet")
	game.weather.set_weather(4,true)
	game.weather.snow_cover = .7
	game.weather._process(0)
	await save("snow")
	game.weather.set_weather(0,true)
	game.weather.set_time(2,true)
	game.weather.wetness = 0
	game.weather.snow_cover = 0
	game.weather._process(0)
	await save("night")
	game.queue_free()
	await ticks(3)
	quit()
