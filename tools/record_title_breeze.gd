extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	for i in range(240): await process_frame
	app.queue_free()
	for i in range(4): await process_frame
	quit()
