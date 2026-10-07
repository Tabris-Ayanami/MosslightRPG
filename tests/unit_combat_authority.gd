extends SceneTree
## Controller contracts: identity, current controller and granted abilities vary
## independently. Mouse/key checks go through the live InputMap and router.
var arena: Node
var player: Node
var checks:=0
var failures: Array[String]=[]
var started: Array[Dictionary]=[]
func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func key(code: Key,pressed: bool) -> void:
	var event:=InputEventKey.new()
	event.physical_keycode=code
	event.pressed=pressed
	Input.parse_input_event(event)
func mouse(pressed: bool) -> void:
	var event:=InputEventMouseButton.new()
	event.button_index=MOUSE_BUTTON_LEFT
	event.position=Vector2(640,300)
	event.global_position=event.position
	event.pressed=pressed
	Input.parse_input_event(event)
func reset_inputs() -> void:
	mouse(false)
	for code in [KEY_Q,KEY_E,KEY_R,KEY_CTRL]: key(code,false)
	for action in InputMap.get_actions(): Input.action_release(action)
func spawn(id: String,position: Vector3) -> Node:
	var actor: Node=arena.spawn_enemy(id,position)
	actor.ai_enabled=false
	return actor
func wait_phase(actor: Node,phase: String) -> bool:
	for i in range(100):
		if actor.combat.runner.busy() and actor.combat.runner.action_phase==phase: return true
		await ticks(1)
	return false
func cast_fixture() -> Dictionary:
	return {"id":"innate_authority_spell","name":"天然回归法术","is_skill":true,"animation_family":"STAFF_ORB","presentation_type":"CASTER_ACTION","targeting":"POINT","range":10.0,"radius":1.5,"startup":.06,"active":.08,"recovery":.1,"cooldown":.5,"costs":{"Energy":20},"formula":{"base":50},"damage_type":"FIRE","can_crit":false,"conditions":[],"effects":[]}
func mechanism(kind: String,extra: Dictionary={}) -> bool:
	var effect: Dictionary={"type":kind,"target":"self","duration":.2}
	effect.merge(extra,true)
	return player.combat.use_action({"id":"mechanism_"+kind,"presentation_type":"VFX_ONLY","targeting":"SELF","startup":.02,"active":.06,"recovery":.1,"costs":{},"effects":[effect]})
func run() -> void:
	arena=load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	arena.player_visual_script=preload("res://combat/animation_controller.gd")
	root.add_child(arena)
	await ticks(3)
	player=arena.player
	arena.sound.muted=true
	arena.ui.toggle_menu(false)
	arena.input_blocked=false
	arena.pointer_blocked=false
	for enemy in arena.enemies:
		enemy.ai_enabled=false
		enemy.global_position=Vector3(18,.1,18)
	player.loadout.select_career("warrior")
	player.combat.reset()
	player.global_position=Vector3(0,.1,8)
	var natural: Node=spawn("fire_elemental",Vector3(0,.1,6))
	var victim: Node=spawn("soldier",Vector3(0,.1,2))
	check(not natural.is_player and natural.loadout.career_ids.is_empty(),"natural body retains non-player identity without a career")
	var natural_level: int=natural.loadout.level
	natural.loadout.level=0
	check(natural.combat.action_failure(natural.action_for("PRIMARY_TAP")).is_empty(),"zero-level AI has permission for its own natural attack")
	natural.loadout.level=natural_level
	arena.input_blocked=true
	check(natural.combat.action_failure(natural.action_for("PRIMARY_TAP")).is_empty(),"human interface blocking does not disable AI abilities")
	check(not player.combat.action_failure(player.action_for("PRIMARY_TAP")).is_empty(),"the same interface block stops the currently human body")
	arena.input_blocked=false
	var ctx: Dictionary=natural.combat.context(player)
	check(ctx.race_id=="elemental" and ctx.target_race=="human" and ctx.definition_id==natural.definition_id,"contexts expose actual source and target race and definition")
	check(CombatConditions.check({"type":"race","value":"elemental"},ctx),"race condition reads unit race")
	check(CombatConditions.check({"type":"faction","value":natural.faction_id},ctx),"faction condition reads unit faction")
	check(CombatConditions.check({"type":"target_race","value":["human","beast"],"op":"in"},ctx),"target race supports membership conditions")
	check(not CombatConditions.check({"type":"target_faction","value":"other","op":"!="},natural.combat.context()),"missing target cannot satisfy a negative target faction condition")
	# Ordinary career abilities never inherit the former enemy permission bypass.
	var trained: Node=spawn("soldier",Vector3(8,.1,8))
	check(trained.progression.choose_career("warrior"),"normal-mode AI chooses a real career through shared progression")
	check(trained.progression.learn_skill("warrior_whirlwind"),"normal-mode AI explicitly learns its career skill through shared progression")
	check(trained.loadout.assign_skill(0,0,"warrior_whirlwind"),"normal-mode AI assigns its learned career skill to Q")
	trained.combat.reset()
	trained.resources.configure("Energy",60)
	var learned: Dictionary=arena.database.skills.warrior_whirlwind.duplicate(true)
	check(trained.combat.action_failure(learned).is_empty(),"AI may use an actually learned equipped career skill")
	trained.loadout.unlocked_skills.erase("warrior_whirlwind")
	check(not trained.combat.use_action(learned) and trained.resources.current("Energy")==60,"AI cannot use an unlearned career skill or pay for rejected use")
	trained.loadout.unlocked_skills.append("warrior_whirlwind")
	trained.stats.add_modifier("authority_requirement",{"STR":-100})
	check(not trained.combat.action_failure(learned).is_empty(),"AI equipment requirements are rechecked after its attributes change")
	trained.stats.remove_modifier("authority_requirement")
	check(arena.control.possess(natural,30.0),"take control of the natural body through the shared control service")
	check(natural.is_human_controlled() and not natural.is_player,"human control is independent from protagonist identity")
	var energy_before: float=player.resources.current("Energy")
	check(not player.combat.request_skill(0) and player.resources.current("Energy")==energy_before,"a departed body in none control mode cannot cast from a stale interface")
	arena.aim_override=victim.global_position
	arena.aim_point=victim.global_position
	arena.locked_target=victim
	natural.combat.runner.action_started.connect(func(action: Dictionary): started.append(action.duplicate(true)))
	var hp: float=victim.resources.current("HP")
	mouse(true)
	await ticks(2)
	mouse(false)
	await ticks(110)
	check(started.size()==1 and started[0].id=="fire_elemental_attack","physical mouse tap dispatches the possessed body's natural attack exactly once")
	check(started.size()==1 and started[0].animation_family==natural.action_for("PRIMARY_TAP").animation_family,"natural action retains its own animation family")
	check(victim.resources.current("HP")<hp,"possessed natural attack creates a real projectile and damages its hostile target")
	check(victim.last_damage_source!=null and victim.last_damage_source.get_ref()==natural,"actual HP damage attributes the hit to its source body")
	check(not natural.combat.begin_charge("PRIMARY"),"natural tap-only body cannot borrow an unrelated equipment charge")
	# A natural Q is not present in the global career-skill catalog, but can buffer.
	natural.innate_skills.assign([cast_fixture()])
	natural.resources.configure("Energy",40)
	natural.combat.reset()
	started.clear()
	check(natural.combat.weapon_action("PRIMARY_TAP"),"natural attack opens an action for the queue fixture")
	check(await wait_phase(natural,"ACTIVE"),"natural attack reaches its real active phase")
	key(KEY_Q,true)
	await ticks(1)
	key(KEY_Q,false)
	await ticks(1) # Quick casting confirms on the buffered release event.
	check(natural.combat.queued_command.get("action_id","")=="innate_authority_spell","physical Q queues the actual natural skill definition")
	await ticks(70)
	var casts:=0
	for action in started:
		if action.id=="innate_authority_spell": casts+=1
	check(casts==1 and natural.resources.current("Energy")==20,"natural queued skill starts once and pays its resource once")
	natural.combat.reset()
	started.clear()
	natural.combat.weapon_action("PRIMARY_TAP")
	await wait_phase(natural,"ACTIVE")
	key(KEY_Q,true)
	await ticks(1)
	key(KEY_Q,false)
	await ticks(1) # Quick casting confirms on the buffered release event.
	natural.innate_skills.clear()
	await ticks(70)
	check(natural.resources.current("Energy")==40 and started.size()==1,"removing a natural ability before queue drain rejects stale intent without payment")
	arena.control.release()
	var guard: Node=spawn("heavy_guard",Vector3(0,.1,6))
	check(arena.control.possess(guard,30.0),"take control of a body with a natural shield")
	key(KEY_CTRL,true)
	await ticks(2)
	check(guard.combat.state=="GUARD" and guard.combat.defense.shield().get("id","")=="wooden_shield","physical Ctrl uses the possessed body's definition shield")
	key(KEY_CTRL,false)
	await ticks(2)
	check(guard.combat.state=="NORMAL","releasing Ctrl leaves natural shield guard normally")
	check(guard.combat.request_shield(),"natural shield can execute raise without a career equipment proficiency")
	guard.combat.reset()
	arena.control.release()
	reset_inputs()
	player.combat.reset()
	arena.locked_target=natural
	check(mechanism("possess"),"data-only possession action enters the common runner")
	await ticks(4)
	check(arena.control.controlled_actor()==natural and not player.combat.runner.busy(),"possession effect transfers control and cancels the old action before dispatch")
	await ticks(15)
	check(arena.control.controlled_actor()==player and player.is_human_controlled(),"possession effect duration returns control to the original body")
	player.combat.reset()
	check(mechanism("berserk"),"data-only berserk action enters the common runner")
	await ticks(4)
	check(player.control_mode=="ai","berserk effect delegates to the shared AI controller")
	await ticks(15)
	check(player.is_human_controlled(),"berserk effect expires back to human input")
	player.combat.reset()
	check(mechanism("transform",{"unit_id":"fire_elemental"}),"data-only transformation action enters the common runner")
	await ticks(4)
	check(player.form.active and player.definition_id=="fire_elemental" and not player.combat.runner.busy(),"transformation effect applies the real definition and cancels its old action")
	await ticks(15)
	check(not player.form.active and player.definition_id=="hero","transformation effect expires back to the original definition")
	player.combat.apply_effect({"type":"transform","unit_id":"missing_unit","duration":1.0})
	check(not player.form.active and not player.combat.last_condition_failed.is_empty(),"an invalid transformation fails safely")
	for enemy in arena.enemies:
		enemy.global_position=Vector3(18,.1,18)
	var possessed_hit: Node=spawn("soldier",player.global_position+Vector3.FORWARD*1.6)
	arena.locked_target=possessed_hit
	arena.aim_override=possessed_hit.global_position
	arena.aim_point=possessed_hit.global_position
	var innate_hit: Dictionary=arena.database.enemies.soldier.action.duplicate(true)
	innate_hit.merge({"id":"natural_possession_hit","startup":.05,"active":.1,"recovery":.2,"formula":{"base":1},"poise_damage":0,"effects":[{"type":"possess","target":"target","duration":.3}]},true)
	player.innate_actions["PRIMARY_TAP"]=innate_hit
	player.combat.reset()
	var prior_hp: float=possessed_hit.resources.current("HP")
	mouse(true)
	await ticks(2)
	mouse(false)
	await ticks(12)
	check(possessed_hit.resources.current("HP")<prior_hp and arena.control.controlled_actor()==possessed_hit,"real natural mouse attack applies on-hit possession to the struck body")
	await ticks(25)
	check(arena.control.controlled_actor()==player,"on-hit possession returns input after its lease")
	player.innate_actions.clear()
	player.combat.reset()
	var wild: Node=spawn("fire_elemental",player.global_position+Vector3.RIGHT*2)
	prior_hp=player.resources.current("HP")
	wild.combat.hit_target(player,{"formula":{"base":1},"can_crit":false,"poise_damage":0,"effects":[{"type":"possess","target":"target","duration":1}]},Vector3.LEFT)
	check(player.resources.current("HP")<prior_hp and arena.control.controlled_actor()==player and not wild.combat.last_condition_failed.is_empty(),"a hostile AI hit cannot steal local input through a possession effect")
	print("UNIT_COMBAT_AUTHORITY_RESULT %d/%d passed"%[checks-failures.size(),checks])
	arena.queue_free()
	await ticks(3)
	quit(0 if failures.is_empty() else 1)
