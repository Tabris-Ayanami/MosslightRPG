extends "res://tests/frontend_rpg.gd"
var output_dir := "res://docs/world-interaction"
func shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	root.get_texture().get_image().save_png(output_dir.path_join(name+".png"))
func hover(point: Vector2) -> void:
	var motion:=InputEventMouseMotion.new()
	motion.position=root.get_final_transform()*point
	motion.global_position=motion.position
	Input.parse_input_event(motion)
func context_ticks(game: Node, point: Vector2, count: int) -> void:
	# An offscreen Windows window reports the real desktop cursor outside its
	# bounds. Advance the real context controller with the supplied pointer;
	# wheel events still travel through native Input -> app -> world UI routing.
	for i in range(count):
		await ticks(1)
		game.world_ui.update_context(1.0/60.0,point)
		game.world_ui.feed.tick(1.0/60.0,point,false)
func run() -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=app.SAVE_REPOSITORY.new(OS.get_temp_dir().path_join("interaction-preview-%d"%Time.get_ticks_usec()))
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate.a=1
	await settle()
	var game: Node=app.game
	actor=game.player
	actor.progression.choose_career("warrior")
	app.ui.close_panel()
	await settle()
	app.ui.region_clock=0
	game.combat_world.encounters_started=true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	game.sound.muted=true
	var npc: Node3D=game.narrative_npcs[0]
	var merchant: Node3D=game.narrative_npcs[1]
	actor.restore(merchant.global_position+Vector3(0,0,1.6))
	await ticks(80)
	game.notify("拾得 · 木材 ×3",Color("e7cc9c"))
	game.notify("发现 · 风铃村的守望人")
	game.notify("获得 · 生命药水 ×1",Color("d7dcb1"))
	var menu: Control=game.world_ui.menu
	game.world_ui.set_process(false)
	var merchant_point: Vector2=game.world_to_screen(merchant.global_position+Vector3.UP*1.1)
	hover(merchant_point)
	await context_ticks(game,merchant_point,24)
	check(menu.expanded>.95 and game.world_ui.pointed_object==merchant,"pointer over merchant opens world choices")
	var zoom: float=game.target_camera_height
	mouse(merchant_point,true,MOUSE_BUTTON_WHEEL_DOWN)
	await context_ticks(game,merchant_point,18)
	check(menu.selected==1 and game.target_camera_height==zoom,"native wheel over merchant selects trade without zoom")
	await shot("01-context-and-feed")
	hover(Vector2(20,500))
	await context_ticks(game,Vector2(20,500),24)
	check(menu.selected==0 and menu.expanded==0 and menu.show_selected_when_closed,"moving away leaves the default verb visible")
	await shot("01b-context-folded")
	var ladder: Node3D=get_first_node_in_group("village_ladders")
	actor.restore(ladder.bottom_exit())
	game.camera_yaw=0
	await ticks(80)
	await context_ticks(game,Vector2(20,500),24)
	await shot("01c-ladder-default")
	var ladder_point: Vector2=game.world_to_screen(ladder.to_global(Vector3(0,1.3,0)))
	hover(ladder_point)
	await context_ticks(game,ladder_point,24)
	check(menu.expanded>.95 and game.world_ui.pointed_object==ladder,"pointer over ladder rungs opens dismantle")
	await shot("01d-ladder-hover")
	mouse(ladder_point,true,MOUSE_BUTTON_WHEEL_DOWN)
	await context_ticks(game,ladder_point,18)
	check(menu.selected==1 and game.target_camera_height==zoom,"native wheel over ladder selects dismantle")
	await shot("01e-ladder-selected")
	hover(Vector2(20,500))
	game.world_ui.set_process(true)
	game.camera_yaw=game.DEFAULT_CAMERA_YAW
	actor.restore(npc.global_position+Vector3(0,0,1.6))
	await ticks(70)
	game.interactions.execute(npc,"talk")
	await ticks(24)
	await shot("02-speaking")
	await ticks(65)
	game.dialogue_panel._activate()
	await ticks(90)
	await shot("03-player-choices")
	key(KEY_W,true)
	await ticks(29)
	await shot("04-hold-to-leave")
	key(KEY_W,false)
	await ticks(3)
	game.dialogue_panel.close()
	await ticks(8)
	for skin_id in ["demon_bubble","king_bubble"]:
		npc.set_meta("bubble_skin_id",skin_id)
		game.interactions.execute(npc,"talk")
		await ticks(95)
		await shot("skin-"+skin_id)
		game.dialogue_panel.close()
		await ticks(4)
	npc.remove_meta("bubble_skin_id")
	app.queue_free()
	await ticks(6)
	print("WORLD_INTERACTION_PREVIEW complete")
	quit(0 if failures.is_empty() else 1)
