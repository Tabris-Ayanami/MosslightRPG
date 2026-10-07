extends SceneTree
## Presentation lifecycle and input isolation regression. HUD fixtures do not bind stats.
const Preferences=preload("res://rpg/game_preferences.gd")
var app: Node
var failures: Array[String]=[]
var count := 0
var test_workspace := ""
func _initialize() -> void: call_deferred("run")
func check(value: bool, label: String) -> void:
	count+=1
	if not value: failures.append(label)
	print("PASS " if value else "FAIL ",label)
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func settle_book() -> void:
	await ticks(2)
	var deadline := Time.get_ticks_msec()+5000
	while app.ui.is_animating() and Time.get_ticks_msec()<deadline: await process_frame
	if app.ui.is_animating(): check(false,"book animation reaches its stable state")
	await ticks(2)
func careers_settled() -> bool:
	for item: Dictionary in app.ui.career_nodes:
		if item.retiring:
			if app.ui.CAREERS.erase(item,app.ui.career_age)<1.0: return false
		elif app.ui.CAREERS.grow(item,app.ui.career_age)<1.0: return false
	return true
func settle_careers() -> void:
	var deadline := Time.get_ticks_msec()+3000
	while not careers_settled() and Time.get_ticks_msec()<deadline: await process_frame
	check(careers_settled(),"career growth and retirement animations reach their completed states")
func clean_test_tree(path: String) -> void:
	var resolved := path.simplify_path()
	var allowed := test_workspace.simplify_path()
	if allowed.is_empty() or (resolved!=allowed and not resolved.begins_with(allowed+"/")): return
	var directory := DirAccess.open(resolved)
	if directory==null: return
	for file in directory.get_files(): DirAccess.remove_absolute(resolved.path_join(file))
	for child in directory.get_directories(): clean_test_tree(resolved.path_join(child))
	DirAccess.remove_absolute(resolved)
func mouse(at: Vector2, pressed: bool, button: int=MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	# parse_input_event accepts physical window pixels; headless windows are 64px.
	event.position=root.get_final_transform()*at
	event.global_position=event.position
	event.button_index=button
	event.pressed=pressed
	Input.parse_input_event(event)
func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode=code
	event.physical_keycode=code
	event.pressed=pressed
	Input.parse_input_event(event)
func has_button(label: String) -> bool:
	for node in app.ui.modal.get_children():
		if node is Button and node.text==label: return true
	return false
func click_label(label: String) -> void:
	await settle_book()
	for node in app.ui.modal.get_children():
		if node is Button and node.text==label:
			var point: Vector2=app.ui.get_global_transform()*node.get_global_rect().get_center()
			mouse(point,true)
			await ticks(1)
			mouse(point,false)
			await ticks(2)
			await settle_book()
			return
	check(false,"button exists: "+label)
func load_adventure(check_arrival_cancel: bool=false) -> void:
	app.start_adventure()
	app.start_adventure()
	check(app.stage==app.Stage.JOURNEY,"repeated start is ignored during the transition")
	app._process(app.JOURNEY_SECONDS+.1)
	check(app.stage==app.Stage.CHOOSING and app.choice.kind=="continue","start reaches the sky save selector before loading")
	app.choice.age=2
	app.choice._confirm()
	check(app.stage==app.Stage.DISSOLVING,"confirmation first dissolves the cloud glyphs")
	app.stage_time=1.4
	app._process(0)
	check(app.stage==app.Stage.ASCENDING,"glyph dismissal completes before ascent")
	app._process(app.ASCENT_SECONDS+.1)
	check(app.stage==app.Stage.LOADING and is_equal_approx(app.cloud_material.get_shader_parameter("cover"),1),"opaque clouds cover the scene swap")
	var deadline := Time.get_ticks_msec()+20000
	while app.stage==app.Stage.LOADING and Time.get_ticks_msec()<deadline:
		app._process(.04)
		await process_frame
	check(app.stage==app.Stage.DESCENDING,"threaded load advances to the camera descent")
	check(is_instance_valid(app.game),"one playable world is mounted")
	if not is_instance_valid(app.game): return
	if check_arrival_cancel:
		app.stage_time=1.0
		app._process(0)
		var checkpoint: Transform3D=app.game.camera.global_transform
		app.stage_time=2.0
		app._process(0)
		app.cancel_journey()
		app._process(1.0)
		check(app.game.camera.global_transform.is_equal_approx(checkpoint),"cancelling arrival retraces the game camera before returning to the sky")
		app._process(1.1)
		await ticks(2)
		check(not is_instance_valid(app.game) and app.title_image.visible,"opaque clouds safely return from the mounted world to the title stage")
		app._process(app.ASCENT_SECONDS+.1)
		app._process(app.JOURNEY_SECONDS+.1)
		check(app.stage==app.Stage.TITLE and not app.cloud.visible,"arrival cancellation ends with Kirito resting and all title actions restored")
		await load_adventure()
		return
	check(not app.game.player.is_physics_processing(),"player input waits for camera arrival")
	var before: Vector3=app.game.player.global_position
	Input.action_press("move_right")
	await ticks(4)
	check(app.game.player.global_position.is_equal_approx(before),"movement cannot escape the arrival cinematic")
	Input.action_release("move_right")
	app.stage_time=4.1
	app._process(0)
	await ticks(5)
	check(app.stage==app.Stage.PLAYING and not app.cloud.visible,"arrival reveals gameplay and retires the cloud input shield")
	check(app.game.player.is_physics_processing() and app.ui.game_mode,"gameplay and presentation become active together")

func run() -> void:
	test_workspace=OS.get_temp_dir().path_join("mosslight-frontend-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(test_workspace)
	Preferences.settings_path=test_workspace.path_join("preferences.cfg")
	app=load("res://scenes/frontend/app.tscn").instantiate()
	# Install isolated saves BEFORE _ready lists slots or any title action can write.
	app.saves=app.SAVE_REPOSITORY.new(test_workspace.path_join("adventures"))
	check(app.saves.create("前端回归旅人",0).ok,"frontend starts with a fixed adventure in an isolated temporary repository")
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	check(app.stage==app.Stage.TITLE and app.menu.visible,"F5 shell starts on the meadow menu")
	check(not is_instance_valid(app.game),"the world is not mounted behind the initial menu")
	check(app.menu.buttons.size()==4 and app.menu.buttons[3].name=="Exit","title includes the fourth exit action")
	check((-app.meadow.camera.global_basis.z).is_equal_approx(Vector3.DOWN),"title camera looks exactly vertically down")
	var hotspot_styles_ok := true
	for button: Button in app.menu.buttons:
		for state in ["normal","hover","pressed","hover_pressed","disabled","focus"]:
			hotspot_styles_ok=hotspot_styles_ok and button.get_theme_stylebox(state) is StyleBoxEmpty
	check(hotspot_styles_ok,"title hotspots stay transparent in every native button state")
	var worst_contact := 0.0
	for i in range(101):
		app.meadow.sleeper.apply_pose(float(i)/100)
		worst_contact=maxf(worst_contact,app.meadow.sleeper.contact_error)
	check(worst_contact<.025,"all 101 sampled poses keep hand and foot targets reachable within 2.5cm")
	var actor: Node3D=app.meadow.sleeper
	var skeleton: Skeleton3D=actor.skeleton
	var last: Array[Quaternion]=[]
	var largest_step := 0.0
	for frame in range(roundi(actor.STORY.END*120)+1):
		actor.apply_time(float(frame)/120)
		for bone in range(skeleton.get_bone_count()):
			var q := skeleton.get_bone_pose_rotation(bone)
			if frame==0: last.append(q)
			largest_step=maxf(largest_step,last[bone].angle_to(q))
			last[bone]=q
	check(rad_to_deg(largest_step)<6,"full 120Hz get-up, sheath and walk sweep has no elbow flips or rotation spikes")
	# Test the rendered fabric, not the now-unused coat-bone endpoints.
	var positions: Image=load("res://assets/ui/title/cloth-positions.res").get_image()
	var lowest_cloth := 100.0
	for frame in range(positions.get_height()):
		for vertex in range(positions.get_width()):
			lowest_cloth=minf(lowest_cloth,positions.get_pixel(vertex,frame).g)
	check(lowest_cloth>.015,"all cached coat surface vertices stay above the meadow across the full performance")
	check(actor.cloth.skin==null and actor.cloth.mesh.get_surface_count()==2,"cloth uses its actual two material surfaces without double skinning")
	var hips := skeleton.find_bone("J_Bip_C_Hips")
	actor.apply_time(0)
	var resting_hip := skeleton.to_global(skeleton.get_bone_global_pose(hips).origin)
	actor.apply_time(actor.STORY.RISE_END)
	var standing_hip := skeleton.to_global(skeleton.get_bone_global_pose(hips).origin)
	check(standing_hip.y-resting_hip.y>1.3,"native pelvis translation lifts the body from lying to standing after retargeting")
	check(actor.PERFORMANCE.get_meta("source_clips")==["UAL2 LayToIdle","UAL1 Idle_Loop","UAL1 Walk_Loop"],"the shipped performance uses the downloaded get-up, idle and walk clips")
	actor.apply_pose(.413)
	var cached_hip := skeleton.get_bone_pose_position(hips)
	var cached: Array[Quaternion]=[]
	for bone in range(skeleton.get_bone_count()): cached.append(skeleton.get_bone_pose_rotation(bone))
	actor.apply_pose(.92)
	actor.apply_pose(.413)
	var reversible := cached_hip.is_equal_approx(skeleton.get_bone_pose_position(hips))
	for bone in range(skeleton.get_bone_count()): reversible=reversible and cached[bone].is_equal_approx(skeleton.get_bone_pose_rotation(bone))
	check(reversible,"direct seek and reverse seek give identical body and cloth poses")
	actor.apply_time(actor.STORY.CHOICE_TIME)
	check((-actor.hero.global_basis.z).normalized().dot(actor.STORY.FACING)>.999,"the standing traveller turns to face the sky choices")
	check(actor.sword_attached,"the sword is on his back before the sky choices appear")
	var grip_before: Transform3D
	actor.apply_time(actor.STORY.ATTACH_TIME-.001)
	grip_before=actor.sword.transform
	actor.apply_time(actor.STORY.ATTACH_TIME+.001)
	check(actor.sword.position.distance_to(grip_before.origin)<.01 and actor.sword.basis.y.dot(grip_before.basis.y)>.999,"hand-to-back transfer preserves the sword pose")
	actor.apply_time(12.3)
	var walking_root: Vector3=actor.hero.position
	var walking_prop: Transform3D=actor.sword.transform
	var walking_cloth: float=actor.cloth_materials[0].get_shader_parameter("frame")
	actor.apply_time(15)
	actor.apply_time(12.3)
	check(actor.hero.position.is_equal_approx(walking_root) and actor.sword.transform.is_equal_approx(walking_prop) and is_equal_approx(walking_cloth,actor.cloth_materials[0].get_shader_parameter("frame")),"walk, back attachment and surface cache reverse to exactly the same frame")
	check(walking_root.dot(actor.STORY.FACING)>2,"confirmation makes the traveller move forward through the meadow")
	app.meadow.set_journey(0)
	var home_camera: Transform3D=app.meadow.camera.global_transform
	var level_horizon := true
	for frame in range(101):
		app.meadow.set_journey(float(frame)/100)
		level_horizon=level_horizon and absf(app.meadow.camera.basis.x.y)<.0001
	check(level_horizon,"withdrawal keeps the horizon level throughout camera yaw and pitch")
	app.meadow.set_journey(0)
	var new_button: Button=app.menu.buttons[1]
	var radial_point: Vector2=new_button.get_global_transform()*(new_button.size*.5)
	mouse(radial_point,true)
	await ticks(1)
	mouse(radial_point,false)
	await ticks(1)
	check(app.stage==app.Stage.JOURNEY and app.choice_kind=="new","rotated New Adventure button receives real pointer input")
	app._process(2.4)
	var forward_camera: Transform3D=app.meadow.camera.global_transform
	app._process(2.4)
	app.cancel_journey()
	app._process(2.4)
	check(app.meadow.camera.global_transform.is_equal_approx(forward_camera),"Escape retraces the exact camera path at an intermediate timestamp")
	app._process(2.5)
	check(app.stage==app.Stage.TITLE and app.meadow.camera.global_transform.is_equal_approx(home_camera),"cancelling during get-up returns to the same resting composition")
	check(is_zero_approx(app.meadow.sleeper.rise),"Kirito lies down again after reversing")
	app.new_adventure()
	app._process(app.JOURNEY_SECONDS+.1)
	check(app.choice.kind=="new" and is_instance_valid(app.choice.name_input),"new adventure opens a native editable name field")
	check(app.cloud.visible and not app.cloud_material.get_shader_parameter("deck_mode"),"the sparse authored clouds are already present on the sky choice page")
	var initial_clouds: PackedVector3Array=app.cloud_material.get_shader_parameter("cloud_centers")
	var choice_camera: Transform3D=app.meadow.camera.transform
	app._sample_ascent()
	check(app.meadow.camera.transform.is_equal_approx(choice_camera) and initial_clouds==app.cloud_material.get_shader_parameter("cloud_centers"),"starting ascent preserves the existing camera and cloud positions without replacing the sky")
	var last_height := -1.0
	var rises := true
	var looks_down := true
	for frame in range(101):
		var progress := float(frame)/100
		var pose: Transform3D=app.FLIGHT.camera_pose(progress)
		rises=rises and pose.origin.y>=last_height
		last_height=pose.origin.y
		if progress>=.28: looks_down=looks_down and (-pose.basis.z).y<-.14
	check(rises and last_height>100 and looks_down,"the crane rises continuously while looking down at the ground")
	check(initial_clouds==app.FLIGHT.cloud_centers(1),"distant sky clouds stay in place during the ground-facing crane")
	app.choice.age=2
	app.choice.name_input.text="   "
	app.choice._confirm()
	check(app.stage==app.Stage.CHOOSING,"a blank name cannot confirm an adventure")
	app.choice.name_input.text="风中的桐人"
	app.choice._confirm()
	check(app.selected_name=="风中的桐人" and app.stage==app.Stage.DISSOLVING,"Chinese name is retained as local presentation state")
	var disabled_clear := true
	for button: Button in app.choice.buttons: disabled_clear=disabled_clear and button.disabled and button.get_theme_stylebox("disabled") is StyleBoxEmpty
	check(disabled_clear,"dissolving sky choices cannot reveal the default disabled button background")
	await ticks(2)
	key(KEY_ESCAPE,true)
	key(KEY_ESCAPE,false)
	await ticks(1)
	app._process(app.JOURNEY_SECONDS+.1)
	check(app.stage==app.Stage.TITLE and not app.choice.visible,"Escape during glyph dismissal returns without mounting a world")
	await ticks(2)
	app.start_adventure()
	app._process(app.JOURNEY_SECONDS+.1)
	app.choice.age=2
	app.choice._confirm()
	app.stage_time=1.4
	app._process(0)
	app._process(2.2)
	var ascent_checkpoint: Transform3D=app.meadow.camera.global_transform
	app._process(.6)
	app.cancel_journey()
	app._process(.6)
	check(app.meadow.camera.global_transform.is_equal_approx(ascent_checkpoint),"Escape also reverses a partly completed sky ascent")
	app._process(2.3)
	app._process(app.JOURNEY_SECONDS+.1)
	check(app.stage==app.Stage.TITLE and not app.cloud.visible,"reversed ascent removes cloud overlay and restores menu input")
	app.ui.show_panel("settings")
	check(app.menu.buttons[0].disabled,"modal panel disables background menu actions")
	app.ui.close_panel()
	await settle_book()
	check(not app.menu.buttons[0].disabled,"closing a title panel restores menu input")
	await load_adventure(true)
	if not is_instance_valid(app.game): quit(1); return
	var game: Node=app.game
	check(app.ui.has_rpg(),"the current F5 integration can bind the live actor")
	app.ui.show_panel("character")
	await settle_book()
	app.ui.show_panel("skills")
	await settle_book()
	check(app.ui.panel=="skills" and app.ui.item_buttons.is_empty(),"live character and empty skill pages render safely before career selection")
	app.ui.close_panel()
	await settle_book()
	# Keep the visual fixtures stable while the independent RPG integration evolves.
	app.ui.bind_rpg(null)
	# Reproduce a live progressed character handing over to an empty art fixture.
	# The presenter deliberately retains obsolete branches for their erasure pass.
	app.ui.fixture_careers.assign(["warrior","swordsman","dual_swordsman"])
	app.ui.CAREERS.refresh(app.ui,true)
	app.ui.fixture_careers.clear()
	app.ui.character_tab=0
	app.ui.selected_item=2
	app.ui.selected_skill=0
	app.ui.learned_skills={0:true,1:true,2:true,7:true,11:true}
	app.ui.active_slots.assign([0,1,2])
	app.ui.passive_slots.assign([7,11])
	app.ui._rebuild_hud_buttons()
	var initial_health: float=game.player.resources.current("HP")
	var initial_mana: float=game.player.resources.current("Qi")
	var point: Vector2=app.ui.hud_buttons.get_children()[-1].get_global_rect().get_center()
	mouse(point,true)
	await ticks(3)
	check(game.player.input_router.held.is_empty(),"clicking a presentation slot cannot start a sword charge")
	mouse(point,false)
	await ticks(3)
	check(not game.player.combat.runner.busy(),"releasing a presentation click cannot trigger an attack")
	check(is_equal_approx(game.player.resources.current("HP"),initial_health) and is_equal_approx(game.player.resources.current("Qi"),initial_mana),"presentation clicks do not consume character resources")
	app.ui.show_panel("bag")
	check(paused and game.paused and app.ui.transition=="opening","opening the book immediately freezes the playable world")
	await settle_book()
	check(not app.ui.paper_doll.visible and not has_button("属性") and not has_button("装备"),"the inventory spread contains no character portrait or character controls")
	var held: Vector3=game.player.global_position
	Input.action_press("move_right")
	await ticks(3)
	check(game.player.global_position.is_equal_approx(held),"movement is suppressed behind inventory")
	await click_label("食物")
	check(app.ui.inventory_tab==3 and app.ui._displayed_items().size()==3,"real GUI click filters inventory without freeing an active signal emitter")
	check(app.ui.selected_item==2,"filtering keeps item details inside the chosen category")
	var item_point: Vector2=app.ui.get_global_transform()*app.ui.item_buttons[3].get_global_rect().get_center()
	mouse(item_point,true)
	await ticks(1)
	mouse(item_point,false)
	await ticks(2)
	check(app.ui.selected_item==3,"clicking an item updates the detail preview")
	check(app.ui.item_buttons[3].selected and not app.ui.item_buttons[2].selected,"item detail and selection outline agree")
	await click_label("任务")
	check(app.ui._displayed_items()==[11] and app.ui.selected_item==11,"the task pocket only shows its letter and selects it")
	await click_label("全部")
	check(app.ui.item_buttons.size()==15,"the complete illustrated inventory occupies fifteen slots")
	await click_label("技能")
	check(app.ui.panel=="skills" and not app.ui.paper_doll.visible and app.ui.item_buttons.is_empty() and app.ui.skill_buttons.size()==12,"the skill bookmark opens a separate spread without inventory or character content")
	await click_label("疾风步")
	check(app.ui.selected_skill==1 and app.ui.skill_buttons[1].selected and not app.ui.skill_buttons[0].selected,"skill selection updates its own description and highlight")
	await click_label("逐风连斩")
	var points_before: int=app.ui.skill_points
	await click_label("学习 · 1 技能点")
	check(app.ui.learned_skills.has(3) and app.ui.skill_points==points_before-1,"learning a skill spends exactly one local point")
	app.ui._learn_skill()
	check(app.ui.skill_points==points_before-1,"learning an already learned node cannot spend a second point")
	await click_label("备战")
	await create_timer(.65).timeout
	check(app.ui.ink_open and app.ui.ink_buttons.size()==7 and not has_button("A 组") and not has_button("B 组"),"ink expands into both A and B rows and cancel without skill group tabs")
	await click_label("R")
	await create_timer(.65).timeout
	check(app.ui.active_slots[2]==3 and not app.ui.ink_open,"ink choice writes the selected local skill to the chosen slot")
	await click_label("备战")
	await create_timer(.65).timeout
	key(KEY_ESCAPE,true)
	key(KEY_ESCAPE,false)
	await create_timer(.65).timeout
	check(app.ui.panel=="skills" and not app.ui.ink_open,"Escape retracts ink choices before closing the book")
	await click_label("轻身")
	await click_label("备战")
	await create_timer(.65).timeout
	check(app.ui.ink_buttons.size()==3 and has_button("Ⅰ") and not has_button("Q"),"passive skills expose two passive marks rather than active key slots")
	await click_label("×")
	await create_timer(.65).timeout
	await click_label("疾风步")
	await click_label("角色")
	check(app.ui.panel=="character" and app.ui.item_buttons.is_empty() and app.ui.skill_buttons.is_empty() and app.ui.paper_doll.visible and not has_button("全部"),"the character spread has attributes and equipment but no inventory grid or filters")
	await click_label("面板")
	var equip_count := 0
	for node in app.ui.modal.get_children():
		if node is Button and node.get("role")=="equip_small": equip_count+=1
		if node is Button and node.get("role")=="top_bookmark": check(node.get_rect().get_center().y<app.ui.panel_rect.position.y,"secondary bookmark lies outside the upper paper edge")
	check(equip_count==10,"all ten weapon and armor slots fit in a single equipment page")
	await click_label("旅人外衣")
	check(app.ui.character_tab==0 and app.ui.selected_equipment==3 and app.ui.paper_doll.visible,"equipment selection keeps the isolated character studio visible")
	await click_label("职业")
	await settle_careers()
	var visible_careers: Array[String]=[]
	var erased_careers_safe := true
	for item: Dictionary in app.ui.career_nodes:
		var button: Button=app.ui.career_buttons.get(item.id)
		if item.retiring:
			erased_careers_safe=erased_careers_safe and button!=null and button.disabled and is_equal_approx(float(button.material.get_shader_parameter("erasure")),1.0)
		elif button!=null: visible_careers.append(item.id)
	visible_careers.sort()
	check(app.ui.character_tab==1 and not app.ui.paper_doll.visible and visible_careers==["barbarian","mage","rogue","warrior"],"settled career page replaces portrait with exactly the four starting branches")
	check(app.ui.career_buttons.has("swordsman") and app.ui.career_buttons.has("dual_swordsman") and erased_careers_safe,"retained old career branches are fully erased and cannot receive clicks")
	await click_label("战士")
	await create_timer(1.2).timeout
	check(app.ui.fixture_careers==["warrior"] and app.ui.career_buttons.has("swordsman"),"career choice keeps the selected black branch and grows advancement options")
	app.ui._open_loadout(0,false)
	await ticks(3)
	check(has_button("疾风步") and not has_button("轻身"),"active preparation offers learned active skills only")
	await click_label("疾风步")
	check(app.ui.active_slots==[1,0,3],"assigning an existing active skill swaps slots instead of duplicating it")
	app.ui._open_loadout(0,true)
	await ticks(3)
	check(has_button("轻身") and has_button("森语") and not has_button("疾风步"),"passive preparation offers passive skills only")
	await click_label("森语")
	check(app.ui.passive_slots==[11,7],"passive preparation swaps its two equipped marks")
	await click_label("面板")
	var original_window_size := root.size
	root.size=Vector2i(960,540)
	await ticks(3)
	var in_bounds := true
	for node in app.ui.modal.get_children():
		if node is Button:
			in_bounds=in_bounds and root.get_visible_rect().encloses(node.get_global_rect())
	check(in_bounds,"all book controls fit inside the minimum supported window")
	await click_label("背包")
	check(app.ui.panel=="bag" and not app.ui.paper_doll.visible and app.ui.item_buttons.size()==15 and app.ui.selected_item==11,"returning to inventory restores its selection without leaking character content")
	await click_label("食物")
	check(app.ui.inventory_tab==3 and app.ui.item_buttons.size()==3,"scaled book buttons retain correct pointer hit areas")
	await click_label("技能")
	check(app.ui.panel=="skills" and app.ui.selected_skill==1 and app.ui.item_buttons.is_empty() and not app.ui.paper_doll.visible,"the new skill bookmark works at minimum size and preserves its own selection")
	root.size=original_window_size
	await ticks(3)
	app.ui.show_panel("journal")
	await settle_book()
	await click_label("一束花的约定")
	check(app.ui.selected_quest==1,"journal selection updates through its actual button")
	await click_label("追踪此任务")
	check(app.ui.tracked_quest==1,"quest tracking is retained in local presentation state")
	await click_label("背包")
	check(app.ui.panel=="bag" and paused,"a side bookmark changes spreads without resuming the world")
	app.ui.show_panel("settings")
	await settle_book()
	for node in app.ui.modal.get_children():
		if node is HSlider:
			node.value=14
			break
	check(is_equal_approx(app.ui.preview_levels[0],14),"slider signals update their presentation value")
	check(is_equal_approx(AudioServer.get_bus_volume_linear(AudioServer.get_bus_index("Master")),.14),"settings slider changes actual master bus volume")
	check(is_equal_approx(game.sound.master_volume_db,-2),"user volume preserves the authored Game mix baseline")
	await click_label("按键")
	var saved_events: Array[Array]=[]
	for action: StringName in app.ui.BINDINGS.ACTIONS: saved_events.append(InputMap.action_get_events(action))
	for i in range(3):
		app.ui._bind_key(i)
		await ticks(2)
		key([KEY_1,KEY_2,KEY_3][i],true)
		key([KEY_1,KEY_2,KEY_3][i],false)
		await ticks(3)
	check(app.ui.BINDINGS.signature()=="1|2|3","settings accept three actual remapped skill keys")
	check(app.ui.BINDINGS.action_label(&"quick_item_1")=="Q" and app.ui.BINDINGS.action_label(&"quick_item_3")=="R","assigning numeric skill keys safely swaps conflicting quick-item bindings")
	check(app.ui.quick_buttons[&"skill_q"].caption=="1" and app.ui.quick_buttons[&"skill_r"].caption=="3","HUD captions follow actual action bindings")
	app.ui._bind_key(0)
	await ticks(2)
	key(KEY_W,true)
	key(KEY_W,false)
	await ticks(2)
	check(app.ui.awaiting_binding==0 and app.ui.BINDINGS.label(0)=="1","movement keys cannot be stolen by skill binding")
	key(KEY_ESCAPE,true)
	key(KEY_ESCAPE,false)
	await ticks(2)
	check(app.ui.panel=="settings" and app.ui.awaiting_binding==-1,"Escape cancels key capture without closing the book")
	game._setup_inputs()
	check(app.ui.BINDINGS.signature()=="1|2|3" and InputMap.action_get_events("skill_q").size()==1,"world input setup preserves customized bindings without adding default keys")
	await click_label("技能")
	await click_label("备战")
	await create_timer(.65).timeout
	check(has_button("1") and has_button("2") and has_button("3") and not has_button("Q") and app.ui.ink_buttons[0].text==app.ui.ink_buttons[3].text and app.ui.ink_buttons[5].text=="3","both ink rows follow actual remapped keys")
	app.ui._assign_ink(5)
	await create_timer(.65).timeout
	check(app.ui.reserve_slots[2]==app.ui.selected_skill,"second ink row writes to B independently")
	await click_label("备战")
	await create_timer(.65).timeout
	key(KEY_ESCAPE,true)
	key(KEY_ESCAPE,false)
	await create_timer(.65).timeout
	app.ui.close_panel()
	check(paused and app.ui.blocks_world_pointer(Vector2(640,350)),"closing sheets retain the input shield until fully shut")
	await settle_book()
	check(not paused and not game.paused and not Input.is_action_pressed("move_right"),"closing a panel resumes safely with held actions released")
	key(KEY_X,true)
	key(KEY_X,false)
	await settle_book()
	check(app.ui.panel=="character" and paused,"C opens the character bookmark through the normal app input route")
	key(KEY_X,true)
	key(KEY_X,false)
	await settle_book()
	check(app.ui.panel=="" and not paused,"C closes the character book and releases pause")
	key(KEY_K,true)
	key(KEY_K,false)
	await settle_book()
	check(app.ui.panel=="skills" and paused and app.ui.item_buttons.is_empty(),"K opens the independent skill spread through the normal input route")
	key(KEY_K,true)
	key(KEY_K,false)
	await settle_book()
	check(app.ui.panel=="" and not paused,"K closes the skill book and releases pause")
	key(KEY_ESCAPE,true)
	key(KEY_ESCAPE,false)
	await settle_book()
	check(app.ui.panel=="settings" and paused,"Escape opens the presentation pause panel")
	key(KEY_ESCAPE,true)
	key(KEY_ESCAPE,false)
	await settle_book()
	check(app.ui.panel=="" and not paused,"Escape closes it without double toggling gameplay pause")
	var old_height: float=game.target_camera_height
	mouse(point,true,MOUSE_BUTTON_WHEEL_UP)
	check(is_equal_approx(game.target_camera_height,old_height),"scrolling a HUD control cannot zoom the world camera")
	check(not app.ui_pointer_capture,"wheel events cannot leave a held pointer capture behind")
	await ticks(1)
	mouse(Vector2(640,350),true)
	await ticks(2)
	check(game.player.input_router.held.has("attack_primary"),"ordinary world input still reaches the weapon controller")
	game.player.cancel_charge()
	mouse(Vector2(640,350),false)
	app.ui.show_region("低语森林","测试区域")
	app.ui._process(6.3)
	check(is_zero_approx(app.ui.region_clock),"area announcement automatically fades out")
	app.ui.show_panel("settings")
	await settle_book()
	app.ui._return()
	await settle_book()
	await ticks(4)
	check(not paused and not is_instance_valid(app.game) and app.menu.visible,"return to title releases the old world and pause state")
	check(not app.ui.game_mode and app.ui.panel=="","return to title clears the gameplay presentation")
	await load_adventure()
	check(get_nodes_in_group("player").size()==1,"a second adventure does not duplicate players")
	check(app.ui.BINDINGS.signature()=="1|2|3","returning to title and starting again preserves the session bindings")
	for i in range(3):
		InputMap.action_erase_events(app.ui.BINDINGS.ACTIONS[i])
		for saved in saved_events[i]: InputMap.action_add_event(app.ui.BINDINGS.ACTIONS[i],saved)
	app.queue_free()
	await ticks(18)
	print("FRONTEND_TESTS ",count-failures.size(),"/",count)
	Preferences.settings_path=Preferences.DEFAULT_PATH
	clean_test_tree(test_workspace)
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
