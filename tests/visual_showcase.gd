extends SceneTree
var game: Node
func _initialize() -> void:
	call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await process_frame
func shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path)
func run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted = true
	game.aim_override = game.player.global_position + Vector3(10,0,24).normalized()*5
	await ticks(90)
	await shot("res://docs/preview.png")
	game.camera_height = 9
	game.target_camera_height = 9
	await ticks(60)
	await shot("res://docs/character-in-garden.png")
	game.player.charge_kind = "bow"
	await ticks(35)
	await shot("res://docs/character/bow-in-game.png")
	game.player.cancel_charge()
	game.player._swing(true)
	await ticks(10)
	await shot("res://docs/character/sword-in-game.png")
	print("VISUAL_SHOWCASE_SAVED")
	game.queue_free()
	await process_frame
	quit()
