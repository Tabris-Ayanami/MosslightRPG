extends SceneTree
var game: Node
func _initialize(): call_deferred("run")
func ticks(n):
	for i in range(n): await process_frame
func shot(label: String,at: Vector3,height: float,yaw: float=.3947911197):
	game.player.restore(game.GARDEN_ORIGIN+at)
	game.camera_height=height
	game.target_camera_height=height
	game.camera_yaw=yaw
	game.smooth_target=game.player.global_position+game._camera_lead()
	await ticks(65)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/environment-revision/"+label+".png")
	print("ENVIRONMENT_CAPTURE ",label)
func run():
	DirAccess.make_dir_recursive_absolute("res://docs/environment-revision")
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted=true
	await ticks(40)
	await shot("garden",Vector3(1.6,2.35,4.8),18)
	await shot("clear-shore",Vector3(2.5,2.35,7.5),10)
	await shot("forest-variety",Vector3(35,2.35,-1),16)
	await shot("fruit-and-flowers",Vector3(41,2.35,3),9)
	await shot("forest-reverse",Vector3(35,2.35,-1),16,PI*1.25)
	await shot("village",Vector3(2,2.35,-37),20)
	await shot("river-bank",Vector3(23,2.35,1.7),15)
	for i in range(5):
		await shot("moving-edge-%02d"%i,Vector3(3+i*1.8,2.35,-44),18)
	game.queue_free()
	await ticks(2)
	quit()
