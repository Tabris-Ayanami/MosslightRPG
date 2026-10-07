extends SceneTree
var app: Node
func _initialize() -> void: call_deferred("run")
func capture(label: String) -> void:
	for i in range(5): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/volume-"+label+".png")
	print("VOLUME_CAPTURE ",label)
func run() -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await process_frame
	app.set_process(false)
	app.menu.hide()
	app.meadow.set_journey(1)
	app.choice.present("new")
	for i in range(100): await process_frame
	await capture("name")
	app.choice.hide()
	for point: float in [.25,.55,.75,.9]:
		app.ascent_cursor=point
		app._sample_ascent()
		await capture("up-%02d"%roundi(point*100))
	app.start_adventure()
	app.journey_cursor=1
	app._process(0)
	app.choice.age=2
	app.choice._confirm()
	app.stage_time=1.4
	app._process(0)
	app._process(5.1)
	while app.stage!=app.Stage.DESCENDING:
		app._process(.05)
		await process_frame
	for point: float in [.5,.9,1.3,1.7,2.1,2.5,3.2]:
		app.stage_time=point
		app._process(0)
		await capture("down-%02d"%roundi(point*10))
	app.queue_free()
	for i in range(20): await process_frame
	quit()
