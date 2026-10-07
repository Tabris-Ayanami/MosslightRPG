extends SceneTree
## Capture actual F5 shell, using its normal world-loading and modal transitions.
var app: Node
func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count): await process_frame
func capture(label: String) -> void:
	await ticks(3)
	while app.ui.is_animating(): await process_frame
	await ticks(12)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/frontend/book-"+label+".png")
	print("BOOK_CAPTURE ",label)
func run() -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	app.set_process(false)
	await ticks(5)
	app.start_adventure()
	app._process(app.JOURNEY_SECONDS+.1)
	app.choice.age=2
	app.choice._confirm()
	app.stage_time=1.4
	app._process(0)
	app._process(app.ASCENT_SECONDS+.1)
	var deadline := Time.get_ticks_msec()+30000
	while app.stage==app.Stage.LOADING and Time.get_ticks_msec()<deadline:
		app._process(.04)
		await process_frame
	if not is_instance_valid(app.game):
		push_error("World load did not finish")
		quit(1)
		return
	app.stage_time=4.1
	app._process(0)
	app._process(1)
	app.ui.modulate=Color.WHITE
	app.ui.region_clock=4.5
	# Art review keeps the same specimen set while gameplay data evolves separately.
	app.ui.close_panel(true)
	if app.ui.has_method("bind_rpg"): app.ui.bind_rpg(null)
	app.ui.selected_item=2
	app.ui.character_tab=0
	app.ui.selected_skill=0
	app.ui.learned_skills={0:true,1:true,2:true,7:true,11:true}
	app.ui.active_slots.assign([0,1,2])
	app.ui.passive_slots.assign([7,11])
	app.ui._rebuild_hud_buttons()
	if "--record-book" in OS.get_cmdline_user_args():
		await record_sequence()
		return
	await capture("hud")
	app.ui.show_panel("bag")
	await capture("inventory")
	app.ui.book_view.get_texture().get_image().save_png("res://.work/ink-journal/raw-paper.png")
	app.ui.show_panel("character")
	await capture("character")
	app.ui._select_character_tab(1)
	await settle(65)
	await capture("career-options")
	app.ui._choose_career("warrior")
	await ticks(75)
	await capture("loadout")
	app.ui.show_panel("skills")
	await capture("skills")
	app.ui._open_ink()
	await ticks(42)
	await capture("ink")
	app.ui._cancel_ink()
	await ticks(42)
	app.ui.show_panel("bag")
	await capture("inventory-all")
	app.ui._select_inventory_tab(2)
	await capture("materials")
	app.ui._select_inventory_tab(3)
	await capture("food")
	app.ui.show_panel("journal")
	await capture("journal")
	app.ui.show_panel("settings")
	await capture("settings")
	app.ui._select_settings_tab(1)
	await capture("bindings")
	app.ui.character_tab=0
	app.ui.show_panel("character")
	root.size=Vector2i(960,540)
	await capture("small")
	app.ui.show_panel("bag")
	await capture("inventory-small")
	app.ui.show_panel("skills")
	await capture("skills-small")
	root.size=Vector2i(1600,720)
	app.ui.show_panel("character")
	await capture("wide")
	app.ui.close_panel(true)
	app.queue_free()
	await ticks(18)
	quit()

func settle(hold := 28) -> void:
	await ticks(3)
	while app.ui.is_animating(): await process_frame
	await ticks(hold)

func record_sequence() -> void:
	await ticks(10)
	print("JOURNAL_MOVIE_START ",Engine.get_frames_drawn())
	app.ui.show_panel("character")
	await settle(36)
	app.ui._select_character_tab(1)
	await settle(35)
	app.ui.show_panel("bag")
	await settle(35)
	app.ui._select_inventory_tab(2)
	await settle(32)
	app.ui._select_inventory_tab(3)
	await settle(32)
	app.ui.show_panel("skills")
	await settle(25)
	app.ui._open_ink()
	await ticks(40)
	app.ui._assign_ink(1)
	await ticks(32)
	app.ui.show_panel("settings")
	await settle(12)
	app.ui._select_settings_tab(1)
	await settle(12)
	for i in range(3):
		var event := InputEventKey.new()
		event.physical_keycode=[KEY_1,KEY_2,KEY_3][i]
		app.ui.BINDINGS.assign(i,event)
	await ticks(25)
	app.ui.show_panel("skills")
	await settle(15)
	app.ui._open_ink()
	await ticks(44)
	app.ui.request_escape()
	await ticks(26)
	app.ui.close_panel()
	await settle(30)
	print("JOURNAL_MOVIE_END ",Engine.get_frames_drawn())
	app.queue_free()
	await ticks(3)
	quit()
