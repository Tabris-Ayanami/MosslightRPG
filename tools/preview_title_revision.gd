extends SceneTree
var app: Node
var tag := ""
func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count): await process_frame
func capture(label: String) -> void:
	await ticks(5)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/revision-"+label+tag+".png")
	print("CAPTURE ",label)
func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tag="): tag="-"+arg.trim_prefix("--tag=")
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await ticks(20)
	app.set_process(false)
	await capture("title")
	app.menu.hide()
	for i in range(9):
		app.meadow.set_journey(float(i)/8)
		await capture("journey-%d"%i)
	app.choice.present("continue")
	await ticks(125)
	await capture("save")
	app.choice.present("new")
	await ticks(125)
	app.choice.name_input.text="桐人"
	await capture("name")
	app.choice.dissolve()
	await ticks(24)
	await capture("letters-dissolve")
	app.choice.hide()
	for i in range(5):
		app.ascent_cursor=float(i)/5
		app._sample_ascent()
		await capture("sky-%d"%i)
	app.queue_free()
	await ticks(18)
	quit()
