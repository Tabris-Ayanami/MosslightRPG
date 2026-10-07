extends SceneTree
var app: Node
func _initialize() -> void: call_deferred("run")
func wait_stage(value: int) -> void:
	while app.stage!=value: await process_frame
func click(button: Button) -> void:
	var point := button.get_global_transform()*(button.size*.5)
	for down in [true,false]:
		var event := InputEventMouseButton.new()
		event.position=root.get_final_transform()*point
		event.global_position=event.position
		event.button_index=MOUSE_BUTTON_LEFT
		event.pressed=down
		Input.parse_input_event(event)
		await process_frame
func run() -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await create_timer(3.5).timeout
	await click(app.menu.buttons[0])
	await wait_stage(app.Stage.CHOOSING)
	await create_timer(2.1).timeout
	await click(app.choice.buttons[3])
	await wait_stage(app.Stage.PLAYING)
	await create_timer(1.2).timeout
	print("TITLE_POLISH_MOVIE completed real pointer start/save/arrival")
	app.queue_free()
	for i in range(4): await process_frame
	quit()
