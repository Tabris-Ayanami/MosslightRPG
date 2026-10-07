extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	app.set_process(false)
	app.menu.hide()
	app.meadow.camera.fov=36
	var flight=app.FLIGHT
	app.meadow.camera.look_at_from_position(flight.SUBJECT+Vector3(6.35,5.4,6.2),flight.SUBJECT+Vector3(0,1.7,0))
	for i in range(15): await process_frame
	for i in range(505):
		var time := float(i)/30
		app.meadow.sleeper.apply_time(time)
		var target: Vector3=flight.SUBJECT+flight.FORWARD*flight.STORY.distance_at(time)
		app.meadow.camera.look_at_from_position(target+Vector3(6.35,5.4,6.2),target+Vector3(0,1.7,0))
		await process_frame
	for i in range(15): await process_frame
	app.queue_free()
	await process_frame
	quit()
