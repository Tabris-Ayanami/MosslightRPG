extends SceneTree
## Real App, terrain, native actors, encounter transactions and disk restores.
## Damage calls prepare life-cycle fixtures, not combat/difficulty assertions.
## The walk segment makes only the arriving actor neutral to isolate navigation.
const Preferences = preload("res://rpg/game_preferences.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Arrival = preload("res://rpg/encounter_arrival.gd")
const SOLDIER := "encounter.forest.soldier_01"
const HEAVY := "encounter.forest.heavy_guard_01"
const FIRE := "encounter.forest.fire_elemental_01"
const OGRE := "encounter.forest.ogre_01"
const LETHAL := {"formula":{"base":1000000}, "can_crit":false, "damage_type":"PHYSICAL"}
var app: Node
var game: Node
var repo: RefCounted
var isolated := ""
var evidence := ""
var checks := 0
var failures: Array[String] = []
var patrol: Dictionary = {}
var before_guard: Dictionary = {}
var alternate: Dictionary = {}
var definitions: Dictionary = {}

func _initialize() -> void:
	isolated = OS.get_temp_dir().path_join("mosslight-arrival-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path = isolated.path_join("preferences.cfg")
	evidence = ProjectSettings.globalize_path("res://.work/encounter-arrival-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(evidence)
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)

func ticks(n: int) -> void:
	for _i in range(n):
		await physics_frame
		await process_frame

func freeze() -> void:
	game.combat_world.set_physics_process(false)
	game.player.set_physics_process(false)
	for enemy in game.combat_world.enemies:
		if is_instance_valid(enemy): enemy.set_physics_process(false)

func at(point: Vector3) -> Vector3: return game.reference_map.to_global(point)
func body(id: String) -> Node: return game.combat_world._encounter_nodes.get(id)
func record(id: String) -> Dictionary: return game.encounters.record(id)
func home(id: String) -> Vector3:
	return game.combat_world._encounter_position(game.encounters.definition(id))
func entry(id: String, index: int) -> Vector3:
	var point: Array = game.encounters.definition(id).arrival_points[index]
	return at(Vector3(point[0],point[1],point[2]))
func flat_distance(a: Vector3,b: Vector3) -> float:
	return Vector2(a.x-b.x,a.z-b.z).length()
func kill(enemy: Node) -> void: enemy.combat.receive_damage(LETHAL,game.player,Vector3.FORWARD)
func rewards() -> Dictionary:
	return {"inventory":game.player.inventory.export_state(),"progression":game.player.progression.export_state(),"counters":game.world_state.export_state().counters}
func live_count(id: String) -> int:
	var count := 0
	for enemy in game.combat_world.enemies:
		if is_instance_valid(enemy) and enemy.is_inside_tree() and enemy.combat.state!="DEAD" and enemy.get_meta("encounter_id","")==id: count+=1
	return count

func restore(snapshot: Dictionary, label: String) -> void:
	var result: Dictionary=repo.restore(snapshot,game.player,game)
	check(result.ok,label+" "+str(result.get("error","")))
	freeze()
	app.ui._sync_rpg()

func save_snapshot(label: String, slot := 0) -> Dictionary:
	var slot_name: String=repo.load_slot(slot).snapshot.name
	var result: Dictionary = repo.save(slot,slot_name,game.player,game)
	check(result.ok,"isolated disk save: "+label+" "+str(result.get("error","")))
	return result.get("snapshot",{}).duplicate(true)

func verify_arrival(id: String, index: int, label: String) -> void:
	var enemy: Node = body(id)
	check(is_instance_valid(enemy),label+" creates a real actor")
	if not is_instance_valid(enemy): return
	check(flat_distance(enemy.global_position,entry(id,index))<.05,label+" uses selected authored entry XZ")
	check(game.combat_world._safe_position(enemy.global_position,12),label+" is more than 12m from hero and possessed body")
	check(flat_distance(enemy.spawn_point,home(id))<.01 and enemy.spawn_point.distance_to(enemy.global_position)>12,label+" preserves the original home, not the entry, for return movement")
	check(enemy.has_meta("encounter_arriving") and live_count(id)==1,label+" publishes one visible arriving life")
	var ground := PhysicsRayQueryParameters3D.create(enemy.global_position+Vector3.UP*4,enemy.global_position-Vector3.UP*4,1)
	var hit: Dictionary = enemy.get_world_3d().direct_space_state.intersect_ray(ground)
	check(not hit.is_empty() and enemy.global_position.y>float(hit.get("position",Vector3.INF).y),label+" starts above the actual entry ground")

func capture(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	# Remove synthetic lethal-fixture damage numerals from visual evidence.
	game.combat_world.floaters.clear()
	game.floaters.clear()
	app.ui.modulate.a=1
	app.ui._sync_rpg()
	await ticks(5)
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(evidence.path_join(label+".png"))==OK,"Forward+ HUD capture: "+label)

func run() -> void:
	create_timer(180,true,false,true).timeout.connect(func(): printerr("ENCOUNTER_ARRIVAL watchdog"); quit(1))
	if DisplayServer.get_name()=="headless": root.size=Vector2i(1280,720)
	repo=Repository.new(isolated.path_join("adventures"))
	var created: Dictionary=repo.create("林路入场",0)
	var other: Dictionary=repo.create("另一段旅途",1)
	check(created.ok and other.ok,"both adventures created in isolated repository before App enters tree")
	alternate=other.snapshot.duplicate(true)
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=repo
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app.selected_name="林路入场"
	app.selected_save=0
	app.pending_snapshot=created.snapshot.duplicate(true)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	game=app.game
	game.sound.muted=true
	app.ui.modulate.a=1
	app.ui.close_panel(true)
	await ticks(10)
	freeze()
	var deadline:=Time.get_ticks_msec()+5000
	while not game.world_navigation.navigation_ready() and Time.get_ticks_msec()<deadline: await physics_frame
	check(game.world_navigation.navigation_ready(),"real terrain navigation is ready")
	check(Preferences.settings_path.begins_with(isolated) and app.saves.directory.begins_with(isolated),"preferences and saves were isolated before App entered tree")
	for item in game.encounters.entries():
		definitions[item.id]=game.encounters.definition(item.id)
	check(game.player.progression.choose_career("warrior") and game.quests.accept("village_patrol"),"real career and first quest prepare normal adventure")
	patrol=save_snapshot("首巡逻起点")
	if patrol.is_empty():
		app.selected_save=-1
		app.queue_free()
		await ticks(3)
		quit(1)
		return
	await near_home_restore()
	prepare_investigation()
	await first_unlock()
	one_entry_occupied()
	await both_entries_occupied()
	cooldown_policy()
	pending_life()
	cleared_life()
	switch_adventure()
	app.selected_save=-1
	app.queue_free()
	await ticks(4)
	var result := "ENCOUNTER_ARRIVAL checks=%d failures=%d evidence=%s"%[checks,failures.size(),evidence]
	print(result)
	for failure in failures: printerr("FAIL: ",failure)
	var output:=FileAccess.open(evidence.path_join("result.log"),FileAccess.WRITE)
	output.store_string(result+"\n"+"\n".join(failures))
	output.close()
	quit(0 if failures.is_empty() else 1)

func near_home_restore() -> void:
	restore(patrol,"restore ordinary patrol baseline")
	game.player.global_position=home(SOLDIER)
	var near:=save_snapshot("士兵近处读档")
	var before:=rewards()
	restore(repo.load_slot(0).snapshot,"read real disk save with hero occupying living soldier home")
	verify_arrival(SOLDIER,0,"near-home restore")
	if not is_instance_valid(body(SOLDIER)): return
	check(record(SOLDIER).phase=="alive" and record(SOLDIER).generation==1 and rewards()==before,"reconstructing existing living generation gives no reward or generation increment")
	var snapshot: Dictionary=game.world_state.export_state()
	var hint: String=game.combat_world.encounter_hint("soldier")
	check(hint.contains("赶来") and app.ui.tracked_quest_summary().detail==hint,"tracked objective HUD exposes the real incoming actor")
	check(game.world_state.export_state()==snapshot,"querying arrival hint never changes tracking or persistent world")
	await capture("01-soldier-incoming")
	var first: Node=body(SOLDIER)
	for _i in range(4): game.combat_world._tick_encounters(0)
	check(body(SOLDIER)==first and live_count(SOLDIER)==1 and rewards()==before,"repeated arrival reconciliation cannot duplicate actor or rewards")
	restore(near,"repeat the same near-home disk snapshot")
	check(body(SOLDIER)!=first and not first.is_inside_tree() and live_count(SOLDIER)==1 and rewards()==before,"repeat restore detaches old actor and rebuilds exactly one unpaid life")
	restore(patrol,"return to safe-home baseline")
	check(body(SOLDIER).global_position==home(SOLDIER) and not body(SOLDIER).has_meta("encounter_arriving"),"safe home keeps the original immediate placement")
	check(not is_instance_valid(body(HEAVY)) and not is_instance_valid(body(OGRE)) and game.combat_world.encounter_hint("ogre").is_empty(),"locked chapter encounters stay absent with no waiting hint")

func prepare_investigation() -> void:
	restore(patrol,"restore patrol for real quest unlock transactions")
	kill(body(SOLDIER))
	check(game.quests.claim("village_patrol") and game.quests.accept("forest_investigation"),"actual soldier defeat and claim unlock investigation")
	game.combat_world._tick_encounters(0)
	freeze()
	check(is_instance_valid(body(HEAVY)) and is_instance_valid(body(FIRE)) and not is_instance_valid(body(OGRE)),"investigation baseline has guard/fire but locked boss")
	before_guard=save_snapshot("重甲守卫尚存")

func first_unlock() -> void:
	restore(before_guard,"restore before first boss unlock")
	game.player.global_position=home(OGRE)
	kill(body(HEAVY))
	var before:=rewards()
	game.combat_world._tick_encounters(0)
	freeze()
	verify_arrival(OGRE,0,"first boss unlock beside occupied home")
	if not is_instance_valid(body(OGRE)): return
	check(body(OGRE).loadout.level==5 and record(OGRE).generation==1 and record(OGRE).phase=="alive","arrival preserves authored boss profile and original living generation")
	check(rewards()==before and game.world_state.get_event_count("enemy_defeated","ogre")==0,"first boss entry does not pay premature boss reward")
	app.ui._sync_rpg()
	check(app.ui.tracked_quest_summary().detail.contains("赶来"),"first boss objective communicates entry on live HUD")
	await capture("02-boss-incoming")

func one_entry_occupied() -> void:
	restore(before_guard,"restore one-entry possession fixture")
	game.player.global_position=home(OGRE)
	var vessel: Node=body(FIRE)
	vessel.global_position=entry(OGRE,0)
	check(game.combat_world.control.possess(vessel,100),"actual unit control occupies first entry")
	kill(body(HEAVY))
	var before:=rewards()
	game.combat_world._tick_encounters(0)
	freeze()
	verify_arrival(OGRE,1,"possessed first entry selects second entry")
	check(rewards()==before and record(OGRE).generation==1,"alternate entry changes neither rewards nor generation")
	game.combat_world.control.release()

func make_both_blocked() -> Node:
	restore(before_guard,"restore double-blocked entry fixture")
	# Hero's sphere covers home and entry B; a real possessed body covers A.
	game.player.global_position=(home(OGRE)+entry(OGRE,1))*.5
	var vessel: Node=body(FIRE)
	vessel.global_position=entry(OGRE,0)
	check(game.combat_world.control.possess(vessel,100),"two real bodies cover home and both arrival points")
	kill(body(HEAVY))
	game.combat_world._tick_encounters(0)
	freeze()
	return vessel

func both_entries_occupied() -> void:
	var vessel:=make_both_blocked()
	var before:=rewards()
	check(not is_instance_valid(body(OGRE)) and record(OGRE).phase=="alive" and record(OGRE).generation==1,"blocked entries wait without creating a fake/dead/new life")
	var hint: String=game.combat_world.encounter_hint("ogre")
	check(hint.contains("解除附身") and hint.contains("让出"),"waiting feedback gives an actionable way to free entry")
	app.ui._sync_rpg()
	var tracking: Variant=game.world_state.get_flag("journal.tracked_quest")
	check(app.ui.tracked_quest_summary().detail==hint and tracking=="forest_investigation","waiting reason replaces objective detail without changing tracked quest")
	await capture("03-boss-entry-blocked")
	for _i in range(3): game.combat_world._tick_encounters(0)
	check(not is_instance_valid(body(OGRE)) and rewards()==before,"retries while blocked remain inert")
	game.combat_world.control.release()
	# Release restores control; the physical body must also vacate the entry.
	vessel.global_position=vessel.spawn_point
	# PhysicsServer must publish the relocated capsule before the next normal
	# spawn retry. Rendering takes real frames; an immediate same-frame query
	# may correctly still see the old occupancy after a fixture teleport.
	await ticks(2)
	game.combat_world._tick_encounters(0)
	freeze()
	verify_arrival(OGRE,0,"freeing occupied route")
	if not is_instance_valid(body(OGRE)): return
	var arriving: Node=body(OGRE)
	for _i in range(3): game.combat_world._tick_encounters(0)
	check(body(OGRE)==arriving and live_count(OGRE)==1 and record(OGRE).generation==1 and rewards()==before,"unblocked retries create only one original life without rewards")
	check(game.combat_world.encounter_hint("ogre").contains("赶来"),"waiting feedback becomes incoming feedback")
	await walk_arrival(arriving)

func walk_arrival(arriving: Node) -> void:
	var original_faction: String=arriving.faction_id
	var before: Vector3=arriving.global_position
	# Keep the real hero active, and suppress only this fixture's hostility.
	# Native capsule, speed, UnitBrain, navigation and movement remain unchanged.
	arriving.faction_id="arrival_route_fixture"
	arriving.refresh_collision_layer()
	game.player.set_control_mode("none")
	game.player.set_physics_process(true)
	arriving.ai_enabled=true
	arriving.set_physics_process(true)
	var minimum_y:=INF
	var frames:=0
	if DisplayServer.get_name()=="headless":
		Engine.physics_ticks_per_second=240
		Engine.time_scale=4
		Engine.max_physics_steps_per_frame=32
	while frames<1200 and flat_distance(arriving.global_position,arriving.spawn_point)>.85:
		await physics_frame
		frames+=1
		minimum_y=minf(minimum_y,arriving.global_position.y)
	Engine.time_scale=1
	Engine.physics_ticks_per_second=60
	freeze()
	check(flat_distance(arriving.global_position,arriving.spawn_point)<=.85 and flat_distance(before,arriving.global_position)>12,"production arriving ogre actually walks from its entry to original home")
	check(minimum_y>1.1 and not is_instance_valid(arriving.current_target),"neutral route fixture remains on land and uses return-home rather than combat pursuit")
	print("ARRIVAL_WALK frames=",frames," start=",game.reference_map.to_local(before)," end=",game.reference_map.to_local(arriving.global_position))
	arriving.faction_id=original_faction
	arriving.refresh_collision_layer()
	game.player.set_control_mode("human")
	game.combat_world._physics_process(0)
	app.ui._sync_rpg()
	check(game.combat_world.encounter_hint("ogre").is_empty() and not app.ui.tracked_quest_summary().detail.contains("赶来"),"arrival hint clears when actor reaches its home")
	await capture("04-boss-arrived")

func cooldown_policy() -> void:
	restore(patrol,"restore cooldown policy fixture")
	kill(body(SOLDIER))
	var before:=rewards()
	game.player.global_position=home(SOLDIER)
	check(not Arrival.choose(game.combat_world,game.encounters.definition(SOLDIER),home(SOLDIER)).is_empty(),"a safe alternate entry exists while ordinary respawn home is occupied")
	game.combat_world._tick_encounters(45)
	check(record(SOLDIER).phase=="cooldown" and record(SOLDIER).remaining==45 and record(SOLDIER).generation==1 and not is_instance_valid(body(SOLDIER)),"elapsed time cannot refresh a defeated life despite an available entry")
	game.combat_world._tick_encounters(0)
	check(record(SOLDIER).generation==1 and rewards()==before,"zero-time retry cannot prematurely refresh or pay again")
	game.player.global_position=at(Vector3(1.6,2.35,4.8))
	var rest: Dictionary=game.encounters.plan_short_rest(game.world_state.export_state())
	check(rest.ok and game.world_state.import_state(rest.world),"short rest commits next encounter generation")
	game.combat_world.refresh_after_short_rest()
	freeze()
	check(record(SOLDIER).phase=="alive" and record(SOLDIER).generation==2 and is_instance_valid(body(SOLDIER)) and body(SOLDIER).global_position==home(SOLDIER),"safe home creates exactly the next ordinary generation at home")
	check(rewards()==before,"ordinary respawn itself does not repeat previous death rewards")
	game.player.global_position=home(SOLDIER)
	var second:=save_snapshot("第二代近处重建")
	restore(second,"restore second living generation close to home")
	verify_arrival(SOLDIER,0,"second-generation reload")
	check(record(SOLDIER).generation==2 and rewards()==before,"near reload of generation two cannot pay or increment it")

func pending_life() -> void:
	restore(patrol,"restore pending reward fixture")
	game.player.inventory.stacks.healing_potion=1000000
	var before:=rewards()
	kill(body(SOLDIER))
	check(record(SOLDIER).phase=="pending" and rewards()==before,"actual failed loot transaction creates a defeated pending life")
	game.player.global_position=home(SOLDIER)
	var pending:=save_snapshot("待结算死亡")
	restore(pending,"restore pending death beside its home")
	game.combat_world._tick_encounters(90)
	check(not is_instance_valid(body(SOLDIER)) and record(SOLDIER).phase=="pending" and record(SOLDIER).generation==1 and game.combat_world.encounter_hint("soldier").is_empty(),"pending means dead reward settlement, never arrival waiting or respawn")
	check(rewards()==before,"restoring pending life pays no duplicate reward")

func cleared_life() -> void:
	restore(patrol,"restore one-shot encounter fixture")
	# Authored chapter encounters currently respawn. A supported zero-respawn
	# catalog fixture exercises the separate cleared branch without invalid saves.
	var once: Dictionary=definitions.duplicate(true)
	once[SOLDIER].respawn_seconds=0
	check(game.encounters.setup(game.world_state,game.combat_world.database,once),"temporary non-respawning definition is valid for cleared-life coverage")
	kill(body(SOLDIER))
	var before:=rewards()
	game.player.global_position=home(SOLDIER)
	game.combat_world._tick_encounters(90)
	game.combat_world.restore_encounters()
	freeze()
	check(record(SOLDIER).phase=="cleared" and record(SOLDIER).generation==1 and not is_instance_valid(body(SOLDIER)),"cleared one-shot life stays absent through runtime reconstruction")
	check(rewards()==before and game.combat_world.encounter_hint("soldier").is_empty(),"cleared reconstruction has no rewards or misleading wait hint")
	# Remove the temporary rule and its fixture world together before disk restore.
	check(game.world_state.import_state(patrol.world_state) and game.encounters.setup(game.world_state,game.combat_world.database,definitions),"original catalog and compatible baseline world restored after fixture")

func switch_adventure() -> void:
	make_both_blocked()
	check(not game.combat_world.encounter_hint("ogre").is_empty(),"old adventure has genuine pending entry feedback before switch")
	restore(alternate,"switch to a fresh independent adventure")
	check(game.combat_world._arrival_waiting.is_empty() and game.combat_world.encounter_hint("ogre").is_empty() and not is_instance_valid(body(OGRE)),"adventure switch clears old waiting feedback and retains new chapter locks")
	check(game.player.loadout.level==0 and game.world_state.get_event_count("enemy_defeated")==0 and game.player.inventory.stacks.is_empty(),"fresh adventure receives none of old arrival/death rewards")
	check(game.combat_world.control.controlled_actor()==game.player and live_count(SOLDIER)==1,"restore releases old possessed body and rebuilds one introductory life")
