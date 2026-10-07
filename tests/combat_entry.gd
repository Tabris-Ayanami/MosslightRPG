extends SceneTree
## Verify the actual title button, scene transition and return button.
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func frames(count: int) -> void:
	for i in range(count):
		await process_frame
		await physics_frame

func verify(value: bool, label: String) -> void:
	print("PASS " if value else "FAIL ", label)
	if not value:
		failures.append(label)

func run() -> void:
	var app: Node = load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	await frames(4)
	verify(app.menu.combat_button.visible and not app.menu.combat_button.disabled, "title exposes enabled combat arena entry")
	app.menu.combat_button.pressed.emit()
	await frames(6)
	var arena := current_scene
	verify(arena.scene_file_path == "res://scenes/demo/CombatTestArena.tscn", "title button enters shipped arena")
	verify(arena.player.loadout.level == 0 and arena.ui.menu_open, "arena opens Lv0 career choice")
	var return_button: Button
	for node in arena.ui.find_children("*", "Button", true, false):
		if node.text == "返回标题":
			return_button = node
	verify(return_button != null, "arena menu includes return to title")
	if return_button:
		return_button.pressed.emit()
		await frames(6)
		verify(current_scene.scene_file_path == "res://scenes/frontend/app.tscn", "return button loads original frontend")
	current_scene.queue_free()
	await frames(2)
	print("COMBAT_ENTRY: 5 checks; %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
