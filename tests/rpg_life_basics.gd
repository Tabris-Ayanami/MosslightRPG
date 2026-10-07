extends SceneTree
const Preferences=preload("res://rpg/game_preferences.gd")
var game: Node
var actor: Node
var checks := 0
var failures: Array[String]=[]
var punches: Array[String]=[]
func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func press(action: String,frames := 2) -> void:
	Input.action_press(action)
	await ticks(frames)
	Input.action_release(action)
	await ticks(36)
func run() -> void:
	Preferences.settings_path=OS.get_temp_dir().path_join("mosslight-life-basics-%d-%d.cfg"%[OS.get_process_id(),Time.get_ticks_usec()])
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(15)
	actor=game.player
	game.sound.muted=true
	game.combat_world.encounters_started=true
	check(actor.loadout.level==0 and actor.resources.max_value("HP")==100 and actor.resources.max_value("Stamina")==3,"civilian level zero has concrete HP and stamina")
	check(preload("res://scripts/frontend/rpg_view_model.gd").build(actor,"旅人").career=="平民","level zero is named civilian in the character sheet")
	for index in range(2): check(actor.loadout.weapon_at(index).get("unarmed",false),"empty group %d provides a fist action source"%index)
	check(not actor.animation._weapon.visible,"civilian holds no invisible sword geometry")
	var foe: Node=game.combat_world.spawn_enemy("soldier",actor.global_position+Vector3(1.05,0,0))
	foe.set_physics_process(false)
	foe.resources.configure("HP",2000)
	game.aim_override=foe.global_position
	actor.combat.runner.action_started.connect(func(action: Dictionary): punches.append(action.get("id","")))
	var hp: float=foe.resources.current("HP")
	await press("attack_primary")
	check(foe.resources.current("HP")<hp,"real level-zero left click deals fist damage")
	check(punches.back()=="plain_punch_left","first actual click starts left straight punch")
	hp=foe.resources.current("HP")
	await press("attack_primary")
	check(foe.resources.current("HP")<hp and punches.back()=="plain_punch_right","second actual click alternates to right fist and hits")
	await press("attack_secondary")
	check(punches.back()=="plain_punch_heavy","right click offers a valid heavy punch")
	var count := punches.size()
	await press("attack_primary",28)
	check(punches.size()==count+1 and actor.combat.state in ["NORMAL","MOVE"],"long-held empty-hand click releases one punch without charge lock")
	check(actor.inventory.item_ids().is_empty(),"innate fists never create phantom inventory items")
	check(actor.progression.choose_career("warrior") and actor.loadout.level==1,"civilian still chooses a base career normally")
	check(actor.inventory.count("magic_candy")==0 and actor.loadout.weapon().get("weapon_type")=="Sword","first profession grants normal equipment without debug candy")
	check(actor.loadout.equip_weapon(0,"") and actor.loadout.weapon().get("unarmed",false),"unequipping a later weapon also restores safe fist fallback")
	actor.health.receive(25)
	var saved_hp: float=actor.resources.current("HP")
	var water_y: float=game.water_surface_at(game.GARDEN_ORIGIN)
	var shore := Vector3.ZERO
	var found := false
	for x in range(-18,20):
		if found: break
		for z in range(-16,17):
			var at: Vector3=game.GARDEN_ORIGIN+Vector3(x*.8,5,z*.8)
			var query := PhysicsRayQueryParameters3D.create(at,at-Vector3.UP*12,1)
			var hit: Dictionary=actor.get_world_3d().direct_space_state.intersect_ray(query)
			if not hit.is_empty() and hit.position.y>water_y-.35 and hit.position.y<water_y-.12 and hit.normal.y>.8:
				shore=hit.position+Vector3.UP*.025
				found=true
				break
	check(found,"locate a real shallow shore on the unchanged terrain")
	if found:
		actor.global_position=shore
		actor.velocity=Vector3.ZERO
		await ticks(24)
		check(actor.wading and not actor.swimming,"shallow shore remains ordinary wading")
		check(actor.global_position.distance_to(shore)<.5 and actor.resources.current("HP")==saved_hp,"shallow water neither teleports nor resets health")
	var deep: Vector3=game.GARDEN_ORIGIN+Vector3(75,water_y-.8,-30)
	actor.global_position=deep
	actor.velocity=Vector3.ZERO
	await ticks(100)
	var animated_surface: float=game.water_surface_at(actor.global_position)
	check(actor.swimming and absf(actor.global_position.y-(animated_surface-.70))<.04,"deep water supports stable buoyancy on the moving surface")
	check(actor.resources.current("HP")==saved_hp and actor.global_position.distance_to(game.checkpoint)>30,"deep water never calls death or checkpoint respawn")
	var before: Vector3=actor.global_position
	Input.action_press("move_right")
	await ticks(60)
	Input.action_release("move_right")
	var distance: float=actor.global_position.distance_to(before)
	check(distance>1.6 and distance<3.6,"player can swim slowly using actual movement input")
	check(actor.resources.current("HP")==saved_hp,"swimming preserves combat health")
	actor.global_position=game.checkpoint
	actor.velocity=Vector3.ZERO
	await ticks(20)
	check(not actor.swimming and not actor.wading and is_equal_approx(actor.move_speed,5.2),"dry land restores normal movement state and speed")
	game._release_actions()
	game.queue_free()
	await ticks(3)
	print("RPG_LIFE_BASICS: %d checks; %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
