extends SceneTree
## Real-renderer visual review. Captures are rendered by Godot, not mockups.
var app: Node
var tag := ""
func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count): await process_frame
func capture(label: String) -> void:
	await ticks(3)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/"+label+tag+".png")
	print("FRONTEND_CAPTURE ",label)
func run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--tag="): tag="-"+argument.trim_prefix("--tag=")
	if DisplayServer.get_name()=="headless":
		push_error("Visual review requires a GPU renderer.")
		quit(1)
		return
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await ticks(45)
	await capture("title")
	app.shadow_view.get_texture().get_image().save_png("res://docs/frontend/shadow-mask"+tag+".png")
	if "--title-only" in OS.get_cmdline_user_args():
		app.menu.visible=false
		await capture("title-scene")
		for i in range(4):
			app.meadow.sleeper.apply_pose(float(i)/3)
			await capture("pose-%d"%i)
		app.queue_free()
		await ticks(18)
		quit()
		return
	app.new_adventure()
	while app.stage!=app.Stage.CHOOSING: await process_frame
	await ticks(120)
	app.choice.name_input.text="桐人"
	await capture("new-adventure")
	app.cancel_journey()
	while app.stage!=app.Stage.TITLE: await process_frame
	app.start_adventure()
	while app.stage==app.Stage.JOURNEY and app.stage_time<2.8: await process_frame
	await capture("waking")
	while app.stage!=app.Stage.CHOOSING: await process_frame
	await ticks(120)
	await capture("save-selection")
	app.choice._confirm()
	while app.stage==app.Stage.DISSOLVING and app.stage_time<.48: await process_frame
	await capture("cloud-letters")
	while app.stage==app.Stage.DISSOLVING: await process_frame
	while app.stage==app.Stage.ASCENDING and app.stage_time<2.9: await process_frame
	await capture("ascending")
	while app.stage!=app.Stage.DESCENDING: await process_frame
	await capture("clouds")
	while app.stage==app.Stage.DESCENDING and app.stage_time<2.3: await process_frame
	await capture("descending")
	while app.stage!=app.Stage.PLAYING: await process_frame
	await ticks(85)
	await capture("hud")
	app.ui.show_panel("bag")
	await capture("inventory")
	app.ui.show_panel("journal")
	await capture("journal")
	app.ui.show_panel("settings")
	await capture("settings")
	app.ui.close_panel()
	app.queue_free()
	await ticks(18)
	quit()
