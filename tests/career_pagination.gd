extends SceneTree
## Real App/map UI, synthetic catalog entries only; all preferences and saves
## are injected into a fresh OS-temp directory before App enters the tree.
const Preferences=preload("res://rpg/game_preferences.gd")
var app: Node
var actor: Node
var failures: Array[String]=[]
var checks := 0
var base_ids: Array[String]=[]
var branch_ids: Array[String]=[]
var deep_ids: Array[String]=[]

func _initialize() -> void: call_deferred("run")
func check(value: bool,label: String) -> void:
	checks+=1
	if not value: failures.append(label)
	print("PASS " if value else "FAIL ",label)
func ticks(count: int) -> void:
	for _i in range(count):
		await physics_frame
		await process_frame
func settle() -> void:
	await ticks(2)
	var until := Time.get_ticks_msec()+5500
	while (app.ui.is_animating() or career_ink_animating()) and Time.get_ticks_msec()<until:
		await process_frame
	await ticks(2)
	check(not app.ui.is_animating() and not career_ink_animating(),"book and visible career ink animations settle")
func career_ink_animating() -> bool:
	return app.ui.panel=="character" and app.ui.character_tab==1 and app.ui.career_age<1.4
func active_candidates() -> Array[String]:
	var ids: Array[String]=[]
	for entry in app.ui.career_nodes:
		if not entry.chosen and not entry.retiring: ids.append(entry.id)
	return ids
func press_control(control: Button) -> void:
	check(control!=null and not control.disabled,"native career control is enabled")
	if control!=null and not control.disabled:
		control.grab_focus()
		control.pressed.emit()
	await settle()
func next_page() -> void:
	await press_control(app.ui.modal.get_node_or_null("CareerNextPage"))
	check(app.ui.career_buttons[active_candidates()[0]].has_focus(),"next page transfers focus to its first visible candidate")
func previous_page() -> void:
	await press_control(app.ui.modal.get_node_or_null("CareerPreviousPage"))
	check(app.ui.career_buttons[active_candidates()[0]].has_focus(),"previous page transfers focus to its first visible candidate")
func key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode=code
	event.keycode=code
	event.pressed=true
	Input.parse_input_event(event)
	await ticks(1)
	event=InputEventKey.new()
	event.physical_keycode=code
	event.keycode=code
	event.pressed=false
	Input.parse_input_event(event)
	await ticks(2)
func capture(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://docs/content-preview")
	DirAccess.make_dir_recursive_absolute(directory)
	check(root.get_texture().get_image().save_png(directory.path_join(label+".png"))==OK,"GPU career screenshot saved: "+label)
func assert_geometry() -> void:
	var cards: Array[Rect2]=[]
	var ids := active_candidates()
	check(ids.size()<=4,"candidate page capacity remains four regardless of catalog size")
	for entry in app.ui.career_nodes:
		var control: Button=app.ui.career_buttons.get(entry.id)
		if entry.retiring:
			check(control!=null and control.disabled and is_equal_approx(float(control.material.get_shader_parameter("erasure")),1),"retired career is fully erased and cannot activate: "+entry.id)
			continue
		var rect := Rect2(control.position-app.ui.panel_rect.position,control.size)
		check(Rect2(24,125,478,389).encloses(rect),"career card stays within left page: "+entry.id)
		for previous in cards: check(not previous.intersects(rect),"career cards do not overlap")
		cards.append(rect)
		var top_left: Vector2=root.get_final_transform()*app.ui.get_global_transform()*control.get_global_rect().position
		var bottom_right: Vector2=root.get_final_transform()*app.ui.get_global_transform()*control.get_global_rect().end
		check(top_left.x>=0 and top_left.y>=0 and bottom_right.x<=root.size.x and bottom_right.y<=root.size.y,"career card fits physical window: "+entry.id)
func install_fixture() -> void:
	var db: Dictionary=actor.loadout.database.careers
	for i in range(12):
		var id := "ui_test:base_%02d"%i
		base_ids.append(id)
		var data: Dictionary=db.warrior.duplicate(true)
		data.id=id
		data.name="试炼职业%02d"%i
		data.base_career=id
		data.next_careers=[]
		db[id]=data
	for i in range(12):
		var id := "ui_test:branch_%02d"%i
		branch_ids.append(id)
		var data: Dictionary=db.swordsman.duplicate(true)
		data.id=id
		data.name="试炼分支%02d"%i
		data.base_career=base_ids.back()
		data.parent_career=base_ids.back()
		data.required_level=2
		data.next_careers=[]
		db[id]=data
	db[base_ids.back()].next_careers=branch_ids.duplicate()
	var parent: String=branch_ids.back()
	for level in range(3,11):
		var id := "ui_test:deep_%02d"%level
		deep_ids.append(id)
		var data: Dictionary=db.swordsman.duplicate(true)
		data.id=id
		data.name="试炼道路第%d阶"%level
		data.base_career=base_ids.back()
		data.parent_career=parent
		data.required_level=level
		data.next_careers=[]
		db[id]=data
		db[parent].next_careers=[id]
		parent=id
	actor.progression.changed.emit()

func run() -> void:
	create_timer(180,true).timeout.connect(func(): printerr("CAREER_PAGINATION TIMEOUT"); quit(1))
	root.size=Vector2i(1280,720)
	var isolated := OS.get_temp_dir().path_join("mosslight-career-ui-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path=isolated.path_join("preferences.cfg")
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=app.SAVE_REPOSITORY.new(isolated.path_join("adventures"))
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app.selected_name="职业容量测试"
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate.a=1
	actor=app.game.rpg
	for enemy in actor.arena.enemies: enemy.ai_enabled=false
	await settle()
	check(active_candidates().size()==4,"the original four base careers remain visible together")
	install_fixture()
	await settle()
	check(app.ui.CAREERS.options(app.ui).size()==16 and app.ui.CAREERS.page_count(app.ui)==4,"twelve additional base careers paginate beside all four originals")
	for size: Vector2i in [Vector2i(960,540),Vector2i(1280,720)]:
		root.size=size
		await ticks(3)
		var visited: Array[String]=[]
		while app.ui.career_page>0: await previous_page()
		for page in range(4):
			assert_geometry()
			visited.append_array(active_candidates())
			check(app.ui.career_page==page,"base page index is stable after resize")
			if page<3: await next_page()
		check(visited.size()==16 and visited.count(base_ids.back())==1,"every base career is reachable exactly once at %s"%size)
		check(app.ui.modal.get_node("CareerNextPage").disabled,"last base page prevents overshooting")
		await capture("career-%dx%d-base"%[size.x,size.y])
	# Names longer than one card are elided visually, but the full identifier,
	# tooltip and focus inspection remain attached to the same native button.
	var last: Button=app.ui.career_buttons[base_ids.back()]
	check(last.tooltip_text.contains("试炼职业11") and app.ui.CAREERS.fit_name("很长很长的外部职业名称").ends_with("…"),"long labels retain full tooltip while fitting the card width")
	check(app.ui.F.font().get_string_size(app.ui.CAREERS.fit_text("长名称".repeat(100),16,150),HORIZONTAL_ALIGNMENT_LEFT,-1,16).x<=150,"long external names preserve the separate condition text width budget")
	last.grab_focus()
	await ticks(2)
	app.ui._build_modal()
	await ticks(2)
	check(app.ui.career_buttons[base_ids.back()].has_focus(),"focused career survives a live modal rebuild")
	await press_control(app.ui.career_buttons[base_ids.back()])
	check(app.ui.panel=="skills","first career selection continues into the skill book")
	app.ui.show_panel("character")
	await settle()
	check(actor.loadout.career_ids==[base_ids.back()] and app.ui.career_page==0,"choosing a late-page base resets advancement to first page")
	check(app.ui.CAREERS.options(app.ui).size()==12,"all twelve same-level advancement branches are retained")
	var locked: Button=app.ui.career_buttons[branch_ids[0]]
	check(not locked.disabled and locked.tooltip_text.contains("Lv2"),"locked advancement remains focusable with its actual level condition")
	locked.grab_focus()
	await ticks(2)
	check(app.ui.career_detail_id==branch_ids[0],"keyboard focus exposes the locked branch condition")
	await press_control(locked)
	check(actor.loadout.career_ids==[base_ids.back()] and actor.progression.last_error.contains("Lv2"),"activating an unmet condition cannot change the career chain")
	check(actor.progression.level_up(),"normal progression unlocks level-two advancement")
	await settle()
	check(app.ui.rpg_note.is_empty() and not app.ui.rpg_feedback_failed,"meeting a branch condition clears its stale failure message")
	for size: Vector2i in [Vector2i(960,540),Vector2i(1280,720)]:
		root.size=size
		await ticks(3)
		while app.ui.career_page>0: await previous_page()
		var visited: Array[String]=[]
		for page in range(3):
			assert_geometry()
			visited.append_array(active_candidates())
			if page<2: await next_page()
		check(visited==branch_ids,"all twelve advancement branches remain ordered and reachable at %s"%size)
		await capture("career-%dx%d-branches"%[size.x,size.y])
	var candidate: Button=app.ui.career_buttons[branch_ids[8]]
	candidate.grab_focus()
	await key(KEY_TAB)
	check(app.ui.career_buttons[branch_ids[9]].has_focus(),"Tab advances between visible native career choices")
	app.ui.career_buttons[branch_ids.back()].grab_focus()
	await key(KEY_ENTER)
	await settle()
	check(actor.loadout.career_ids==[base_ids.back(),branch_ids.back()],"Enter chooses a focused late-page advancement through native input")
	for id in deep_ids:
		check(actor.progression.level_up(),"next career step unlocks through actual level progression")
		await settle()
		await press_control(app.ui.career_buttons[id])
		assert_geometry()
	check(actor.loadout.career_ids.size()==10 and actor.loadout.career_ids.back()==deep_ids.back(),"deep progression preserves the entire ten-step chosen chain")
	check(active_candidates().is_empty(),"terminal career displays no invented next branch")
	var path: ScrollContainer=app.ui.modal.get_node("CareerPath")
	check(path.get_child(0).get_child_count()==11,"full path contains Traveller and all ten chosen careers")
	var end: Button=path.get_child(0).get_child(10)
	end.grab_focus()
	await ticks(4)
	check(end.has_focus() and path.scroll_horizontal>0,"keyboard focus scrolls the complete history to a distant chosen career")
	for size: Vector2i in [Vector2i(960,540),Vector2i(1280,720)]:
		root.size=size
		await ticks(3)
		assert_geometry()
		await capture("career-%dx%d-full-chain"%[size.x,size.y])
	check(Preferences.settings_path.begins_with(isolated) and app.saves.directory.begins_with(isolated),"all preference and repository access stays in the injected Temp workspace")
	paused=false
	app.free()
	await ticks(3)
	print("CAREER_PAGINATION ",checks-failures.size(),"/",checks," isolated=",isolated)
	for failure in failures: printerr("FAILED: ",failure)
	quit(0 if failures.is_empty() else 1)
