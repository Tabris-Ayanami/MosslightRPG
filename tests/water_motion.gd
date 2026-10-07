extends SceneTree
## Real main-world input, both actor presentations, and rendered water contacts.
## Run on a real renderer with --fixed-fps 30 (stroke and shoreline durations).
var game: Node
var hero: Node
var checks := 0
var failed := 0

func _initialize() -> void: call_deferred("run")
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failed+=1
	print("PASS " if ok else "FAIL ",label)
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func image() -> Image:
	await RenderingServer.frame_post_draw
	return game.viewport.get_texture().get_image()
func changed(a: Image,b: Image) -> int:
	var count := 0
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			var c := a.get_pixel(x,y)
			var d := b.get_pixel(x,y)
			if Vector3(c.r,c.g,c.b).distance_to(Vector3(d.r,d.g,d.b))>.012: count+=1
	return count

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Water motion acceptance needs a GPU.")
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
	game.camera_height=8
	game.target_camera_height=8
	game.camera_yaw=0
	game.camera_pitch_degrees=55
	game.smooth_target=game.GARDEN_ORIGIN+Vector3(-3,.6,16)
	game._resize()
	game._process(0)
	await ticks(10)
	var hp: float=hero.resources.current("HP")
	hero.restore(game.GARDEN_ORIGIN+Vector3(-3,-.1,16))
	await ticks(35)
	var surface: float=game.water_surface_at(hero.global_position)
	check(hero.swimming and hero.animation.current_animation=="swim_tread","actual deep water replaces standing idle with treading")
	check(hero.animation._bone_world("J_Bip_C_Head").origin.y>surface,"treading keeps the skinned head above the surface")
	var hands: Array[Vector3]=hero.animation.water_contact_points()
	await ticks(18)
	var new_hands: Array[Vector3]=hero.animation.water_contact_points()
	check(hands[0].distance_to(new_hands[0])>.025,"treading moves real hand bones")
	var before: Vector3=hero.global_position
	var emitted: int=game.water_interactions.rings_emitted
	Input.action_press("move_right")
	await ticks(60)
	Input.action_release("move_right")
	check(hero.global_position.distance_to(before)>1 and hero.swimming,"actual movement input advances the swimmer")
	check(hero.animation.current_animation=="swim_breaststroke" and absf(hero.animation._rig.rotation.x)>.85,"moving water locomotion leans the body into a breaststroke")
	check(hero.animation._bone_world("J_Bip_C_Head").origin.y>surface+.02,"swimming keeps the head above water")
	check(game.water_interactions.rings_emitted>emitted+1 and game.water_interactions.splashes_emitted>0,"hand strokes emit lingering waves and airborne drops")
	check(hero.resources.current("HP")==hp,"swimming visuals do not change health")
	hero.set_physics_process(false)
	game.water_interactions.set_process(false)
	game.smooth_target=hero.global_position+Vector3(0,.55,0)
	game._process(0)
	game.water_interactions.clear()
	game.water_interactions.contact(Vector3(hero.global_position.x,surface,hero.global_position.z),hero.facing,0,1.0,8)
	game.water_interactions.advance(.32)
	await ticks(4)
	var rippled := await image()
	game.water_material.set_shader_parameter("water_event_count",0)
	await ticks(4)
	var calm := await image()
	check(changed(rippled,calm)>12,"contact waves are visible in the actual water shader")
	var origin: Vector3=game.water_interactions.events[0].at
	hero.global_position=game.checkpoint
	game.water_interactions.advance(.20)
	check(game.water_interactions.events[0].at.is_equal_approx(origin),"waves stay in the water after their actor moves away")
	game.water_interactions.advance(2.0)
	check(game.water_interactions.events.is_empty() and game.water_interactions.droplets.is_empty() and game.water_material.get_shader_parameter("water_event_count")==0,"contact effects expire and release their slots")
	hero.restore(game.checkpoint)
	hero.set_physics_process(true)
	game.water_interactions.set_process(true)
	await ticks(35)
	check(not hero.swimming and hero.animation.water_motion.blend<.001 and hero.animation.current_animation=="travel_idle","dry land restores the existing standing pose")
	# Both humanoid adapters share the stroke clock, including possessed units.
	var unit: Node=game.combat_world.spawn_enemy("soldier",game.GARDEN_ORIGIN+Vector3(-8,-.1,17))
	unit.ai_enabled=false
	await ticks(35)
	check(unit.swimming and unit.animation.current_animation=="swim_tread","another production humanoid also receives swimming presentation")
	var unit_hands: Array[Vector3]=unit.animation.water_contact_points()
	await ticks(16)
	check(unit_hands[1].distance_to(unit.animation.water_contact_points()[1])>.02,"the second humanoid's swimming pose is animated")
	# Walk into and out of the real south bank, rather than synthesizing contacts.
	hero.restore(game.GARDEN_ORIGIN+Vector3(0,2.35,8.1))
	await ticks(30)
	game.water_interactions.clear()
	await ticks(2)
	var entry_splashes: int=game.water_interactions.splashes_emitted
	Input.action_press("move_down")
	await ticks(135)
	Input.action_release("move_down")
	check(hero.swimming and game.water_interactions.splashes_emitted>entry_splashes,"crossing the real bank creates entry / stroke splashes")
	Input.action_press("move_up")
	await ticks(190)
	Input.action_release("move_up")
	await ticks(20)
	check(not hero.swimming and not hero.wading and hero.animation.water_motion.blend<.001,"swimming exits through real shoreline traversal")
	check(hero.resources.current("HP")==hp,"water entry and exit preserve health")
	print("WATER_MOTION_RESULT ",checks-failed,"/",checks)
	game._release_actions()
	game.queue_free()
	for i in range(5): await process_frame
	quit(1 if failed else 0)
