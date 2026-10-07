extends SceneTree
var app: Node
func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count): await process_frame
func capture(label: String) -> void:
	await ticks(6)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/polish-"+label+".png")
	print("CAPTURE ",label)
func run() -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await ticks(25)
	app.set_process(false)
	await capture("title")
	app.start_adventure()
	await capture("title-disabled")
	app._process(app.JOURNEY_SECONDS+.1)
	await ticks(120)
	await capture("choice")
	app.choice.dissolve()
	await capture("choice-disabled")
	await ticks(100)
	app.choice.hide()
	for i in range(11):
		app.ascent_cursor=float(i)/10
		app._sample_ascent()
		await capture("flight-%02d"%i)
	app.queue_free()
	await ticks(20)
	quit()
