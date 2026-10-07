extends SceneTree
const Repo = preload("res://rpg/save_repository.gd")
const View = preload("res://scripts/frontend/rpg_view_model.gd")
const Inn = preload("res://rpg/inn_room.gd")
const SOLDIER := "encounter.forest.soldier_01"
var checks := 0
var failures: Array[String] = []
var game: Node
var player: Node
var damage_report := {}

func _initialize() -> void: call_deferred("run")
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
	print("PASS " if value else "FAIL ",label)
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func ready_at(point: Vector3) -> void:
	player.combat.reset()
	player.global_position=point
	player.velocity=Vector3.ZERO
	game.aim_override=point+Vector3.FORWARD*3
	for enemy in game.combat_world.enemies:
		enemy.ai_enabled=false
		enemy.set_physics_process(false)
		enemy.current_target=null
		enemy.combat.in_combat=false
	game.rest_service.refresh()

func run() -> void:
	create_timer(110,true).timeout.connect(func(): printerr("REST_TARGET timeout"); quit(1))
	var repo := Repo.new(OS.get_temp_dir().path_join("mosslight-rest-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()]))
	var created: Dictionary = repo.create("旅馆与战斗测试")
	check(created.ok,"create isolated named adventure")
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(18)
	player=game.player
	game.sound.muted=true
	check(player.progression.choose_career("barbarian"),"choose real career and retain starter ownership")
	check(player.progression.max_level()==5 and game.combat_world.database.progression.rules.max_level==20,"chapter level cap five, global cap twenty")
	player.progression.add_experience(100000)
	check(player.loadout.level==5,"large XP reward cannot exceed chapter cap")
	var plan: Dictionary = player.progression.plan_enemy_reward("ogre")
	check(plan.ok and plan.level==5,"enemy reward planner respects chapter cap")
	player.progression.experience=23
	plan=player.progression.plan_enemy_reward("soldier")
	check(plan.ok and plan.experience==23,"existing experience at chapter cap is preserved")
	player.progression.experience=0
	check(View.icon(game.combat_world.database.weapons.bone_greataxe)=="axe" and View.icon(game.combat_world.database.weapons.border_spear)=="spear","HUD axe and spear have distinct correct types")
	var rest: Node = game.rest_service
	check(rest.places.trees.size()>=2,"real large forest trees offer short rest")
	ready_at(Inn.DOOR+Vector3(1.1,.06,.4))
	check(not rest.execute(rest.places.door,"room_rent") and not rest.inside(),"insufficient copper cannot enter paid room")
	game.world_state.set_object("economy.wallet",{"version":1,"balance":50,"revision":0})
	check(rest.execute(rest.places.door,"room_rent"),"pay to rent and enter physical inn interior")
	check(rest.inside() and rest.places.room.visible and game.economy.balance()==35,"room entered and price charged exactly once")
	await ticks(5)
	check(player.is_on_floor() and absf(player.global_position.y-Inn.ROOM.y)<.15,"interior has a real walkable collision floor")
	var items: Array = View.build(player,"旅馆与战斗测试").items
	var coins: Array = items.filter(func(v: Dictionary) -> bool: return v.id=="coin")
	check(coins.size()==1 and coins[0].count=="35" and coins[0].type=="其他","inventory copper item uses canonical wallet")
	var body: Node = game.combat_world._encounter_nodes.get(SOLDIER)
	check(is_instance_valid(body),"authored soldier exists before defeat")
	if is_instance_valid(body):
		body.ai_enabled=false
		body.combat.receive_damage({"formula":{"base":1000000},"can_crit":false,"damage_type":"PHYSICAL"},player,Vector3.FORWARD)
	check(game.encounters.record(SOLDIER).phase=="cooldown","real defeat waits for rest")
	game.combat_world._tick_encounters(3600)
	var active_ids: Array[String] = [SOLDIER]
	var idle: Dictionary = game.encounters.plan_tick(86400,active_ids)
	check(idle.ok and idle.spawn_ids.is_empty() and game.encounters.record(SOLDIER).phase=="cooldown","one day of timers cannot respawn enemies")
	ready_at(rest.places.bed.global_position+Vector3(1.6,.07,0))
	player.resources.change("HP",player.resources.max_value("HP")*.1-player.resources.current("HP"))
	player.resources.change("Energy",player.resources.max_value("Energy")*.1-player.resources.current("Energy"))
	check(rest.execute(rest.places.bed,"rest_short"),"bed short rest succeeds")
	check(is_equal_approx(player.resources.current("HP"),player.resources.max_value("HP")*.6) and is_equal_approx(player.resources.current("Energy"),player.resources.max_value("Energy")*.6),"short rest adds half maximum HP and energy")
	check(rest.clock().minute==1080,"day advances to dusk")
	check(game.encounters.record(SOLDIER).generation==2 and game.encounters.record(SOLDIER).phase=="alive","short rest alone creates next encounter life")
	check(game.checkpoint.distance_to(player.global_position)<.01,"bed short rest records checkpoint")
	var saved: Dictionary = repo.save(0,"旅馆与战斗测试",player,game)
	check(saved.ok,"save interior, date, wallet, checkpoint and encounter generation")
	var broken: Dictionary=saved.snapshot.duplicate(true)
	broken.world_state.objects["rest.clock"].minute=1440
	check(not repo.restore(broken,player,game).ok and rest.inside() and game.economy.balance()==35,"invalid clock rejected before mutating room or wallet")
	await ticks(110)
	check(rest.execute(rest.places.bed,"rest_short") and rest.clock().minute==1320,"dusk short rest advances to night")
	await ticks(110)
	var day: int = rest.clock().day
	check(rest.execute(rest.places.bed,"rest_long"),"long rest succeeds")
	check(rest.clock().day==day+1 and rest.clock().minute==480,"long rest advances to next morning")
	check(player.resources.current("HP")==player.resources.max_value("HP") and player.resources.current("Energy")==player.resources.max_value("Energy"),"long rest restores all resources")
	check(game.encounters.record(SOLDIER).generation==2,"long rest does not cause an extra monster refresh")
	await ticks(110)
	check(rest.actions(rest.places.bed)[0].id=="room_rent","room lease expires after next-day long rest")
	check(repo.restore(saved.snapshot,player,game).ok,"saved indoor adventure restores through real repository")
	check(rest.inside() and rest.places.room.visible and rest.clock().minute==1080 and game.economy.balance()==35,"restore preserves room, clock and paid wallet")
	ready_at(rest.places.exit.global_position+Vector3(0,.04,-.8))
	check(rest.execute(rest.places.exit,"room_exit") and not rest.inside(),"room exit returns to village")
	var tree: Node = rest.places.trees[0]
	ready_at(tree.global_position+Vector3(1.0,.08,0))
	for enemy in game.combat_world.enemies: enemy.global_position+=Vector3(50,0,0)
	check(rest.execute(tree,"rest_short") and player.get_meta("rest_pose","")=="tree","large tree offers an actual resting pose and short rest")
	await ticks(110)
	check(player.get_meta("rest_pose","")=="" and not player.get_meta("traversal_locked",false),"rest animation releases player control")
	game.world_state.set_object("rest.clock",{"version":1,"day":3,"minute":1380})
	rest.refresh()
	check(rest.execute(tree,"rest_short") and rest.clock().day==4 and rest.clock().minute==480,"late-night short rest reaches the next morning")
	await ticks(110)
	game.world_state.set_object("rest.clock",{"version":1,"day":4,"minute":60})
	rest.refresh()
	check(rest.execute(tree,"rest_short") and rest.clock().day==4 and rest.clock().minute==480,"after-midnight short rest reaches this morning instead of dusk or an extra day")
	await ticks(110)
	await combat_checks()
	print("REST_TARGET ",JSON.stringify({"checks":checks,"failures":failures,"balance":damage_report}))
	game.queue_free()
	await ticks(4)
	quit(0 if failures.is_empty() else 1)

func combat_checks() -> void:
	ready_at(game.GARDEN_ORIGIN+Vector3(1.6,2.3,4.8))
	var arena: Node = game.combat_world
	var origin: Vector3 = player.global_position
	var enemy: Node = arena.spawn_enemy("soldier",origin+Vector3(0,0,-5))
	enemy.ai_enabled=false
	await ticks(6)
	enemy.set_physics_process(false)
	arena.locked_target=enemy
	game.aim_override=enemy.global_position
	var found: Node = arena.hover_at_feet(player,arena.world_to_screen(enemy.global_position)+Vector2(8,4))
	check(found==enemy,"mouse near enemy feet selects that enemy")
	var serial: int = player.combat.serial
	check(player.attack_assist.request_primary() and player.attack_assist.approaching(),"out-of-reach primary click queues approach")
	await ticks(100)
	check(player.combat.serial==serial+1 and not player.attack_assist.approaching(),"approach walks into range and executes one primary attack")
	await ticks(70)
	ready_at(origin)
	arena.locked_target=enemy
	player.attack_assist.request_primary()
	player.attack_assist.direction(.016,Vector3.LEFT)
	check(not player.attack_assist.approaching(),"manual movement cancels automatic approach")
	ready_at(origin)
	var left_key := InputEventKey.new()
	left_key.physical_keycode=KEY_A
	check(InputMap.action_has_event("move_left",left_key) and not player.attack_assist.indicator.visible,"A retains left movement and no attack-range preview")
	check(player.combat.begin_charge("PRIMARY"),"weapon charge starts")
	player.combat.charge_time=player.input_router.hold_threshold+.02
	player.attack_assist._physics_process(.016)
	check(player.attack_assist.indicator.visible,"releasable charged attack shows blue range")
	player.input_router.cancel()
	player.attack_assist._physics_process(.016)
	check(not player.attack_assist.indicator.visible,"charge cancellation hides range without A binding")
	ready_at(origin)
	check(player.progression.choose_career("berserker"),"advance to berserker")
	check(player.progression.learn_skill("berserker_quake"),"learn earthquake")
	player.loadout.current_set=1
	var quake: Dictionary = arena.database.skills.berserker_quake.duplicate(true)
	check(player.combat.action_failure(quake).is_empty() and player.combat.use_action(quake),"earthquake works with career's spear group")
	await ticks(80)
	ready_at(origin)
	player.loadout.current_set=0
	check(player.progression.learn_skill("barbarian_leap"),"learn jump slash")
	var leap: Dictionary = arena.database.skills.barbarian_leap.duplicate(true)
	enemy.global_position=origin+Vector3(0,0,-4.4)
	enemy.combat.reset()
	enemy.set_physics_process(false)
	arena.locked_target=enemy
	game.aim_override=enemy.global_position
	var bystander: Node = arena.spawn_enemy("soldier",enemy.global_position+Vector3(1.2,0,0))
	bystander.ai_enabled=false
	bystander.set_physics_process(false)
	var hp: float = bystander.resources.current("HP")
	var wall_root := Node3D.new()
	game.world.add_child(wall_root)
	preload("res://scripts/art.gd").solid_box(wall_root,origin+Vector3(0,2,-2),Vector3(3,4,.4),Color.GRAY)
	await ticks(2)
	var energy: float=player.resources.current("Energy")
	check(not player.combat.use_action(leap) and player.resources.current("Energy")==energy,"obstructed leap rejected before spending energy")
	wall_root.queue_free()
	await ticks(2)
	check(player.combat.use_action(leap),"single target jump slash validates and starts")
	var peak := origin.y
	var biggest_step := 0.0
	var last: Vector3 = player.global_position
	for i in range(64):
		await ticks(1)
		peak=maxf(peak,player.global_position.y)
		biggest_step=maxf(biggest_step,last.distance_to(player.global_position))
		last=player.global_position
	check(peak>origin.y+.7 and biggest_step<.65,"jump slash follows visible arc with bounded swept movement")
	check(enemy.resources.current("HP")<enemy.resources.max_value("HP") and bystander.resources.current("HP")==hp,"jump slash damages only locked target")
	await ticks(35)
	var boss: Node = arena.spawn_enemy("ogre",origin+Vector3(15,0,0))
	check(boss.loadout.level==5 and boss.aggro_range>=24,"first-map boss level five with expanded chase radius")
	boss.ai_enabled=false
	player.combat.reset()
	var before: float = player.resources.current("HP")
	var hit: Dictionary = boss.action_for("PRIMARY_TAP",0).duplicate(true)
	hit.can_crit=false
	player.combat.receive_damage(hit,boss,Vector3.LEFT)
	damage_report={"hero_level":player.loadout.level,"hero_hp":player.resources.max_value("HP"),"boss_level":boss.loadout.level,"boss_primary_damage":before-player.resources.current("HP"),"fraction":(before-player.resources.current("HP"))/player.resources.max_value("HP")}
	check(damage_report.fraction<.12,"measured boss ordinary hit is below twelve percent of level-five HP")
