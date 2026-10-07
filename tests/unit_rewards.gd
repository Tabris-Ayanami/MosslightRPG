extends SceneTree
## Live main-world death callbacks, faction ownership and per-life rewards.
var game: Node
var world: Node
var player: Node
var checks:=0
var failures: Array[String]=[]
var rewards: Array[String]=[]
const LETHAL := {"id":"reward_hit","formula":{"base":100000},"can_crit":false,"damage_type":"PHYSICAL","poise_damage":0,"effects":[]}
func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func spawn(id: String,offset: Vector3) -> Node:
	var body: Node=world.spawn_enemy(id,player.global_position+offset)
	body.ai_enabled=false
	body.set_physics_process(false)
	return body
func xp_total() -> int:
	var total: int=player.progression.experience
	for level in range(1,player.loadout.level):
		total+=int(world.database.progression.rules.xp_to_next.get(str(level),0))
	return total
func events() -> int: return game.world_state.get_event_count("enemy_defeated")
func receipt() -> Dictionary:
	return {"xp":xp_total(),"items":player.inventory.stacks.duplicate(true),"events":events(),"kills":player.progression.enemy_kills.duplicate(true),"rewards":rewards.size()}
func assert_same(before: Dictionary,label: String) -> void:
	check(receipt()==before,label)
func kill(source: Node,victim: Node) -> Dictionary:
	return source.combat.hit_target(victim,LETHAL,Vector3.FORWARD)
func repeat_death(victim: Node) -> void:
	world._enemy_defeated(victim)
	victim.combat.died.emit()
	world._enemy_defeated(victim)
func run() -> void:
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(20)
	player=game.player
	world=game.combat_world
	world.encounters_started=true
	game.sound.muted=true
	for enemy in world.enemies: enemy.set_physics_process(false)
	check(player.progression.choose_career("warrior"),"reward fixture chooses a real starting career")
	check(game.quests.accept("village_patrol"),"main game's soldier quest observes the live world event stream")
	player.progression.reward_received.connect(func(id: String,_reward: Dictionary): rewards.append(id))
	var attacker: Node=spawn("fire_elemental",Vector3(2,0,0))
	var friendly_body: Node=spawn("soldier",Vector3(0,0,-2))
	check(world.control.possess(friendly_body,30),"possession changes a non-player body to the hero faction")
	var before:=receipt()
	var result: Dictionary=kill(attacker,friendly_body)
	check(result.get("final",0)>0 and friendly_body.combat.state=="DEAD","a hostile source really kills the friendly possessed body")
	assert_same(before,"friendly possessed death grants no XP, loot, kill count or quest event")
	check(game.quests.status("village_patrol")=="active","friendly soldier death cannot complete the actual soldier quest")
	await ticks(2)
	check(world.control.controlled_actor()==player,"possessed death returns control to the protagonist")
	repeat_death(friendly_body)
	assert_same(before,"replaying a resolved friendly death remains reward-free")
	var host: Node=spawn("fire_elemental",Vector3(2,0,-1))
	var target: Node=spawn("soldier",Vector3(3,0,-1))
	check(world.control.possess(host,30),"second possession supplies a hero-faction attacking body")
	before=receipt()
	var potion_count: int=player.inventory.count("healing_potion")
	result=kill(host,target)
	check(result.get("final",0)>0 and target.combat.state=="DEAD","possessed natural body kills an actual hostile unit")
	check(target.last_damage_source!=null and target.last_damage_source.get_ref()==host,"lethal hit has the actual body source before death callbacks")
	check(xp_total()==before.xp+40 and player.inventory.count("healing_potion")==potion_count+1,"possessed kill pays XP and loot to protagonist progression")
	check(host.progression.experience==0 and host.inventory.item_ids().is_empty(),"possessed body does not receive a second progression reward")
	check(events()==before.events+1 and game.quests.status("village_patrol")=="ready","possessed kill advances the actual main-game quest")
	before=receipt()
	var respawn_count: int=world.respawns.size()
	repeat_death(target)
	kill(host,target)
	assert_same(before,"repeated callbacks and hits cannot reward one dead life twice")
	check(world.respawns.size()==respawn_count,"repeat death callback cannot schedule duplicate respawns")
	world.control.release()
	check(world.control.autopilot(player,30),"protagonist enters the real shared autopilot controller")
	player.ai_enabled=false
	var ai_target: Node=spawn("heavy_guard",Vector3(3,0,-2))
	before=receipt()
	result=kill(player,ai_target)
	check(player.control_mode=="ai" and ai_target.combat.state=="DEAD","hero AI body can deal a real lethal hit")
	check(xp_total()==before.xp+70 and events()==before.events+1,"hero AI kill is credited to protagonist XP and world events")
	before=receipt()
	repeat_death(ai_target)
	assert_same(before,"one AI kill has exactly one progression reward")
	var new_life: Node=spawn("heavy_guard",Vector3(3,0,-3))
	before=receipt()
	kill(player,new_life)
	check(xp_total()==before.xp+70 and events()==before.events+1,"a new spawned life of the same enemy is independently rewardable")
	check(not player.progression.claimed_rewards.has(str(new_life.get_instance_id())),"process-local instance IDs are not persisted as reward receipts")
	# Direct APIs must obey the same relation filter as area/projectile targeting.
	var ally: Node=spawn("soldier",Vector3(-2,0,0))
	ally.faction_id=player.faction_id
	ally.refresh_collision_layer()
	var ally_hp: float=ally.resources.current("HP")
	before=receipt()
	check(kill(player,ally).get("blocked",false) and ally.resources.current("HP")==ally_hp,"direct hit_target cannot bypass same-faction protection")
	check(ally.combat.receive_damage(LETHAL,player,Vector3.FORWARD).get("blocked",false) and ally.resources.current("HP")==ally_hp,"direct receive_damage cannot bypass same-faction protection")
	check(ally.hurtbox.receive(LETHAL,player,Vector3.FORWARD).get("blocked",false) and ally.last_damage_source==null,"direct hurtbox receive cannot apply friendly damage or attribution")
	assert_same(before,"rejected friendly damage produces no rewards or quest progress")
	ally.faction_id="villagers"
	check(kill(player,ally).get("blocked",false) and ally.resources.current("HP")==ally_hp,"different neutral factions are protected until explicitly hostile")
	var hostile_peer: Node=spawn("soldier",Vector3(-3,0,0))
	var peer_hp: float=hostile_peer.resources.current("HP")
	check(kill(attacker,hostile_peer).get("blocked",false) and hostile_peer.resources.current("HP")==peer_hp,"native enemies cannot directly damage their own faction")
	before=receipt()
	result=ally.combat.receive_damage(LETHAL,null,Vector3.ZERO)
	check(result.get("final",0)>0 and ally.combat.state=="DEAD","source-free environmental damage remains available")
	assert_same(before,"unattributed environmental death yields no hero progression reward")
	world.control.cancel_all()
	print("UNIT_REWARDS_RESULT %d/%d passed"%[checks-failures.size(),checks])
	game.queue_free()
	await ticks(3)
	quit(0 if failures.is_empty() else 1)
