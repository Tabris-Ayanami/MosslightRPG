extends "res://tests/frontend_rpg.gd"
const NOTES=preload("res://scripts/frontend/trait_notes.gd")

func run() -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate.a=1
	await settle()
	actor=app.game.player
	await click_label("战士")
	check(not str(actor.loadout.sets[0].weapon).is_empty(),"native career selection equips the starter weapon")
	if str(actor.loadout.sets[0].weapon).is_empty():
		await capture("traveller-career-failure")
		quit(1)
		return
	check(actor.progression.acquired_traits.is_empty(),"a new adventure never acquires art-preview blessings")
	check(not actor.progression.grant_trait("nonexistent","测试"),"unknown trait identifiers are rejected")
	check(actor.progression.grant_trait("steadfast","林间石碑","祝福"),"a non-career acquired trait stores its origin")
	check(not actor.progression.grant_trait("steadfast","重复来源"),"acquisition cannot stack a second copy of the same passive")
	await ticks(3)
	var definitions: Array=actor.combat.passives.definitions()
	check(definitions.any(func(d: Dictionary): return d.id=="steadfast"),"registered blessings participate in the actual passive engine")
	var bonus: Dictionary=actor.combat.passives.modifiers("stat_update",actor.combat.context())
	check(is_equal_approx(float(bonus.get("Poise",0)),20),"the acquired steadfast passive contributes its actual conditional 20 poise")
	var saved: Dictionary=actor.progression.export_state()
	actor.progression.revoke_trait("steadfast")
	check(not actor.combat.passives.definitions().any(func(d: Dictionary): return d.id=="steadfast"),"removing a blessing removes its combat effect")
	actor.progression.import_state(saved)
	await ticks(3)
	check(actor.progression.acquired_traits.steadfast.source=="林间石碑","save round-trip preserves trait origin")
	await click_label("特性")
	check(app.ui.character_tab==2 and not app.ui.paper_doll.visible,"traits are an independent character spread")
	await click_label("坚定")
	var entry: Dictionary=app.ui.traits()[app.ui.selected_trait]
	check(entry.source=="林间石碑" and entry.effects.contains("20") and entry.condition.contains("80%"),"selected trait shows source, real condition and numeric effect")
	for d: Dictionary in actor.loadout.database.passives.values():
		var note: Dictionary=NOTES.notes(d,actor.loadout.database)
		check(not note.effects.is_empty(),"passive explanation available: "+d.id)
	var top_count := 0
	for b in app.ui.modal.get_children():
		if b is Button and b.get("role")=="top_bookmark":
			top_count+=1
			check(b.size.y<86 and b.z_index>app.ui.cover.z_index and b.z_index<app.ui.paper.z_index,"short top bookmark lies between cowhide cover and first page")
	check(top_count==3,"character offers panel, career and traits bookmarks")
	await click_label("背包")
	await select_item("healing_potion")
	var count_before: int=actor.inventory.count("healing_potion")
	await click_label("丢弃")
	check(actor.inventory.count("healing_potion")==count_before,"discard gesture alone does not destroy an item")
	await click_label("还是留着")
	check(not app.ui.discard_confirm and actor.inventory.count("healing_potion")==count_before,"cancel keeps the item")
	await click_label("丢弃")
	await click_label("丢弃一件")
	check(actor.inventory.count("healing_potion")==count_before-1,"confirmed discard removes exactly one owned consumable")
	check(not actor.inventory.discard_item(actor.loadout.weapon_at(0).id),"an equipped weapon cannot be discarded")
	app.ui.close_panel(true)
	key(KEY_M,true);key(KEY_M,false)
	await settle()
	check(app.ui.panel=="map" and app.ui.unfolded_map.visible and paused,"M unfolds the chart and pauses gameplay")
	var mini: Control=app.ui.minimap
	var chart: Control=app.ui.unfolded_map
	check(is_instance_valid(mini.document) and mini.document.houses.size()==7 and mini.document.trees.size()>40,"atlas reads real village buildings and woodland placements")
	var origin: Vector2=mini._get_world_2d_pos(actor)
	check(origin.distance_to(Vector2(1.6,4.8))<1,"map coordinates remove the distant WaterGarden world offset")
	check(mini._world_to_minimap(origin).distance_to(Vector2.ONE*mini.radius)<.001,"upstream projection keeps the real player centered")
	check(chart.unproject(chart.project(origin)).distance_to(origin)<.0001,"full chart projection and inverse agree")
	var height: Image=mini.document.elevation.get_image()
	var island_uv: Vector2=(Vector2(0,0)-mini.document.BOUNDS.position)/mini.document.BOUNDS.size
	var water_uv: Vector2=(Vector2(-25,0)-mini.document.BOUNDS.position)/mini.document.BOUNDS.size
	check(height.get_pixelv(Vector2i(island_uv*Vector2(height.get_size()-Vector2i.ONE))).r>.37,"atlas waits for terrain storage before sampling actual land")
	check(height.get_pixelv(Vector2i(water_uv*Vector2(height.get_size()-Vector2i.ONE))).r<.36,"open water stays water in the atlas")
	var anchor: Vector2=chart.plot.get_center()+Vector2(76,-21)
	var before: Vector2=chart.unproject(anchor)
	var world_height: float=app.game.target_camera_height
	var zoom: float=chart.zoom
	mouse(app.ui.get_global_transform()*anchor,true,MOUSE_BUTTON_WHEEL_UP)
	await ticks(2)
	check(chart.zoom>zoom and chart.unproject(anchor).distance_to(before)<.001,"native wheel zoom anchors the map point under the pointer")
	check(is_equal_approx(app.game.target_camera_height,world_height),"map wheel never changes the game camera height")
	var focus_before: Vector2=chart.focus
	var shift := Vector2(36,18)
	mouse(app.ui.get_global_transform()*anchor,true)
	await ticks(1)
	var drag := InputEventMouseMotion.new()
	drag.position=root.get_final_transform()*(app.ui.get_global_transform()*(anchor+shift))
	drag.global_position=drag.position
	drag.relative=root.get_final_transform().basis_xform(app.ui.get_global_transform().basis_xform(shift))
	drag.button_mask=MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(drag)
	await ticks(1)
	mouse(app.ui.get_global_transform()*(anchor+shift),false)
	await ticks(2)
	check(chart.focus.distance_to(focus_before-shift/chart.scale_factor())<.01,"native dragging moves the chart by the correct scaled world distance")
	check(not chart.pin.is_finite(),"dragging never leaves an accidental pencil pin")
	mouse(app.ui.get_global_transform()*anchor,true);mouse(app.ui.get_global_transform()*anchor,false)
	await ticks(2)
	check(chart.pin.distance_to(chart.unproject(anchor))<.01,"a short native click places a pencil mark at the clicked world point")
	mouse(app.ui.get_global_transform()*anchor,true,MOUSE_BUTTON_RIGHT)
	mouse(app.ui.get_global_transform()*anchor,false,MOUSE_BUTTON_RIGHT)
	await ticks(2)
	check(not chart.pin.is_finite(),"right click erases the temporary map mark")
	var original_position: Vector3=actor.global_position
	var original_facing: Vector3=actor.facing
	actor.global_position+=Vector3(7,0,-3)
	actor.facing=Vector3.RIGHT
	check(mini._get_world_2d_pos(actor).distance_to(origin+Vector2(7,-3))<.001,"live map tracking follows movement rather than a fixed origin")
	check(is_equal_approx(mini.heading_angle(),PI*.5),"player arrow reads actual facing independently of camera yaw")
	actor.global_position=original_position
	actor.facing=original_facing
	var blocked := InputEventKey.new()
	blocked.physical_keycode=KEY_M
	check(not app.ui.BINDINGS.assign(0,blocked),"M remains reserved during skill remapping")
	key(KEY_ESCAPE,true);key(KEY_ESCAPE,false)
	check(paused,"the world remains paused while the scroll rolls closed")
	await settle()
	check(app.ui.panel=="" and not paused,"Escape closes only the map and resumes the world")
	var map_point: Vector2=mini.get_global_transform()*(mini.size*.5)
	mouse(map_point,true)
	await ticks(1)
	mouse(map_point,false)
	await settle()
	check(app.ui.panel=="map" and not actor.combat.runner.busy(),"clicking the live minimap opens the chart without firing a weapon")
	key(KEY_M,true);key(KEY_M,false)
	await settle()
	check(not paused and app.ui.panel=="","M toggles the chart closed")
	app.ui.show_panel("character")
	await settle()
	root.size=Vector2i(960,540)
	await ticks(4)
	await click_label("特性")
	check(app.ui.character_tab==2,"buried leather bookmarks stay clickable at 960 by 540")
	app.ui.close_panel(true)
	app.queue_free()
	await ticks(12)
	print("TRAVELLER_JOURNAL ",checks-failures.size(),"/",checks)
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
