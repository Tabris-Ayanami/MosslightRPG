extends "res://tests/frontend_rpg.gd"
## Diagnostic controller, not a human playtest. Every world leg uses ordinary
## movement InputMap actions. No teleport, stat edit, item grant, quest shortcut,
## direct damage, invulnerability, enemy freeze, or time-skipped cooldown.
## Headless manual integration diagnostic: 240 s wall watchdog; 60 Hz simulated
## steps accelerated 4x. Death on return uses the game's normal respawn, counted
## separately. A pass demonstrates this policy/path, not human balance or no-death.
const Repo=preload("res://rpg/save_repository.gd")
const SOLDIER="encounter.forest.soldier_01"
const HEAVY="encounter.forest.heavy_guard_01"
const OGRE="encounter.forest.ogre_01"
const PROFILES := {
	"warrior":{"name":"战士","skill":"warrior_thrust","stop_distance":1.45},
	"rogue":{"name":"游荡者","skill":"rogue_shadow_strike","stop_distance":1.45},
	"barbarian":{"name":"狂蛮","skill":"barbarian_fan_slash","stop_distance":2.6},
	"mage":{"name":"法师","skill":"mage_fireball","stop_distance":6.0}
}
var career := "warrior"
var seed_value := 930
var skill_id := "warrior_thrust"
var adventure_name := "完整旅途战士"
var finished := false
var started_wall := 0
var watchdog: SceneTreeTimer
var phase_records: Array[Dictionary]=[]
var combat_records: Array[Dictionary]=[]
var active_combat: Dictionary={}
var ledger_events: Array[Dictionary]=[]
var reward_events: Array[Dictionary]=[]
var action_events: Array[Dictionary]=[]
var spent_events: Array[Dictionary]=[]
var resource_changes: Dictionary={}
var resource_seen: Dictionary={}
var spent_totals: Dictionary={}
var paid_skill_totals: Dictionary={}
var item_uses: Dictionary={}
var request_totals: Dictionary={}
var last_ledger: Dictionary={}
var previous_ledger: Dictionary={}
var prepared: Dictionary={}
var pending_failure: Dictionary={}
var last_combat_state := ""
var resource_context := "simulation"
var dodge_starts := 0
var perfect_dodges := 0
var dodge_refunds := 0.0
var dodge_intent: Dictionary={}
var dodge_intent_events: Array[Dictionary]=[]
var offmesh_recoveries: Array[Dictionary]=[]
var last_land_position := Vector3.INF
var next_land_sample := 0.0
var game: Node
var repo: RefCounted
var isolated := ""
var output := ""
var stage := "setup"
var trace: Array[Dictionary]=[]
var simulated := 0.0
var paid_dodges := 0
var dodge_stamina := 0.0
var potion_uses := 0
var skill_starts := 0
var weapon_starts := 0
var hits_taken := 0
var damage_taken := 0.0
var deaths := 0
var respawns_seen := 0
var respawn_relocation := 0.0
var next_skill := 0.0
var observed_attacks: Dictionary={}
var handled_attacks: Dictionary={}
var victories: Array[String]=[]
var travel_distance := 0.0
var last_position := Vector3.INF
var sampled_dead := false

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--career="): career=argument.trim_prefix("--career=")
		elif argument.begins_with("--evidence="): output=argument.trim_prefix("--evidence=")
		elif argument.begins_with("--seed="):
			var value := argument.trim_prefix("--seed=")
			if not value.is_valid_int() or int(value)<0 or int(value)>2147483647:
				printerr("--seed must be an integer from 0 to 2147483647"); quit(2); return
			seed_value=int(value)
		elif argument=="--supply-stop":
			printerr("--supply-stop is reserved; the real shop/waystone route is not implemented in this diagnostic yet"); quit(2); return
		else:
			printerr("Unknown chapter diagnostic argument: "+argument); quit(2); return
	if not PROFILES.has(career): printerr("Unknown --career: "+career); quit(2); return
	if not output.is_empty() and not output.is_absolute_path(): printerr("--evidence must be an absolute directory"); quit(2); return
	if output.is_empty(): output=ProjectSettings.globalize_path("res://.work/chapter-playthrough/run-%s-%d-%d"%[career,OS.get_process_id(),Time.get_ticks_usec()])
	if FileAccess.file_exists(output.path_join("trace.json")) or FileAccess.file_exists(output.path_join("report.json")):
		printerr("Evidence already exists; choose a fresh directory"); quit(2); return
	skill_id=str(PROFILES[career].skill)
	adventure_name="完整旅途"+str(PROFILES[career].name)
	isolated=OS.get_temp_dir().path_join("mosslight-%s-chain-%d-%d"%[career,OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path=isolated.path_join("preferences.cfg")
	DirAccess.make_dir_recursive_absolute(output)
	started_wall=Time.get_ticks_msec()
	physics_frame.connect(sample_world_step)
	call_deferred("_run_at_display_size")

func ticks(count: int) -> void:
	for _i in range(count):
		await physics_frame
		# Book animations are process-driven while the adventure is paused. During
		# play use each physical step, matching the normal-combat controller policy.
		if paused: await process_frame

func sample_world_step() -> void:
	if not is_instance_valid(game) or not is_instance_valid(actor) or game.paused or paused or not actor.is_physics_processing(): return
	simulated+=Engine.time_scale/Engine.physics_ticks_per_second
	if last_position.is_finite():
		var moved:=Vector2(actor.global_position.x-last_position.x,actor.global_position.z-last_position.z).length()
		if sampled_dead and actor.combat.state!="DEAD": respawn_relocation+=moved
		else: travel_distance+=moved
	last_position=actor.global_position
	sampled_dead=actor.combat.state=="DEAD"
	if actor.combat.state=="DODGE" and last_combat_state!="DODGE":
		dodge_starts+=1
		var paid: float=actor.combat.dodge_paid
		if paid>0:
			paid_dodges+=1
			dodge_stamina+=paid
		var intent_record: Dictionary={"seconds":simulated,"event":"actual_start","paid":paid,"actual_direction":str(actor.combat.dodge_direction),"requested":dodge_intent.duplicate(true)}
		if not dodge_intent.is_empty(): intent_record["direction_alignment"]=actor.combat.dodge_direction.dot(dodge_intent.direction)
		dodge_intent_events.append(intent_record)
		note("dodge_started",{"paid":paid,"dash":actor.combat.dodge_is_dash,"direction":str(actor.combat.dodge_direction),"request_evidence":intent_record})
		dodge_intent.clear()
	last_combat_state=actor.combat.state
	if simulated>=next_land_sample:
		next_land_sample=simulated+.10
		if on_land_navigation(): last_land_position=actor.global_position
	if not active_combat.is_empty():
		active_combat.minimum_hp=minf(float(active_combat.minimum_hp),actor.resources.current("HP"))

func tap(code: Key) -> void:
	# Keyboard dispatch runs in the event/process loop, not at every accelerated
	# physics step. Wait for both edges instead of testing before F is delivered.
	key(code,true)
	await process_frame
	key(code,false)
	await process_frame
	await ticks(2)

func state() -> Dictionary:
	var record: Dictionary={"career":career,"stage":stage,"seconds":snappedf(simulated,.01),"travel_m":snappedf(travel_distance,.01),"respawns":respawns_seen,"respawn_relocation_m":snappedf(respawn_relocation,.01)}
	if not is_instance_valid(actor): return record
	record.merge({"position":str(game.reference_map.to_local(actor.global_position)),"velocity":str(actor.velocity),"intent":str(actor.move_direction),"combat":actor.combat.state,"hp":actor.resources.current("HP"),"stamina":actor.resources.current("Stamina"),"energy":actor.resources.current("Energy"),"level":actor.loadout.level,"xp":actor.progression.experience,"potions":actor.inventory.count("healing_potion"),"deaths":deaths,"chapter":game.chapter.phase(),"patrol":game.quests.status("village_patrol"),"forest":game.quests.status("forest_investigation"),"paid_dodges":paid_dodges,"dodge_stamina":dodge_stamina,"potions_used":potion_uses,"hits_taken":hits_taken,"damage_taken":damage_taken,"skill_starts":skill_starts,"weapon_starts":weapon_starts})
	record["resources"]=resource_snapshot()
	record["wallet"]=game.world_state.get_object("economy.wallet").duplicate(true)
	record["item_uses"]=item_uses.duplicate(true)
	return record

func note(kind: String,details: Dictionary={}) -> void:
	var record:=state()
	record["event"]=kind
	record.merge(details)
	trace.append(record)
	if kind in ["WATCHDOG","walk_dead","walk_stuck","walk_timeout","dialogue_not_open","unexpected_responses","dialogue_timeout","encounter_absent","combat_dead","combat_timeout","automatic_respawn_timeout","offmesh_recovery_failed"]: pending_failure=record.duplicate(true)
	print("CHAIN ",JSON.stringify(record))
	var file:=FileAccess.open(output.path_join("trace.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(trace,"  "))
	file.close()

func move_towards(direction: Vector3) -> void:
	for action in ["move_left","move_right","move_up","move_down"]: Input.action_release(action)
	if direction.length_squared()<.001: return
	var horizontal: float=direction.dot(game.camera_right())
	var vertical: float=direction.dot(game.camera_forward())
	Input.action_press("move_right" if horizontal>=0 else "move_left",absf(horizontal))
	Input.action_press("move_up" if vertical>=0 else "move_down",absf(vertical))

func local(point: Vector3) -> Vector3: return game.reference_map.to_global(point)

func on_land_navigation() -> bool:
	if not is_instance_valid(game) or not is_instance_valid(actor) or actor.swimming or actor.wading or not game.world_navigation.navigation_ready(): return false
	var closest: Vector3=NavigationServer3D.map_get_closest_point(game.world_navigation.region.get_navigation_map(),actor.global_position)
	return game.world_navigation._near(closest,actor.global_position)

func safe_dodge_direction(retreat: Vector3) -> Dictionary:
	# Coarse visible-ground check only. Keep the old reaction timing and real
	# dodge cost. If retreat would enter water or a wall, try either sidestep;
	# never invent a safe endpoint or alter the physical movement controller.
	var nav: Node=game.world_navigation
	if not on_land_navigation(): return {}
	for candidate: Vector3 in [retreat,retreat.rotated(Vector3.UP,PI/2),retreat.rotated(Vector3.UP,-PI/2)]:
		var valid:=true
		var end: Vector3=actor.global_position
		for reach: float in [1.0,2.0,3.0,4.6]:
			var at: Vector3=actor.global_position+candidate*reach
			var query:=PhysicsRayQueryParameters3D.create(at+Vector3.UP*5,at-Vector3.UP*8,1)
			var hit: Dictionary=actor.get_world_3d().direct_space_state.intersect_ray(query)
			if hit.is_empty() or hit.normal.dot(Vector3.UP)<cos(deg_to_rad(65.0)):
				valid=false
				break
			end=hit.position
			var water: float=game.water_surface_at(end)
			if (is_finite(water) and end.y<water+.08) or not nav.is_reachable(actor.global_position,end):
				valid=false
				break
		if valid: return {"direction":candidate,"land_endpoint":str(game.reference_map.to_local(end)),"choice":"retreat" if candidate.dot(retreat)>.99 else "sidestep"}
	return {}

func hold_queued_dodge() -> bool:
	if dodge_intent.is_empty(): return false
	if actor.combat.state=="DODGE": return false # sample_world_step owns actual-start/payment evidence.
	if actor.combat.queued_command.get("kind","")!="dodge_dash" or actor.combat.input_time>float(dodge_intent.expires):
		var record: Dictionary={"seconds":simulated,"event":"queue_ended_without_start","requested":dodge_intent.duplicate(true),"state":actor.combat.state,"controller_error":actor.combat.last_condition_failed}
		dodge_intent_events.append(record)
		note("dodge_queue_ended",record)
		dodge_intent.clear()
		return false
	move_towards(dodge_intent.direction)
	return true

func recover_land() -> bool:
	if on_land_navigation(): return true
	if not actor.combat.can_start(): return true # Let the real action/hitstun finish.
	var target:=last_land_position
	if not target.is_finite():
		target=NavigationServer3D.map_get_closest_point(game.world_navigation.region.get_navigation_map(),actor.global_position)
	var start:=state()
	var record: Dictionary={"start":start,"target":str(game.reference_map.to_local(target)),"method":"ordinary InputMap movement toward the last observed land position"}
	if offmesh_recoveries.size()>=6 or actor.global_position.distance_to(target)>15.0:
		record["reason"]="recovery limit or no nearby land breadcrumb"
		offmesh_recoveries.append(record)
		note("offmesh_recovery_failed",record)
		return false
	note("offmesh_recovery_start",record)
	for frame in range(480):
		if actor.combat.state=="DEAD": break
		if on_land_navigation():
			move_towards(Vector3.ZERO)
			record["ok"]=true
			record["end"]=state()
			record["frames"]=frame
			offmesh_recoveries.append(record)
			note("offmesh_recovery_complete",record)
			return true
		var direction: Vector3=target-actor.global_position
		direction.y=0
		move_towards(direction.normalized())
		await ticks(1)
	move_towards(Vector3.ZERO)
	record["ok"]=false
	record["end"]=state()
	record["reason"]="eight-second normal movement did not regain land navigation"
	offmesh_recoveries.append(record)
	note("offmesh_recovery_failed",record)
	return false

func resource_snapshot() -> Dictionary:
	var result: Dictionary={}
	if is_instance_valid(actor):
		for id: String in ["HP","Energy","Stamina"]: result[id]={"current":actor.resources.current(id),"max":actor.resources.max_value(id)}
	return result

func ledger_snapshot() -> Dictionary:
	if not is_instance_valid(actor): return {}
	return {"stacks":actor.inventory.stacks.duplicate(true),"xp":actor.progression.experience,"level":actor.loadout.level,"wallet":game.world_state.get_object("economy.wallet").duplicate(true),"quest_status":{"village_patrol":game.quests.status("village_patrol"),"forest_investigation":game.quests.status("forest_investigation")}}

func difference(after: Dictionary,before: Dictionary) -> Dictionary:
	var result: Dictionary={}
	var ids: Array=after.keys()
	for id: Variant in before:
		if id not in ids: ids.append(id)
	for id: Variant in ids:
		var delta: float=float(after.get(id,0))-float(before.get(id,0))
		if not is_zero_approx(delta): result[id]=delta
	return result

func set_stage(value: String) -> void:
	if not phase_records.is_empty():
		phase_records[-1]["end"]=state()
		phase_records[-1]["ledger_end"]=ledger_snapshot()
	stage=value
	phase_records.append({"stage":value,"start":state(),"ledger_start":ledger_snapshot()})

func record_request(kind: String,id: String,accepted: bool,reason: String) -> void:
	var key_name:=kind+":"+id
	if not request_totals.has(key_name): request_totals[key_name]={"attempts":0,"accepted":0,"rejected":0,"reasons":{}}
	var entry: Dictionary=request_totals[key_name]
	entry.attempts+=1
	entry["accepted" if accepted else "rejected"]+=1
	if not accepted:
		var label:=reason if not reason.is_empty() else "transition_or_queue_rejected"
		entry.reasons[label]=int(entry.reasons.get(label,0))+1
		entry["last_rejection"]={"seconds":simulated,"stage":stage,"reason":label,"state":actor.combat.state,"position":str(game.reference_map.to_local(actor.global_position)),"resources":resource_snapshot()}

func run() -> void:
	watchdog=create_timer(240,true,false,true)
	watchdog.timeout.connect(_watchdog)
	Engine.physics_ticks_per_second=240
	Engine.max_physics_steps_per_frame=32
	Engine.time_scale=4
	seed(seed_value)
	repo=Repo.new(isolated.path_join("adventures"))
	var created: Dictionary=repo.create(adventure_name,0)
	check(created.ok,"create real isolated adventure")
	if not created.ok: finish(false); return
	await enter_app(created.snapshot)
	set_stage("career-study-preparation")
	await click_label(str(PROFILES[career].name))
	await select_skill(skill_id)
	await click_label("研习此招式")
	await click_label("备战")
	await ticks(45)
	await click(app.ui.ink_buttons.get(0))
	# The ink chooser rebuilds native controls when its closing animation ends.
	# Wait for that visible transition before starting a click on the close tab.
	for _frame in range(90):
		if not app.ui.ink_open and app.ui.ink_progress<=0: break
		await process_frame
	await process_frame
	await close_book()
	check(app.ui.panel.is_empty() and not paused and not game.paused,"book close finishes after the preparation chooser withdraws")
	check(actor.loadout.career_ids==[career] and actor.loadout.sets[0].skills[0]==skill_id,"native book selects, studies, and prepares actual "+career+" skill")
	if not failures.is_empty(): finish(false); return
	var selected_skill: Dictionary=actor.skill_at(0)
	var primary: Dictionary=actor.action_for("PRIMARY_TAP")
	prepared={"shield":actor.shield_definition().get("id","none"),"weapon":actor.loadout.weapon().id,"skill":selected_skill.duplicate(true),"effective_skill_costs":actor.combat.costs_for(selected_skill),"skill_reach":actor.combat._action_reach(selected_skill),"primary":primary.duplicate(true),"primary_reach":actor.combat._action_reach(primary),"profile":PROFILES[career].duplicate(true),"ledger":ledger_snapshot(),"resources":resource_snapshot(),"unlimited":actor.resources.unlimited.duplicate(true)}
	check(not actor.resources.unlimited.get("Energy",false) and not actor.resources.unlimited.get("Stamina",false),"normal adventure uses finite Energy and Stamina")
	note("prepared",prepared)
	if not await village("first-visit"): finish(false); return
	if not await talk("我去看看。","patrol-accept"): finish(false); return
	check(game.quests.status("village_patrol")=="active","actual NPC dialogue accepts first quest")
	if not await forest_gate("patrol-departure"): finish(false); return
	if not await fight(SOLDIER): finish(false); return
	if not await village("patrol-return"): finish(false); return
	if not await talk("汇报巡路结果。","patrol-report"): finish(false); return
	if not await talk("我会清查林中的威胁。","investigation-accept"): finish(false); return
	check(game.quests.status("forest_investigation")=="active","separate real NPC conversation accepts investigation")
	if not await forest_gate("investigation-departure"): finish(false); return
	if not await fight(HEAVY): finish(false); return
	if not await fight(OGRE): finish(false); return
	if not await village("final-return"): finish(false); return
	if not await talk("汇报调查结果。","final-report"): finish(false); return
	check(game.chapter.is_complete(),"dialogue hand-in reaches chapter ending")
	set_stage("save-and-reopen")
	move_towards(Vector3.ZERO)
	await ticks(30)
	check(app.save_adventure(),"normal App save commits ending")
	var saved: Dictionary=repo.load_slot(0).snapshot
	var old_stacks: Dictionary=actor.inventory.stacks.duplicate(true)
	var old_xp: int=actor.progression.experience
	var old_level: int=actor.loadout.level
	var old_loadout: Dictionary=actor.loadout.export_state()
	var old_wallet: Dictionary=game.world_state.get_object("economy.wallet").duplicate(true)
	note("saved",{"content_set":saved.get("content_set",{})})
	app.selected_save=-1
	app.queue_free()
	await ticks(5)
	actor=null
	game=null
	last_position=Vector3.INF
	await enter_app(saved)
	check(game.chapter.is_complete() and actor.inventory.stacks==old_stacks and actor.progression.experience==old_xp and actor.loadout.level==old_level,"new App restores exact ending, earned inventory, XP and level")
	check(actor.loadout.sets[0].skills[0]==skill_id and game.quests.status("forest_investigation")=="rewarded","reopened App retains studied skill and final hand-in")
	check(actor.loadout.export_state()==old_loadout and game.world_state.get_object("economy.wallet")==old_wallet,"new App restores exact career, prepared loadout and wallet")
	note("reopened")
	finish(failures.is_empty())

func enter_app(snapshot: Dictionary) -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=repo
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app.selected_name=adventure_name
	app.selected_save=0
	app.pending_snapshot=snapshot.duplicate(true)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate.a=1
	game=app.game
	actor=game.player
	game.sound.muted=true
	connect_player()
	await settle()
	check(Preferences.settings_path.begins_with(isolated) and app.saves.directory.begins_with(isolated),"Prefs and Repo isolated before App entered tree")
	last_position=actor.global_position

func connect_player() -> void:
	resource_seen=resource_snapshot()
	last_ledger=ledger_snapshot()
	previous_ledger=last_ledger.duplicate(true)
	last_combat_state=actor.combat.state
	dodge_intent.clear()
	last_land_position=Vector3.INF
	next_land_sample=simulated
	actor.resources.resource_changed.connect(_resource_changed)
	actor.resources.resource_spent.connect(_resource_spent)
	actor.inventory.changed.connect(_ledger_changed)
	actor.progression.changed.connect(_ledger_changed)
	actor.inventory.item_used.connect(_item_used)
	actor.progression.reward_received.connect(_enemy_reward)
	actor.health.damage_received.connect(func(amount: float):
		if amount>0: hits_taken+=1; damage_taken+=amount)
	actor.combat.died.connect(func(): deaths+=1; note("player_died"))
	actor.combat.runner.action_started.connect(_action_started)
	actor.combat.perfect_dodge.connect(func(): perfect_dodges+=1; dodge_refunds+=actor.combat.dodge_paid)

func _resource_spent(id: String,amount: float) -> void:
	spent_totals[id]=float(spent_totals.get(id,0))+amount
	spent_events.append({"seconds":simulated,"stage":stage,"resource":id,"amount":amount,"context":resource_context,"state":actor.combat.state,"current_action":actor.combat.runner.current_action.get("id","")})

func _resource_changed(id: String,current: float,maximum: float) -> void:
	var previous: Dictionary=resource_seen.get(id,{"current":current,"max":maximum})
	if not resource_changes.has(id): resource_changes[id]={"increased":0.0,"decreased":0.0,"increased_by_context":{},"decreased_by_context":{},"max_changes":[],"same_max_changes":0}
	var entry: Dictionary=resource_changes[id]
	if not is_equal_approx(float(previous.max),maximum):
		entry.max_changes.append({"seconds":simulated,"stage":stage,"before":previous.duplicate(true),"after":{"current":current,"max":maximum}})
	else:
		var delta: float=current-float(previous.current)
		entry["increased" if delta>=0 else "decreased"]+=absf(delta)
		var contexts: Dictionary=entry["increased_by_context" if delta>=0 else "decreased_by_context"]
		contexts[resource_context]=float(contexts.get(resource_context,0))+absf(delta)
		entry.same_max_changes+=1
	resource_seen[id]={"current":current,"max":maximum}
	if id=="HP" and not active_combat.is_empty(): active_combat.minimum_hp=minf(float(active_combat.minimum_hp),current)

func _ledger_changed() -> void:
	var current:=ledger_snapshot()
	if current==last_ledger: return
	previous_ledger=last_ledger.duplicate(true)
	ledger_events.append({"seconds":simulated,"stage":stage,"context":resource_context,"before":previous_ledger,"after":current.duplicate(true),"stack_delta":difference(current.stacks,previous_ledger.get("stacks",{}))})
	last_ledger=current

func _item_used(id: String) -> void:
	item_uses[id]=int(item_uses.get(id,0))+1
	if id=="healing_potion": potion_uses+=1
	note("item_used",{"item":id,"ledger":ledger_snapshot()})

func _enemy_reward(enemy_id: String,reward: Dictionary) -> void:
	var record: Dictionary={"seconds":simulated,"stage":stage,"enemy_id":enemy_id,"reward":reward.duplicate(true),"before":previous_ledger.duplicate(true),"after":ledger_snapshot()}
	reward_events.append(record)
	note("enemy_reward",record)

func _action_started(action: Dictionary) -> void:
	var skill: bool=action.get("is_skill",false)
	if skill: skill_starts+=1
	else: weapon_starts+=1
	var paid: Dictionary=action.get("paid_costs",{}).duplicate(true)
	if skill:
		for resource: String in paid: paid_skill_totals[resource]=float(paid_skill_totals.get(resource,0))+float(paid[resource])
	action_events.append({"seconds":simulated,"stage":stage,"id":action.get("id",""),"is_skill":skill,"paid_costs":paid,"base_costs":action.get("costs",{}).duplicate(true),"effective_costs":actor.combat.costs_for(action),"resources_after":resource_snapshot(),"range":action.get("range",0),"cooldown":action.get("cooldown",0)})

func village(label: String,from_garden := false) -> bool:
	set_stage(label)
	var route: Array[Vector3]=[]
	if label!="first-visit" and not from_garden: route.assign([Vector3(25,2.3,1.7),Vector3(11,2.3,1.7),Vector3(.5,2.3,1.7)])
	route.append_array([Vector3(.5,2.3,-3.8),Vector3(.5,2.3,-8.5),Vector3(0,2.3,-12),Vector3(0,2.3,-26),Vector3(-2.8,2.3,-32.5)])
	for point in route:
		if not await walk(point,1.6 if point.z < -30 else 1.0):
			if actor.combat.state=="DEAD" and deaths<=2 and await recover_at_record_point():
				return await village(label+"-after-respawn",true)
			return false
	return true

func recover_at_record_point() -> bool:
	move_towards(Vector3.ZERO)
	var progress: Dictionary={"level":actor.loadout.level,"xp":actor.progression.experience,"stacks":actor.inventory.stacks.duplicate(true),"patrol":game.quests.status("village_patrol"),"forest":game.quests.status("forest_investigation")}
	note("await_automatic_respawn")
	for _frame in range(360):
		await ticks(1)
		if actor.combat.state!="DEAD":
			respawns_seen+=1
			var preserved: bool=actor.loadout.level==progress.level and actor.progression.experience==progress.xp and actor.inventory.stacks==progress.stacks and game.quests.status("village_patrol")==progress.patrol and game.quests.status("forest_investigation")==progress.forest
			check(preserved,"automatic death recovery preserves earned level, XP, items and quest progress")
			check(actor.global_position.distance_to(game.checkpoint)<.75 and actor.resources.current("HP")==actor.resources.max_value("HP"),"normal game timer respawns at checkpoint with its actual recovery rule")
			note("automatic_respawn",{"progress_preserved":preserved,"toast":game.toast_text})
			return preserved
	note("automatic_respawn_timeout",{"death_timer":game.death_time})
	return false

func forest_gate(label: String) -> bool:
	set_stage(label)
	for point in [Vector3(0,2.3,-26),Vector3(0,2.3,-12),Vector3(.5,2.3,-8.5),Vector3(.5,2.3,-3.8),Vector3(.5,2.3,1.7),Vector3(11,2.3,1.7),Vector3(25,2.3,1.7)]:
		if not await walk(point,1.0): return false
	return true

func nearby_hostile(radius := 7.0) -> Node:
	return game.combat_world.nearest_hostile(actor,radius)

func walk(point: Vector3,tolerance: float) -> bool:
	var target:=local(point)
	var start: Vector3=actor.global_position
	var best:=INF
	var stalled:=0
	note("walk_start",{"goal":str(point),"path_points":game.world_navigation.path_between(actor.global_position,target).size()})
	for frame in range(60*100):
		if actor.combat.state=="DEAD": note("walk_dead"); return false
		if not on_land_navigation() and actor.combat.can_start():
			if not await recover_land(): return false
			best=INF
			stalled=0
		var distance:=Vector2(actor.global_position.x-target.x,actor.global_position.z-target.z).length()
		if distance<tolerance:
			move_towards(Vector3.ZERO)
			note("walk_complete",{"goal":str(point),"distance":distance,"net_m":actor.global_position.distance_to(start)})
			return true
		var hostile:=nearby_hostile()
		if is_instance_valid(hostile):
			if not await combat(hostile,"incidental"): return false
			best=INF
			stalled=0
			continue
		if distance<best-.1: best=distance; stalled=0
		else: stalled+=1
		move_towards(game.world_navigation.direction_for(actor,target))
		if frame%300==0: note("walk_progress",{"goal":str(point),"distance":distance})
		if stalled>60*12:
			note("walk_stuck",{"goal":str(point),"distance":distance,"floor":actor.is_on_floor(),"nav_direction":str(game.world_navigation.direction_for(actor,target))})
			move_towards(Vector3.ZERO)
			return false
		await ticks(1)
	note("walk_timeout",{"goal":str(point)})
	return false

func talk(choice: String,label: String) -> bool:
	set_stage(label)
	var before:=ledger_snapshot()
	move_towards(Vector3.ZERO)
	game.aim_override=null
	await ticks(20)
	var npc: Node=game.nearest_interactable()
	note("interact",{"npc":npc.get("display_name") if is_instance_valid(npc) else "none","expected_choice":choice})
	await tap(KEY_F)
	await ticks(6)
	if not game.dialogue_panel.is_open():
		note("dialogue_not_open",{"error":game.interactions.last_error,"toast":game.toast_text})
		return false
	var chosen:=false
	var last_line:=""
	for _step in range(120):
		var panel: Node=game.dialogue_panel
		if not panel.is_open():
			note("dialogue_closed",{"selected_requested_choice":chosen,"ledger_before":before,"ledger_after":ledger_snapshot()})
			return chosen
		if panel._busy or panel.dialogue_line==null: await ticks(2); continue
		var line: String=str(panel.dialogue_line.text)
		if line!=last_line:
			note("dialogue_line",{"text":line})
			last_line=line
		if panel._typing.finished and not panel.dialogue_line.responses.is_empty():
			var selected:=-1
			for index in range(panel.dialogue_line.responses.size()):
				var text: String=panel.dialogue_line.responses[index].text
				if text==choice or text=="第一章完成，继续探索。": selected=index
			if selected<0: note("unexpected_responses",{"text":line}); return false
			while panel.menu.selected!=selected:
				await tap(KEY_DOWN)
			if panel.dialogue_line.responses[selected].text==choice: chosen=true
		await tap(KEY_ENTER)
		await ticks(3)
	note("dialogue_timeout")
	return false

func fight(id: String) -> bool:
	set_stage("encounter-"+id)
	move_towards(Vector3.ZERO)
	if id in victories:
		note("objective_defeated_en_route",{"id":id})
		return true
	for _frame in range(180):
		var foe: Node=game.combat_world._encounter_nodes.get(id)
		if is_instance_valid(foe): return await combat(foe,id)
		await ticks(1)
	note("encounter_absent",{"id":id,"record":game.encounters.record(id),"hint":game.combat_world.encounter_hint(game.encounters.definition(id).enemy_id)})
	return false

func combat(foe: Node,label: String) -> bool:
	var id: int=foe.get_instance_id()
	if not observed_attacks.has(id):
		observed_attacks[id]=0
		foe.combat.runner.action_started.connect(func(_action: Dictionary): observed_attacks[id]+=1)
	active_combat={"foe":foe.enemy_id,"encounter":str(foe.get_meta("encounter_id","")),"kind":label,"start":state(),"ledger_before":ledger_snapshot(),"minimum_hp":actor.resources.current("HP"),"spent_before":spent_totals.duplicate(true),"skill_paid_before":paid_skill_totals.duplicate(true),"items_before":item_uses.duplicate(true),"actions_before":action_events.size(),"resource_changes_before":resource_changes.duplicate(true)}
	note("combat_start",{"foe":foe.enemy_id,"kind":label,"foe_position":str(game.reference_map.to_local(foe.global_position)),"foe_hp":foe.resources.current("HP")})
	game.combat_world.locked_target=foe
	for frame in range(60*100):
		if actor.combat.state=="DEAD":
			note("combat_dead",{"foe":foe.enemy_id,"foe_hp":foe.resources.current("HP")})
			end_combat(foe,"player_dead")
			move_towards(Vector3.ZERO)
			return false
		if not is_instance_valid(foe) or foe.combat.state=="DEAD":
			move_towards(Vector3.ZERO)
			if is_instance_valid(foe): victories.append(str(foe.get_meta("encounter_id","")))
			note("combat_victory",{"foe":foe.enemy_id if is_instance_valid(foe) else "freed","kind":label})
			await ticks(3)
			end_combat(foe,"victory")
			return true
		if hold_queued_dodge():
			await ticks(1)
			continue
		if not on_land_navigation() and actor.combat.can_start():
			if not await recover_land():
				end_combat(foe,"offmesh_recovery_failed")
				return false
		var offset: Vector3=foe.global_position-actor.global_position
		offset.y=0
		var distance:=offset.length()
		var direction:=offset.normalized()
		game.aim_override=foe.global_position
		game.combat_world.aim_point=foe.global_position
		var walking: Vector3=game.world_navigation.direction_for(actor,foe.global_position) if distance>float(PROFILES[career].stop_distance) else Vector3.ZERO
		var incoming: Dictionary=foe.combat.runner.current_action
		var react: bool=not incoming.is_empty() and handled_attacks.get(id,-1)!=observed_attacks[id] and foe.combat.runner.action_time>=maxf(.18,float(incoming.get("startup",.1))-.12) and foe.combat.runner.action_phase!="RECOVERY" and distance<float(incoming.get("range",3))+.8
		if react and actor.resources.current("Stamina")>=1:
			var candidate:=safe_dodge_direction(-direction)
			if candidate.is_empty():
				handled_attacks[id]=observed_attacks[id]
				record_request("dodge","dodge",false,"policy: no dry connected landing")
				note("dodge_declined_terrain",{"foe_action":incoming.get("id",""),"distance":distance})
			else:
				walking=candidate.direction
				move_towards(walking)
				await ticks(1) # normal input routing establishes the dodge direction
				resource_context="dodge_request"
				var accepted: bool=actor.combat.request_dodge()
				resource_context="simulation"
				record_request("dodge","dodge",accepted,actor.combat.last_condition_failed)
				if accepted:
					handled_attacks[id]=observed_attacks[id]
					dodge_intent={"seconds":simulated,"direction":walking,"expires":actor.combat.queued_command.get("expires",actor.combat.input_time+.20),"queued":actor.combat.state!="DODGE","landing":candidate,"foe_action":incoming.get("id","")}
					dodge_intent_events.append({"event":"accepted_request","request":dodge_intent.duplicate(true)})
		move_towards(walking)
		if actor.combat.can_start():
			if actor.resources.current("HP")<actor.resources.max_value("HP")*.45:
				resource_context="item:healing_potion"
				var consumed: bool=actor.inventory.use_item("healing_potion")
				resource_context="simulation"
				record_request("item","healing_potion",consumed,actor.inventory.last_error)
			var primary: Dictionary=actor.action_for("PRIMARY_TAP",actor.combat.combo)
			var reach: float=actor.combat._action_reach(primary,foe)
			var selected_skill: Dictionary=actor.skill_at(0)
			var skill_reach: float=actor.combat._action_reach(selected_skill,foe)
			# Warrior keeps the original approach/cast threshold as the comparison
			# baseline. Other profiles use their skill's reach independently of the
			# normal attack. Mage stops at six metres; there is no automatic kiting.
			var skill_gate: float=reach if career=="warrior" else skill_reach
			var used:=false
			if distance<=skill_gate*.9 and simulated>=next_skill:
				actor.facing=direction
				resource_context="skill_request:"+skill_id
				used=actor.combat.request_skill(0)
				resource_context="simulation"
				record_request("skill",skill_id,used,actor.combat.last_condition_failed)
				if used: next_skill=simulated+4
			if not used and distance<=reach*.9:
				actor.facing=direction
				resource_context="weapon_request:"+str(primary.get("id",""))
				var attacked: bool=actor.combat.weapon_action("PRIMARY_TAP")
				resource_context="simulation"
				record_request("weapon",str(primary.get("id","")),attacked,actor.combat.last_condition_failed)
		if frame%300==0: note("combat_progress",{"foe":foe.enemy_id,"foe_hp":foe.resources.current("HP"),"distance":distance,"foe_position":str(game.reference_map.to_local(foe.global_position)),"foe_action":incoming.get("id","")})
		await ticks(1)
	note("combat_timeout",{"foe":foe.enemy_id,"foe_hp":foe.resources.current("HP"),"foe_position":str(game.reference_map.to_local(foe.global_position))})
	end_combat(foe,"timeout")
	move_towards(Vector3.ZERO)
	return false

func end_combat(foe: Node,outcome: String) -> void:
	if active_combat.is_empty(): return
	active_combat["outcome"]=outcome
	active_combat["end"]=state()
	active_combat["seconds"]=simulated-float(active_combat.start.seconds)
	active_combat["foe_hp_end"]=foe.resources.current("HP") if is_instance_valid(foe) else 0
	active_combat["ledger_after"]=ledger_snapshot()
	active_combat["resource_spent"]=difference(spent_totals,active_combat.spent_before)
	active_combat["skills_paid_costs"]=difference(paid_skill_totals,active_combat.skill_paid_before)
	active_combat["items_used"]=difference(item_uses,active_combat.items_before)
	active_combat["actions_started"]=action_events.size()-int(active_combat.actions_before)
	active_combat["resource_changes_after"]=resource_changes.duplicate(true)
	combat_records.append(active_combat.duplicate(true))
	active_combat.clear()

func _watchdog() -> void:
	if finished: return
	note("WATCHDOG")
	finish(false)

func fingerprints() -> Dictionary:
	var result: Dictionary={}
	for path: String in ["tests/chapter_playthrough.gd","data/combat/careers.json","data/combat/skills.json","data/combat/actions.json","data/combat/weapons.json","data/combat/passives.json","data/combat/progression.json","data/combat/items.json","data/world/quests.json","data/world/shops.json","combat/combat_controller.gd","combat/resource_recovery.gd"]:
		result[path]=FileAccess.get_sha256("res://"+path)
	return result

func finish(success: bool) -> void:
	if finished: return
	finished=true
	if watchdog!=null and watchdog.timeout.is_connected(_watchdog): watchdog.timeout.disconnect(_watchdog)
	watchdog=null
	if is_instance_valid(game): move_towards(Vector3.ZERO)
	note("COMPLETE" if success else "BLOCKED",{"checks":checks,"failures":failures,"diagnostic_policy":"native book + F/Enter dialogue; InputMap walking; normal controller attacks and finite paid dodges; real inventory potions; no teleport or resource grants"})
	if not phase_records.is_empty():
		phase_records[-1]["end"]=state()
		phase_records[-1]["ledger_end"]=ledger_snapshot()
	if not active_combat.is_empty(): end_combat(null,"interrupted")
	var report: Dictionary={"ok":success and failures.is_empty(),"career":career,"seed":seed_value,"checks":checks,"failures":failures,"isolated":isolated,"evidence":output,"wall_seconds":float(Time.get_ticks_msec()-started_wall)/1000.0,"simulated_seconds":simulated,"end":state(),"blocking_failure":{} if success else pending_failure,"prepared":prepared,"stages":phase_records,"combats":combat_records,"ledger_events":ledger_events,"enemy_rewards":reward_events,"actions":action_events,"requests":request_totals,"resource_spent":spent_totals,"resource_spent_events":spent_events,"resource_changed":resource_changes,"skills_paid_costs":paid_skill_totals,"items_used":item_uses,"dodge_starts":dodge_starts,"paid_dodges":paid_dodges,"dodge_stamina_gross":dodge_stamina,"perfect_dodges":perfect_dodges,"dodge_refunds":dodge_refunds,"deaths":deaths,"respawns":respawns_seen,"source_sha256":fingerprints(),"scope":"Automated controller diagnosis, not manual play or a no-death guarantee. Shared map routes, actual native career/study/preparation and F/Enter NPC dialogue, ordinary controller attacks/dodges and real finite inventory. Starting distance is profile-specific; no shield grants, perfect timing, backstab routing or continuous mage kiting. resource_changed gains include recovery/refunds/effects; maximum changes are separate. Accepted requests can be buffered; action paid_costs and resource_spent are the payment evidence. Only return-route deaths auto-recover (maximum two), matching the original warrior policy. No supply-stop/shop/waystone route yet."}
	var file:=FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
	report["policy_version"]=2
	report["dodge_intents"]=dodge_intent_events
	report["offmesh_recoveries"]=offmesh_recoveries
	report.scope+=" Version 2 holds queued dodge direction until actual execution/expiry, chooses retreat or sidestep only when coarse dry-land samples stay navigable, and uses at most six eight-second ordinary movement recoveries toward previously observed land. Initial-placement shore probes validate recovery separately; full chapter never repositions the actor."
	if file!=null:
		file.store_string(JSON.stringify(report,"  "))
		file.close()
	if is_instance_valid(app): app.selected_save=-1; app.queue_free()
	Engine.time_scale=1
	Engine.physics_ticks_per_second=60
	print("CHAPTER_CHAIN ","PASS" if success else "BLOCKED"," career=",career," evidence=",output)
	quit(0 if success else 1)
