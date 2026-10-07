extends "res://tests/water_motion.gd"
## Actual input verifies swim bursts, both presentations, combat rules and wakes.
## Run on a real renderer with --fixed-fps 60.

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Water dash acceptance needs a GPU.")
		quit(1)
		return
	root.size=Vector2i(1280,720)
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	hero=game.player
	game.sound.muted=true
	game.hud.hide()
	game.combat_world.encounters_started=true
	game.set_process(false)
	game.weather.set_process(false)
	game.weather.set_weather(0,true)
	game.weather.set_time(0,true)
	game.weather.clock=12
	game.weather._apply_environment()
	for actor: Node in game.combat_world.units():
		if actor!=hero: actor.set_physics_process(false)
	hero.restore(game.GARDEN_ORIGIN+Vector3(-3,-.1,23))
	game.camera_height=8
	game.target_camera_height=8
	game.camera_pitch_degrees=76
	game.smooth_target=hero.global_position+Vector3(0,.6,0)
	game._resize()
	game._process(0)
	await ticks(35)
	check(hero.swimming,"dash input starts in actual deep water")
	hero.combat.engage()
	hero.resources.change("Stamina",999)
	var hp: float=hero.resources.current("HP")
	var stamina: float=hero.resources.current("Stamina")
	Input.action_press("move_right")
	await ticks(4)
	var start: Vector3=hero.global_position
	Input.action_press("dodge_dash")
	await ticks(1)
	Input.action_release("dodge_dash")
	Input.action_release("move_right")
	check(hero.combat.state=="DODGE" and hero.animation.current_animation=="swim_dash","real dash input chooses the swim burst")
	check(not hero.combat.dodge_is_dash and hero.combat.dodge_paid>0 and absf(stamina-hero.resources.current("Stamina")-hero.combat.dodge_paid)<.02,"water presentation preserves combat stamina cost")
	check(hero.combat.invulnerable(),"combat water dodge preserves the initial invulnerability window")
	var direction: Vector3=hero.combat.dodge_direction
	var hands: Array[Vector3]=hero.animation.water_contact_points()
	var initial_hand: Vector3=hands[0]-hero.global_position
	var head_margin := INF
	var never_roll := true
	var stowed := true
	var hand_motion := 0.0
	var foot_motion := 0.0
	var previous_foot: Vector3=hero.animation._bone_world("J_Bip_L_Foot").origin-hero.global_position
	var elapsed := 0
	while hero.combat.state=="DODGE" and elapsed<40:
		never_roll=never_roll and hero.animation.skeletal_clip!="Roll" and absf(hero.animation._rig.rotation.x)<1.4
		stowed=stowed and hero.animation.weapons_stowed
		head_margin=minf(head_margin,hero.animation._bone_world("J_Bip_C_Head").origin.y-game.water_surface_at(hero.global_position))
		var hand: Vector3=hero.animation.water_contact_points()[0]-hero.global_position
		hand_motion=maxf(hand_motion,hand.distance_to(initial_hand))
		var foot: Vector3=hero.animation._bone_world("J_Bip_L_Foot").origin-hero.global_position
		foot_motion=maxf(foot_motion,foot.distance_to(previous_foot))
		await ticks(1)
		elapsed+=1
	check(never_roll and stowed,"swim burst never samples Roll and keeps weapons stowed")
	check(head_margin>.02,"burst keeps the skinned head above water: %.3f m"%head_margin)
	check(hand_motion>.12 and foot_motion>.06,"swim burst moves actual arm and leg bones")
	var travel: Vector3=(hero.global_position-start)*Vector3(1,0,1)
	check(travel.length()>2.5 and travel.length()<3.3 and travel.normalized().dot(direction)>.995,"water burst follows its committed direction at swimming speed: %.2f m"%travel.length())
	check(not hero.combat.invulnerable() and hero.resources.current("HP")==hp,"burst completion ends invulnerability and preserves health")
	var wakes := 0
	for event: Dictionary in game.water_interactions.events:
		if event.kind==4: wakes+=1
	check(wakes>=3 and game.water_interactions.splashes_emitted>0,"actual burst movement leaves several wakes and airborne drops")
	hero.set_physics_process(false)
	game.water_interactions.set_process(false)
	game.smooth_target=hero.global_position+Vector3(0,.6,0)
	game._process(0)
	await ticks(4)
	var with_wake := await image()
	game.water_material.set_shader_parameter("water_event_count",0)
	await ticks(4)
	check(changed(with_wake,await image())>12,"burst wakes deform and highlight the production water shader")
	game.water_interactions.advance(2.0)
	check(game.water_interactions.events.is_empty() and game.water_interactions.droplets.is_empty(),"burst contacts expire naturally")
	hero.set_physics_process(true)
	game.water_interactions.set_process(true)
	await ticks(35)
	check(hero.animation.current_animation=="swim_tread" and not hero.animation.water_motion.burst,"burst returns smoothly to treading")
	hero.combat.in_combat=false
	hero.combat.combat_timeout=0
	Input.action_press("dodge_dash")
	await ticks(2)
	Input.action_release("dodge_dash")
	check(hero.animation.current_animation=="swim_dash" and hero.animation.skeletal_clip!="Roll","peaceful water sprint also uses the swim burst")
	check(hero.combat.dodge_is_dash and hero.combat.dodge_paid==0 and not hero.combat.invulnerable(),"peaceful water sprint remains free and does not grant combat invulnerability")
	await ticks(30)
	# The procedural adapter must also have a dedicated burst, not a land pose.
	var unit: Node=game.combat_world.spawn_enemy("soldier",game.GARDEN_ORIGIN+Vector3(-8,-.1,23))
	unit.ai_enabled=false
	await ticks(35)
	unit.move_direction=Vector3.FORWARD
	check(unit.combat.request_dodge(),"another production humanoid can request a water burst")
	await ticks(8)
	check(unit.animation.current_animation=="swim_dash" and unit.animation.water_motion.burst and absf(unit.animation._rig.rotation.x)>.8,"procedural humanoid also leans into the swim burst")
	# Returning to land must restore the original dodge animation and rules.
	hero.restore(game.checkpoint)
	await ticks(35)
	hero.combat.engage()
	Input.action_press("dodge_dash")
	await ticks(2)
	Input.action_release("dodge_dash")
	check(not hero.swimming and hero.animation.skeletal_clip=="Roll" and not hero.animation.water_motion.burst,"dry-land dodge retains its original Roll clip")
	check(hero.combat.invulnerable() and hero.combat.dodge_paid>0,"dry-land combat dodge retains its stamina cost and invulnerability")
	print("WATER_DASH_RESULT ",checks-failed,"/",checks)
	game._release_actions()
	game.queue_free()
	for i in range(5): await process_frame
	quit(1 if failed else 0)
