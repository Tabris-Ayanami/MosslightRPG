extends SceneTree
var game: Node
func _initialize() -> void:
	call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n): await process_frame
func shot(label: String,local_pos: Vector3,height: float,yaw := .3947911197) -> void:
	game.player.restore(game.GARDEN_ORIGIN+local_pos)
	game.camera_height=height
	game.target_camera_height=height
	game.camera_yaw=yaw
	game.smooth_target=game.player.global_position+game._camera_lead()
	game.aim_override=game.player.global_position+Vector3(10,0,24).normalized()*5
	await ticks(50)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/regions/"+label+".png")
	print("REGION_CAPTURE ",label)
func run() -> void:
	DirAccess.make_dir_recursive_absolute("res://docs/regions")
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted=true
	await ticks(30)
	await shot("garden",Vector3(1.6,2.35,4.8),18)
	await shot("grass-and-flowers",Vector3(-3,2.35,5),9)
	await shot("forest",Vector3(35,2.35,-1),16)
	await shot("forest-clearing",Vector3(41,2.35,3),10)
	await shot("village",Vector3(0,2.35,-39),24)
	await shot("market",Vector3(1,2.35,-38),12)
	await shot("east-bridge",Vector3(18,2.4,1.7),15)
	await shot("north-bridge",Vector3(0,2.4,-17),17)
	await shot("forest-orbit",Vector3(35,2.35,-1),16,PI*.6)
	game.set_process(false)
	game.camera.size=78
	var target=game.GARDEN_ORIGIN+Vector3(22,2,-23)
	game.camera.look_at_from_position(target+Vector3(12,87,84),target)
	# The overview uses a camera outside the normal zoom limits; sync its reflection.
	var reflected_position: Vector3=game.camera.global_position
	reflected_position.y=1.2-reflected_position.y
	var reflected_direction: Vector3=-game.camera.global_basis.z
	reflected_direction.y=-reflected_direction.y
	game.reflection_camera.size=game.camera.size
	game.reflection_camera.look_at_from_position(reflected_position,reflected_position+reflected_direction,Vector3.DOWN)
	game.water_material.set_shader_parameter("reflection_vp",game.reflection_camera.get_camera_projection()*Projection(game.reflection_camera.global_transform.affine_inverse()))
	await ticks(4)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/regions/map-overview.png")
	game.queue_free()
	await process_frame
	quit()
