extends SceneTree
## Inspect the actual baked title pose, cloth, get-up and reverse playback.
const OUT := "res://docs/title-rest/"
var app: Node
func _initialize() -> void: call_deferred("run")
func frames(count: int) -> void:
	for i in range(count): await process_frame
func shot(label: String) -> void:
	await frames(6)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUT+label+".png")
func run() -> void:
	root.size=Vector2i(1280,720)
	DirAccess.make_dir_recursive_absolute(OUT)
	app=load("res://scenes/frontend/app.tscn").instantiate()
	var isolated := OS.get_temp_dir().path_join("title-rest-%d"%Time.get_ticks_usec())
	app.saves=app.SAVE_REPOSITORY.new(isolated)
	root.add_child(app)
	app.set_process(false)
	await shot("01-title")
	var actor: Node3D=app.meadow.sleeper
	app.menu.hide()
	app.meadow.camera.look_at_from_position(actor.position+Vector3(0,6,0),actor.position,Vector3.FORWARD)
	app.meadow.camera.fov=40
	await shot("02-overhead")
	app.meadow.camera.look_at_from_position(actor.position+Vector3(4,3.1,3.6),actor.position+Vector3(0,.30,.02))
	await shot("03-rest-side")
	for seconds in [.5,.7,1.0,1.5,2.4,4.2]:
		actor.apply_time(seconds)
		await shot("04-rise-%03d"%roundi(seconds*100))
	app.meadow.set_journey(0)
	app.menu.show()
	app.new_adventure()
	app._process(.60)
	await shot("05-camera-with-rise")
	app.cancel_journey()
	app._process(.61)
	await shot("06-returned-rest")
	print("TITLE_REST_PREVIEW real baked title, get-up, camera and cancellation captured")
	app.queue_free()
	await frames(12)
	quit()
