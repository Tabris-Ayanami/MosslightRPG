extends SceneTree
## Real GPU captures, full water/reflection/outline pipeline retained.
var game: Node
func _initialize(): call_deferred("run")
func ticks(n: int):
	for i in range(n): await process_frame
func shot(label: String,yaw: float,size: float):
	var at: Vector3=game.GARDEN_ORIGIN+Vector3(-5,1.1,-2.5)
	game.camera.size=size
	game.camera.look_at_from_position(at+Vector3(0,18,26).rotated(Vector3.UP,yaw),at)
	var reflected: Vector3=game.camera.global_position
	reflected.y=1.2-reflected.y
	var direction: Vector3=-game.camera.global_basis.z
	direction.y=-direction.y
	game.reflection_camera.size=game.camera.size
	game.reflection_camera.look_at_from_position(reflected,reflected+direction,Vector3.DOWN)
	game.water_material.set_shader_parameter("reflection_vp",game.reflection_camera.get_camera_projection()*Projection(game.reflection_camera.global_transform.affine_inverse()))
	await ticks(6)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/terrain-clearance/"+label+".png")
	print("EXCAVATION_CAPTURE ",label)
func run():
	if DisplayServer.get_name()=="headless":
		push_error("Use the GPU for terrain/water captures.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://docs/terrain-clearance")
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted=true
	await ticks(35)
	game.set_process(false)
	game.player.visible=false
	for i in range(4): await shot("after-orbit-%d"%i,.3947911197+i*PI*.5,13.0)
	game.reference_map.get_node("Lake").visible=false
	await shot("after-no-water",.3947911197,13.0)
	game.reference_map.get_node("WaterShrine").visible=false
	await shot("after-terrain-only",.3947911197,13.0)
	game.queue_free()
	await ticks(2)
	quit()
