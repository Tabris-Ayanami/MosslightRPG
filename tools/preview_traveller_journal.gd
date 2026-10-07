extends "res://tools/preview_book_ui.gd"

func run() -> void:
	# Use the normal world-entry presenter without reading/writing a player's save.
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	app.set_process(false)
	await ticks(5)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate=Color.WHITE
	app.ui.region_clock=0
	app.ui.close_panel(true)
	app.ui.bind_rpg(null)
	app.ui.selected_item=2
	app.ui.character_tab=0
	app.ui._rebuild_hud_buttons()
	await ticks(10)
	await record_sequence()

func record_sequence() -> void:
	await capture("traveller-hud")
	app.ui.show_panel("bag")
	await capture("traveller-bag")
	# Freeze one real cover/curl frame for layer inspection, then resume normally.
	app.ui.set_process(false)
	app.ui.close_panel()
	app.ui.motion.progress=.19
	app.ui.motion.queue_redraw()
	await ticks(3)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/book-traveller-cover.png")
	app.ui.close_panel(true)
	app.ui.set_process(true)
	app.ui.show_panel("bag")
	await settle(3)
	app.ui.show_panel("character")
	await capture("traveller-character")
	app.ui._select_character_tab(2)
	await capture("traveller-traits")
	app.ui._select_trait(2)
	await capture("traveller-blessing")
	app.ui.show_panel("bag")
	await ticks(2)
	while not app.ui.motion_ready: await process_frame
	app.ui.set_process(false)
	app.ui.motion.progress=.46
	app.ui.motion.queue_redraw()
	await ticks(3)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/book-traveller-curl.png")
	app.ui.set_process(true)
	await settle(3)
	app.ui.close_panel(true)
	app.ui.show_panel("map")
	app.ui.unfolded_map.set_process(false)
	app.ui.unfolded_map.progress=.43
	app.ui.unfolded_map.update_reveal()
	await ticks(3)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/book-traveller-map-opening.png")
	app.ui.unfolded_map.set_process(true)
	await capture("traveller-map")
	app.ui.close_panel(true)
	root.size=Vector2i(960,540)
	app.ui.show_panel("bag")
	await capture("traveller-small")
	app.ui.close_panel(true)
	app.queue_free()
	await ticks(18)
	quit()
