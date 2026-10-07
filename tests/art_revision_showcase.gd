extends SceneTree
## Captures the saved production scene at close zoom and around the inn.
var game: Node
func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n): await process_frame
func shot(label: String,pos: Vector3,height: float,yaw := .3947911197) -> void:
	game.player.restore(game.GARDEN_ORIGIN+pos)
	game.camera_height=height
	game.target_camera_height=height
	game.camera_yaw=yaw
	game.smooth_target=game.player.global_position+game._camera_lead()
	await ticks(65)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/art-revision/"+label+".png")
	print("ART_CAPTURE ",label)
func run() -> void:
	DirAccess.make_dir_recursive_absolute("res://docs/art-revision")
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted=true
	await ticks(60)
	await shot("open-crowns",Vector3(41,2.35,3),10)
	await shot("forest",Vector3(35,2.35,-1),16)
	await shot("forest-orbit",Vector3(35,2.35,-1),16,PI*1.25)
	await shot("garden",Vector3(1.6,2.35,4.8),18)
	if "--canopy-orbit" in OS.get_cmdline_user_args():
		for i in range(8):
			await shot("canopy-orbit-%02d"%i,Vector3(41,2.35,3),10,.3947911197+TAU*i/8.0)
		for height in [8.0,32.0]:
			await shot("canopy-zoom-%d"%height,Vector3(41,2.35,3),height)
		game.compact_pixels=true
		game._resize()
		await shot("canopy-480p",Vector3(41,2.35,3),10)
	if "--trees-only" in OS.get_cmdline_user_args():
		game.queue_free()
		await process_frame
		quit()
		return
	for i in range(12):
		await shot("roof-orbit-%02d"%i,Vector3(-6,2.35,-49),12,.3947911197+TAU*i/12.0)
	for height in [8.0,18.0,32.0]:
		await shot("roof-zoom-%d"%height,Vector3(-6,2.35,-49),height)
	for i in range(4):
		await shot("roof-move-%02d"%i,Vector3(-6+.3*i,2.35,-48+.25*i),9)
	game.queue_free()
	await process_frame
	quit()
