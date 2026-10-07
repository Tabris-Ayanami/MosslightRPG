extends "res://tools/preview_book_ui.gd"
## Reproducible footage from the actual Godot book. -- --record-book
func flip_samples(label: String) -> void:
	await ticks(2)
	while not app.ui.motion_ready: await process_frame
	for amount in [.18,.36,.55,.74]:
		while app.ui.is_animating() and app.ui.motion.progress<amount: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://docs/frontend/reader-"+label+"-%02d.png"%roundi(amount*100))
	await settle(18)

func record_sequence() -> void:
	await ticks(8)
	print("READER_MOVIE_START ",Engine.get_frames_drawn())
	app.ui.show_panel("character")
	await settle(35)
	app.ui.show_panel("bag")
	await flip_samples("forward")
	app.ui._select_inventory_tab(2)
	await settle(18)
	app.ui._select_inventory_tab(0)
	await flip_samples("backward")
	app.ui.show_panel("character")
	await settle(12)
	app.ui._select_character_tab(1)
	await settle(48)
	app.ui._choose_career("warrior")
	await ticks(40)
	app.ui._choose_career("swordsman")
	await ticks(45)
	app.ui.show_panel("skills")
	await settle(20)
	app.ui._open_ink()
	await ticks(34)
	app.ui._assign_ink(4)
	await ticks(26)
	app.ui.close_panel()
	await settle(22)
	print("READER_MOVIE_END ",Engine.get_frames_drawn())
	app.queue_free()
	await ticks(3)
	quit()
