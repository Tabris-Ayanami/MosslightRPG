extends SceneTree
## An unbound presenter preserves the original art fixture for exact GPU comparison.
var app: Node

func _initialize() -> void:
	call_deferred("run")

func frame(count := 1) -> void:
	for i in range(count):
		await process_frame
		await RenderingServer.frame_post_draw

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("FRONTEND_RPG_VISUAL requires a GPU")
		quit(1)
		return
	var phase := "before" if "--before" in OS.get_cmdline_user_args() else "after"
	var output := "res://docs/rpg/ui-preservation/" + phase + "/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	app = load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	app.set_process(false)
	await frame(4)
	app.menu.hide()
	app.title_image.hide()
	app.title_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	app.shadow_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	app.ui.set_game_mode(true)
	app.ui.region_clock = 0
	await frame(2)
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path(output + "hud.png"))
	for panel in ["bag", "character", "skills", "settings"]:
		app.ui.close_panel(true)
		app.ui.show_panel(panel)
		for i in range(100):
			await frame()
			if not app.ui.is_animating():
				break
		app.ui.elapsed = 1.0
		app.ui.book_age = 1.0
		await frame(2)
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path(output + panel + ".png"))
		print("CAPTURE ", phase, " ", panel)
	app.queue_free()
	await frame(2)
	print("FRONTEND_RPG_VISUAL: 5 captures ", phase)
	quit()
