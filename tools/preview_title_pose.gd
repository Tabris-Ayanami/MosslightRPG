extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await process_frame
	app.set_process(false)
	app.menu.hide()
	app.meadow.camera.fov=30
	app.meadow.camera.look_at_from_position(Vector3(7.5,4.0,6.3),Vector3(3.15,.9,1.0))
	for i in range(11):
		app.meadow.sleeper.apply_pose(float(i)/10)
		for j in range(4): await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://docs/frontend/pose-close-%02d.png"%i)
		print("POSE ",i," CONTACT_MAX ",app.meadow.sleeper.contact_error," ",app.meadow.sleeper.chain_errors)
	app.queue_free()
	for i in range(18): await process_frame
	quit()
