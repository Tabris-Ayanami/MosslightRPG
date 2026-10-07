extends SceneTree
var app: Node
func _initialize() -> void: call_deferred("run")
func snap(path: String) -> void:
	for i in range(5): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/"+path+".png")
func run() -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	app.set_process(false)
	app.menu.hide()
	app.meadow.camera.fov=34
	app.meadow.camera.look_at_from_position(Vector3(8,4.6,5.7),Vector3(3.15,1.25,.8))
	var actor: Node3D=app.meadow.sleeper
	for t in [5.4,6.4,6.9,7.5,8.6,10.0]:
		actor.apply_time(t)
		await snap("story-pose-%02d"%roundi(t*10))
		print("STORY_POSE ",t," attached=",actor.sword_attached," grip=",actor.sword.position)
	for t in [11.0,12.0,13.0]:
		actor.apply_time(t)
		var target: Vector3=app.FLIGHT.SUBJECT+app.FLIGHT.FORWARD*app.FLIGHT.STORY.distance_at(t)
		app.meadow.camera.look_at_from_position(target+Vector3(4.85,4.6,4.9),target+Vector3(0,1.25,0))
		await snap("story-pose-%02d"%roundi(t*10))
	# Freeze the shared clock to compare actual blade silhouettes and compositing.
	app.menu.show()
	app.meadow.set_journey(0)
	for t in [0.0,1.25,2.5]:
		app.total_time=t
		app._process(0)
		await snap("story-breeze-%02d"%roundi(t*10))
	app.shadow_view.get_texture().get_image().save_png("res://docs/frontend/story-grass-mask.png")
	app.queue_free()
	for i in range(12): await process_frame
	quit()
