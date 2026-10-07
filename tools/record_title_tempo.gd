extends SceneTree
## Fixed-FPS capture through the normal title, naming, loading and arrival path.
var app: Node
func _initialize() -> void: call_deferred("run")
func frames(count: int) -> void:
	for i in range(count): await process_frame
func shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/tempo-"+name+".png")
func run() -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	var directory := ProjectSettings.globalize_path("res://.work/title-tempo/preview-saves-")+str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(directory)
	app.saves=app.SAVE_REPOSITORY.new(directory)
	root.add_child(app)
	await frames(20)
	await shot("rest")
	app.new_adventure()
	var marks := [15,36,66,105,150,179]
	var frame := 0
	while app.stage==app.Stage.JOURNEY:
		await frames(1)
		frame+=1
		if frame in marks: await shot("rise-%03d"%frame)
	await frames(40)
	await shot("sky")
	app.choice.name_input.text="风中的旅人"
	app.choice.age=2
	app.choice._confirm()
	await frames(15)
	await shot("departure")
	var limit := 0
	while app.stage!=app.Stage.PLAYING and limit<900:
		await frames(1)
		limit+=1
	if app.stage!=app.Stage.PLAYING:
		push_error("Title tempo preview did not reach gameplay")
		quit(1)
		return
	await frames(20)
	print("TITLE_TEMPO_MOVIE completed new-adventure / naming / clouds / world arrival")
	app.queue_free()
	await frames(4)
	quit()
