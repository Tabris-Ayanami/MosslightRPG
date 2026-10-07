extends SceneTree
## GPU visual comparison of transparent water, bottom detail and reflections.
var game: Node
func _initialize(): call_deferred("run")
func ticks(n):
	for i in range(n): await process_frame
func water_value(key: StringName) -> Variant:
	var value: Variant = game.water_material.get_shader_parameter(key)
	if value == null:
		value = RenderingServer.shader_get_parameter_default(game.water_material.shader.get_rid(), key)
	return value
func shot(label: String, at: Vector3, height: float, yaw: float = .3947911197):
	game.player.restore(game.GARDEN_ORIGIN + at)
	# Skip the respawn blink for still-image comparison.
	game.player.invulnerable = 0.0
	game.camera_height = height
	game.target_camera_height = height
	game.camera_yaw = yaw
	game.smooth_target = game.player.global_position + game._camera_lead()
	await ticks(55)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/clear-water/" + label + ".png")
	print("CLEAR_WATER_CAPTURE ", label)
func run():
	if DisplayServer.get_name() == "headless":
		push_error("Water screenshots need a GPU.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://docs/clear-water")
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted = true
	await ticks(40)
	print("LOADED_WATER absorption=", water_value("absorption"), " reflection=", water_value("reflection_strength"), " tint=", water_value("water_tint"))
	await shot("garden", Vector3(1.6,2.35,4.8), 18)
	await shot("shore", Vector3(2.5,2.35,7.5), 10)
	var reflection: Image = game.reflection_viewport.get_texture().get_image()
	var empty := 0
	var solid := 0
	for y in range(reflection.get_height()):
		for x in range(reflection.get_width()):
			var alpha := reflection.get_pixel(x,y).a
			if alpha < .01: empty += 1
			elif alpha > .99: solid += 1
	print("REFLECTION_ALPHA empty=",empty," opaque=",solid)
	# Capture the actual bed at the same angle to expose excessive colour loss.
	game.reference_map.get_node("Lake").visible = false
	await ticks(3)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/clear-water/shore-without-water.png")
	game.reference_map.get_node("Lake").visible = true
	await shot("bridge", Vector3(23,2.35,1.7), 15)
	await shot("reverse", Vector3(2.5,2.35,7.5), 12, PI * 1.25)
	game.queue_free()
	await ticks(3)
	quit()
