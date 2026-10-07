extends SceneTree
const Feed=preload("res://rpg/event_feed.gd")
const Menu=preload("res://rpg/world_action_menu.gd")
const Guard=preload("res://rpg/mutation_guard.gd")
const Repository=preload("res://rpg/save_repository.gd")
const Picker=preload("res://rpg/interaction_picker.gd")
var checks:=0
var failures: Array[String]=[]
var game: Node

func _initialize() -> void: call_deferred("run")
func check(ok: bool, text: String) -> void:
	checks+=1
	if not ok: failures.append(text)
	print("PASS " if ok else "FAIL ",text)
func ticks(count:=3) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func seed_for(caught: bool) -> int:
	var probe:=RandomNumberGenerator.new()
	for value in range(100):
		probe.seed=value
		if (probe.randf()<.42)==caught: return value
	return -1
func key(code: Key) -> void:
	for down in [true,false]:
		var event:=InputEventKey.new()
		event.keycode=code
		event.physical_keycode=code
		event.pressed=down
		Input.parse_input_event(event)
		await process_frame

func run() -> void:
	root.size=Vector2i(1280,720)
	create_timer(100,true).timeout.connect(func(): printerr("WORLD_INTERACTION timeout"); quit(2))
	var feed:=Feed.new()
	root.add_child(feed)
	feed.set_process(false)
	for i in range(8): feed.push("木材 ×%d" % i)
	feed.tick(6,Vector2(-100,-100))
	check(feed.entries.size()==8,"event history lasts longer than the five-second combat timeout")
	feed.tick(20,Vector2(20,20))
	check(feed.entries.size()==8 and feed.entries[0].remaining>=7,"hover suspends expiry and grants a seven-second reading grace")
	var wheel:=InputEventMouseButton.new()
	wheel.position=Vector2(20,20)
	wheel.button_index=MOUSE_BUTTON_WHEEL_UP
	wheel.pressed=true
	feed.handle_pointer(wheel)
	check(feed.scroll_offset==1,"hover wheel scrolls retained history")
	feed.tick(6,Vector2(-100,-100))
	check(feed.entries.size()==8,"moving away retains the reading grace")
	feed.tick(2,Vector2(-100,-100))
	check(feed.entries.is_empty() and feed.scroll_offset==0,"expired records are actually removed and scroll resets")
	feed.push("new")
	check(feed.entries.size()==1,"new arrivals cannot revive cleared history")
	for i in range(80): feed.push(str(i))
	check(feed.entries.size()==64,"event history is bounded during sustained hover")
	feed.queue_free()
	var menu:=Menu.new()
	root.add_child(menu)
	var choices: Array[Dictionary]=[]
	for i in range(8): choices.append({"id":str(i),"label":"操作 %d"%i})
	menu.set_entries(choices,true)
	menu.tick(.1,Menu.BADGE)
	check(menu.expanded>0 and menu.expanded<1,"hover opening has intermediate animation frames")
	menu.tick(.3,Menu.BADGE)
	menu.scroll_by(4)
	check(menu.selected==4 and menu.visible_indices()==[3,4,5],"virtual list exposes only previous, selected and next rows")
	menu.tick(.1,Vector2(-100,-100))
	check(menu.expanded>0 and menu.expanded<1,"leaving folds choices back into F gradually")
	menu.tick(.3,Vector2(-100,-100))
	check(menu.expanded==0 and not menu._has_point(Vector2(100,45)),"collapsed menu releases the transparent surrounding area")
	menu.queue_free()
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene=game
	await ticks(20)
	game.combat_world.encounters_started=true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	game.player.progression.choose_career("warrior")
	var npc: Node3D=game.narrative_npcs[0]
	game.player.restore(npc.global_position+Vector3(0,0,1.4))
	await ticks(40)
	check(game.world_ui.target==npc and game.world_ui.menu.visible,"nearby NPC has an anchored F menu")
	check(not game.combat_world.are_hostile(game.player,npc),"ordinary villagers are neutral combat actors")
	check((npc.collision_layer & 1)!=0,"neutral villagers retain solid body collision")
	check(game.world_ui.menu.show_selected_when_closed and game.world_ui.menu.selected==0,"approaching shows the default verb without hovering")
	var object_point: Vector2=game.world_to_screen(npc.global_position+Vector3.UP*1.1)
	check(Picker.pointed_at(game,object_point)==npc,"pointing at the actual villager finds its visible body")
	var native_motion:=InputEventMouseMotion.new()
	native_motion.position=root.get_final_transform()*object_point
	native_motion.global_position=native_motion.position
	Input.parse_input_event(native_motion)
	await ticks(20)
	check(game.world_ui.menu.expanded>.95 and game.world_ui.pointed_object==npc,"native mouse motion opens alternatives through the normal frame update")
	native_motion=native_motion.duplicate()
	native_motion.position=root.get_final_transform()*Vector2(8,8)
	native_motion.global_position=native_motion.position
	Input.parse_input_event(native_motion)
	await ticks(20)
	game.world_ui.update_context(.3,object_point)
	check(game.world_ui.menu.expanded==1 and game.world_ui.pointed_object==npc,"hovering the object opens alternatives without entering the label")
	var object_zoom: float=game.target_camera_height
	wheel.position=object_point
	wheel.button_index=MOUSE_BUTTON_WHEEL_DOWN
	game._camera_input(wheel)
	check(game.world_ui.menu.selected==1 and game.target_camera_height==object_zoom,"wheel on the 3D object selects an alternative and consumes camera zoom")
	game.world_ui.update_context(.3,Vector2(8,8))
	check(game.world_ui.menu.expanded==0 and game.world_ui.menu.selected==0,"leaving closes alternatives and restores the default action")
	game.world_ui.update_context(.3,game.world_ui.menu.get_global_transform()*(Menu.BADGE+Vector2(60,0)))
	check(game.world_ui.menu.expanded==0,"the collapsed action label is not the trigger for opening alternatives")
	var blocker:=StaticBody3D.new()
	var obstruction:=CollisionShape3D.new()
	var box:=BoxShape3D.new()
	box.size=Vector3(2,2,.3)
	obstruction.shape=box
	blocker.add_child(obstruction)
	npc.get_parent().add_child(blocker)
	blocker.global_transform=Transform3D(game.camera.global_basis,npc.global_position+Vector3.UP*1.1+game.camera.global_basis.z*2.5)
	await ticks(2)
	check(Picker.pointed_at(game,game.world_to_screen(npc.global_position+Vector3.UP*1.1))==null,"an intervening wall blocks object hover")
	blocker.queue_free()
	await ticks(2)
	var merchant: Node3D=game.narrative_npcs[1]
	var merchant_home:=merchant.global_transform
	merchant.global_position=npc.global_position+Vector3(1.4,0,0)
	await ticks(2)
	game.world_ui.update_context(.3,game.world_to_screen(merchant.global_position+Vector3.UP*1.1))
	check(game.world_ui.target==merchant and game.nearest_interactable()==npc,"pointed reachable object wins over a different nearest object")
	merchant.global_transform=merchant_home
	game.world_ui.update_context(.3,Vector2(8,8))
	var near_position: Vector3=game.player.global_position
	game.player.global_position=npc.global_position+Vector3(0,0,3.5)
	check(Picker.pointed_at(game,game.world_to_screen(npc.global_position+Vector3.UP*1.1))!=npc,"pointing at an out-of-reach object cannot offer remote interaction")
	game.player.global_position=near_position
	var before_point: Vector2=game.world_ui.menu.position
	game.camera_yaw+=.6
	game.target_camera_height=12
	await ticks(40)
	var anchor: Vector2=game.world_to_screen(game.interactions.anchor(npc))
	var factor: float=game.world_ui.menu.scale.x
	var projected_y: float=game.world_ui.menu.position.y+Menu.BADGE.y*factor
	check(absf(anchor.y-projected_y)<1 and game.world_ui.menu.position.distance_to(before_point)>2,"anchor follows orbit and zoom with pixel overscan compensation")
	check(Picker.pointed_at(game,game.world_to_screen(npc.global_position+Vector3.UP*1.1))==npc,"body picking stays aligned after rotating and zooming the camera")
	game.world_ui.menu.expanded=1
	var point: Vector2=game.world_ui.menu.get_global_transform()*Menu.BADGE
	var zoom: float=game.target_camera_height
	wheel.position=point
	wheel.button_index=MOUSE_BUTTON_WHEEL_DOWN
	check(game.world_ui.handle_pointer(wheel) and game.world_ui.menu.selected==1,"hover wheel selects theft in the F row")
	check(game.target_camera_height==zoom,"interaction wheel leaves camera height unchanged")
	check(game.world_ui.blocks_pointer(point),"world pointer is blocked over the contextual menu")
	game.camera_dragging=true
	var orbit_release:=InputEventMouseButton.new()
	orbit_release.position=point
	orbit_release.button_index=MOUSE_BUTTON_MIDDLE
	orbit_release.pressed=false
	check(game.world_ui.handle_pointer(orbit_release) and not game.camera_dragging,"releasing middle mouse over the menu always ends an existing orbit")
	game.world_ui.menu.selected=0
	await key(KEY_F)
	await ticks(8)
	check(game.dialogue_open() and game.paused and paused,"F opens the NPC conversation and the host owns pause")
	check(game.dialogue_panel._anchor.get_ref()==npc and game.dialogue_panel.speaker.text.contains("艾琳"),"dialogue follows the same NPC rather than a fixed bottom window")
	check(not game.dialogue_panel.paper is PanelContainer,"speech has no rectangular paper panel")
	if not game.dialogue_panel._typing.finished: await key(KEY_F)
	await key(KEY_F)
	await ticks(8)
	check(game.dialogue_panel._response_ids.size()==2,"real Dialogue Manager exposes the quest choices")
	if not game.dialogue_panel._typing.finished: await key(KEY_F)
	await ticks(3)
	check(game.dialogue_panel.choice_bubble.visible and game.dialogue_panel.choice_bubble.skin_id=="player_bubble","choices use the cloud-white bubble over the player")
	await key(KEY_F)
	await ticks(8)
	check(game.quests.status("village_patrol")=="active","F confirms the currently selected branch and accepts the real quest")
	var standing: Vector3=game.player.global_position
	var held_move:=InputEventKey.new()
	held_move.keycode=KEY_W
	held_move.physical_keycode=KEY_W
	held_move.pressed=true
	Input.parse_input_event(held_move)
	await create_timer(.42,true).timeout
	check(game.dialogue_open() and game.dialogue_panel.exit_progress>.2 and game.dialogue_panel.exit_progress<.85,"holding movement first fills the gray foot ring without ending dialogue")
	check(game.player.global_position.distance_to(standing)<.01,"player remains standing still throughout the hold threshold")
	held_move=held_move.duplicate()
	held_move.pressed=false
	Input.parse_input_event(held_move)
	await ticks(3)
	check(game.dialogue_open() and game.dialogue_panel.exit_progress==0,"releasing movement early cancels exit progress")
	held_move=held_move.duplicate()
	held_move.pressed=true
	Input.parse_input_event(held_move)
	await create_timer(1.15,true).timeout
	check(not game.dialogue_open() and not paused and not game.paused,"one second of held movement closes dialogue and resumes the world")
	await ticks(5)
	check(game.player.global_position.distance_to(standing)>.15,"movement continues after closing without needing another key press")
	held_move=held_move.duplicate()
	held_move.pressed=false
	Input.parse_input_event(held_move)
	await ticks(3)
	check(not Input.is_action_pressed("move_up"),"releasing the movement key after exit stops the resumed input")
	game.player.restore(npc.global_position+Vector3(0,0,1.4))
	await ticks(4)
	var neutral: Dictionary=game.world_state.export_state()
	var potions: int=game.player.inventory.count("healing_potion")
	game.interactions.rng.seed=seed_for(false)
	check(game.interactions.execute(npc,"steal"),"successful theft is a world interaction")
	check(game.player.inventory.count("healing_potion")==potions+1 and not npc.hostile,"successful theft grants the actual inventory item")
	check(not game.interactions.execute(npc,"steal") and game.player.inventory.count("healing_potion")==potions+1,"repeated theft cannot duplicate a reward")
	game.world_state.import_state(neutral)
	game.refresh_world_objects()
	Guard.acquire(game.world_state,"test")
	check(not game.interactions.execute(npc,"steal"),"concurrent mutation lock rejects theft")
	Guard.release(game.world_state,"test")
	game.interactions.rng.seed=seed_for(true)
	check(game.interactions.execute(npc,"steal"),"caught theft resolves")
	check(npc.hostile and npc.control_mode=="ai" and game.combat_world.are_hostile(game.player,npc),"caught villager becomes an actual AI hostile using the same actor")
	check((npc.collision_layer & 1)==0 and game.combat_world.line_clear(game.player.global_position,npc.global_position),"hostile villager can be targeted without its own body blocking the sight ray")
	check(npc.combat.in_combat and game.player.combat.in_combat,"caught theft immediately enters actual combat")
	check(not game.begin_dialogue(npc.definition,npc),"hostile NPC cannot be paused into dialogue")
	var events: int=game.world_state.get_event_count("enemy_defeated")
	npc.combat.receive_damage({"formula":{"base":999999},"can_crit":false,"damage_type":"PHYSICAL"},game.player,Vector3.FORWARD)
	check(npc.dead and game.world_state.get_object(npc.social_id()).defeated,"NPC defeat persists through the real damage system")
	check(game.world_state.get_event_count("enemy_defeated")==events,"villager defeat does not farm patrol quests or normal enemy loot")
	game.player.combat.reset()
	var ladder: Node3D=get_first_node_in_group("village_ladders")
	game.player.restore(ladder.bottom_exit())
	game.camera_yaw=0
	await ticks(60)
	var rung_gap: Vector2=game.world_to_screen(ladder.to_global(Vector3(0,1.3,0)))
	check(Picker.pointed_at(game,rung_gap)==ladder,"the empty space between ladder rungs also hovers the ladder")
	game.world_ui.update_context(.3,rung_gap)
	wheel.position=rung_gap
	game._camera_input(wheel)
	check(game.world_ui.target==ladder and game.world_ui.menu.selected==1,"wheel pointed at ladder chooses dismantle")
	game.world_ui.update_context(.3,Vector2(8,8))
	check(game.world_ui.menu.selected==0,"moving off the ladder restores climb as the default")
	check(game.interactions.execute(ladder,"climb") and game.player.ladder.active,"ladder action enters physical traversal")
	check(not game.interactions._dismantle(ladder) and not ladder.dismantled,"occupied ladder cannot be dismantled")
	game.player.ladder.detach("test",true)
	game.player.restore(ladder.bottom_exit())
	await ticks(4)
	var wood: int=game.player.inventory.count("wood")
	check(game.interactions.execute(ladder,"dismantle"),"dismantling commits the world action")
	check(ladder.dismantled and game.player.inventory.count("wood")==wood+3,"ladder disappears and gives three actual wood items")
	check(Picker.pointed_at(game,rung_gap)!=ladder,"a dismantled ladder cannot keep an invisible hover target")
	check(not game.interactions.execute(ladder,"dismantle") and game.player.inventory.count("wood")==wood+3,"removed ladder cannot pay wood twice")
	check(game.player.inventory.definition("wood").category=="material" and not game.player.inventory.assign_quick_slot(0,"wood"),"wood belongs to materials and cannot become a consumable shortcut")
	var repo:=Repository.new(OS.get_temp_dir().path_join("world-interaction-%d"%Time.get_ticks_usec()))
	var created: Dictionary=repo.create("林间交互")
	var saved: Dictionary=repo.save(created.slot,"林间交互",game.player,game)
	check(saved.ok,"interaction records pass the full save validator")
	game.world_state.import_state(neutral)
	game.refresh_world_objects()
	check(not ladder.dismantled and not npc.hostile and not npc.dead,"switching to a neutral state restores ladder and NPC")
	var restored: Dictionary=repo.restore(saved.snapshot,game.player,game)
	check(restored.ok and ladder.dismantled and npc.hostile and npc.dead,"save restore reinstates dismantling and NPC outcome without replaying rewards")
	var corrupt: Dictionary=saved.snapshot.duplicate(true)
	corrupt.world_state.objects[ladder.persistent_id].dismantled="yes"
	check(not repo.restore(corrupt,game.player,game).ok,"invalid interaction save records are rejected before restoring")
	game.queue_free()
	await ticks(6)
	print("WORLD_INTERACTION %d/%d passed"%[checks-failures.size(),checks])
	quit(0 if failures.is_empty() else 1)
