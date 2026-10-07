extends SceneTree
## Diagnostic, not a passing assertion of the existing awareness behavior.
## Real App, ordinary Lv1 mage and live Ogre AI; only starting positions/aim
## are fixtures. No direct damage, AI disable, frozen actors or resource grants.
const Preferences = preload("res://rpg/game_preferences.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Definition = preload("res://combat/unit_definition.gd")
const Arrival = preload("res://rpg/encounter_arrival.gd")
var app: Node
var game: Node
var hero: Node
var foe: Node
var isolated := ""
var evidence := ""
var requested_case := "all"
var checks := 0
var failures: Array[String] = []
var cases: Array[Dictionary] = []
var samples: Array[Dictionary] = []
var events: Array[Dictionary] = []
var active_case := ""
var phase := ""
var elapsed := 0.0
var phase_elapsed := 0.0
var frame_count := 0
var sample_clock := 0.0
var tracking := false
var phase_metrics: Dictionary = {}
var shot_starts := 0
var hit_events := 0
var direct_hits := 0
var direct_damage := 0.0
var open_pair_validation: Dictionary = {}
var hero_start := Vector3.ZERO
var foe_start := Vector3.ZERO
var watchdog: SceneTreeTimer
var finished := false

func _initialize() -> void:
	isolated = OS.get_temp_dir().path_join("mosslight-ranged-awareness-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence="): evidence = arg.trim_prefix("--evidence=")
		elif arg.begins_with("--case="): requested_case = arg.trim_prefix("--case=")
	if evidence.is_empty(): evidence = ProjectSettings.globalize_path("res://.work/ranged-awareness-20260930/run-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	DirAccess.make_dir_recursive_absolute(evidence)
	Preferences.settings_path = isolated.path_join("preferences.cfg")
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func ticks(n: int) -> void:
	for _index in range(n):
		await physics_frame
		await process_frame

func v(point: Vector3) -> Array: return [point.x, point.y, point.z]
func at(point: Vector3) -> Vector3: return game.reference_map.to_global(point)
func local(point: Vector3) -> Array: return v(game.reference_map.to_local(point))
func flat(a: Vector3, b: Vector3) -> float: return Vector2(a.x - b.x, a.z - b.z).length()

func object_info(value: Object) -> Dictionary:
	if not is_instance_valid(value): return {}
	return {"class": value.get_class(), "id": value.get_instance_id(), "path": str(value.get_path()) if value is Node and value.is_inside_tree() else ""}

func hit_info(hit: Dictionary) -> Dictionary:
	if hit.is_empty(): return {"clear": true}
	return {"clear": false, "collider": object_info(hit.get("collider")), "position": v(hit.get("position", Vector3.ZERO)), "local_position": local(hit.get("position", Vector3.ZERO)), "normal": v(hit.get("normal", Vector3.ZERO)), "shape": hit.get("shape", -1)}

func sight_ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from + Vector3.UP * .8, to + Vector3.UP * .8, 1)
	return hit_info(hero.get_world_3d().direct_space_state.intersect_ray(query))

func ground(point: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 8, point - Vector3.UP * 16, 1)
	return hero.get_world_3d().direct_space_state.intersect_ray(query)

func ground_info(point: Vector3) -> Dictionary:
	var hit := ground(point)
	var data := hit_info(hit)
	if not hit.is_empty(): data["feet_above_ground"] = point.y - float(hit.position.y)
	return data

func navigation_info() -> Dictionary:
	var nav: Node = game.world_navigation
	var path: PackedVector3Array = nav.path_between(foe.global_position, hero.global_position)
	var data := {"ready": nav.navigation_ready(), "points": path.size(), "reachable": nav.is_reachable(foe.global_position, hero.global_position)}
	if not path.is_empty():
		data["first"] = v(path[0])
		data["last"] = v(path[path.size() - 1])
		data["first_local"] = local(path[0])
		data["last_local"] = local(path[path.size() - 1])
		data["first_gap"] = v(path[0] - foe.global_position)
		data["last_gap"] = v(path[path.size() - 1] - hero.global_position)
	var entry: Dictionary = nav._agents.get(foe.get_instance_id(), {})
	if not entry.is_empty():
		var agent: NavigationAgent3D = entry.agent.get_ref()
		data["requested_destination"] = v(entry.destination)
		data["cached_direction"] = v(entry.direction)
		if is_instance_valid(agent):
			data["agent_finished"] = agent.is_navigation_finished()
			data["agent_target_reachable"] = agent.is_target_reachable()
			data["agent_path_index"] = agent.get_current_navigation_path_index()
			data["agent_path_points"] = agent.get_current_navigation_path().size()
			data["agent_final"] = v(agent.get_final_position())
	else: data["agent_exists"] = false
	return data

func snapshot(tag: String) -> Dictionary:
	var nearest: Node = game.combat_world.nearest_hostile(foe, foe.aggro_range * (2 if foe.brain.aggressive else 1))
	var collisions: Array[Dictionary] = []
	for index in range(foe.get_slide_collision_count()):
		var collision: KinematicCollision3D = foe.get_slide_collision(index)
		collisions.append({"collider": object_info(collision.get_collider()), "normal": v(collision.get_normal()), "position": v(collision.get_position())})
	return {"case": active_case, "phase": phase, "tag": tag, "seconds": elapsed, "phase_seconds": phase_elapsed,
		"hero_local": local(hero.global_position), "foe_local": local(foe.global_position), "hero_global": v(hero.global_position), "foe_global": v(foe.global_position),
		"distance_3d": hero.global_position.distance_to(foe.global_position), "distance_xz": flat(hero.global_position, foe.global_position), "aggro_range": foe.aggro_range,
		"nearest": object_info(nearest), "nearest_is_hero": nearest == hero, "line_clear": game.combat_world.line_clear(foe.global_position, hero.global_position),
		"los_forward": sight_ray(foe.global_position, hero.global_position), "los_reverse": sight_ray(hero.global_position, foe.global_position),
		"current_target": object_info(foe.current_target), "target_is_hero": foe.current_target == hero, "last_seen": v(foe.brain._last_seen), "sight_memory": foe.brain._sight_memory,
		"foe_state": foe.combat.state, "control_time": foe.combat.control_time, "poise": foe.combat.current_poise, "knockback": v(foe.combat.knockback),
		"foe_action": foe.combat.runner.current_action.get("id", ""), "foe_action_phase": foe.combat.runner.action_phase,
		"move_direction": v(foe.move_direction), "foe_velocity": v(foe.velocity), "foe_hp": foe.resources.current("HP"), "foe_in_combat": foe.combat.in_combat,
		"ai_enabled": foe.ai_enabled, "physics_processing": foe.is_physics_processing(), "input_blocked": foe.control_input_blocked(), "control_mode": foe.control_mode,
		"hero_state": hero.combat.state, "hero_hp": hero.resources.current("HP"), "hero_energy": hero.resources.current("Energy"), "hero_velocity": v(hero.velocity),
		"navigation": navigation_info(), "slide_collisions": collisions, "foe_ground": ground_info(foe.global_position)}

func record(tag: String) -> Dictionary:
	var row := snapshot(tag)
	samples.append(row)
	print("RANGED_SAMPLE ", JSON.stringify(row))
	return row

func _process(delta: float) -> bool:
	if not tracking or not is_instance_valid(foe): return false
	elapsed += delta
	phase_elapsed += delta
	frame_count += 1
	sample_clock += delta
	phase_metrics.frames += 1
	var nearest: Node = game.combat_world.nearest_hostile(foe, foe.aggro_range * (2 if foe.brain.aggressive else 1))
	phase_metrics.target_frames += int(foe.current_target == hero)
	phase_metrics.nearest_frames += int(nearest == hero)
	phase_metrics.los_frames += int(game.combat_world.line_clear(foe.global_position, hero.global_position))
	phase_metrics.moving_intent_frames += int(foe.move_direction.length_squared() > .01)
	phase_metrics.moving_velocity_frames += int(Vector2(foe.velocity.x, foe.velocity.z).length_squared() > .01)
	phase_metrics.controlled_frames += int(foe.combat.state in ["HITSTUN", "KNOCKDOWN", "EXPOSED", "GUARD_BROKEN", "GRABBED", "GRABBING"])
	phase_metrics.states[foe.combat.state] = int(phase_metrics.states.get(foe.combat.state, 0)) + 1
	phase_metrics.max_memory = maxf(phase_metrics.max_memory, foe.brain._sight_memory)
	phase_metrics.min_distance = minf(phase_metrics.min_distance, hero.global_position.distance_to(foe.global_position))
	phase_metrics.max_foe_displacement = maxf(phase_metrics.max_foe_displacement, flat(foe.global_position, foe_start))
	phase_metrics.max_hero_displacement = maxf(phase_metrics.max_hero_displacement, flat(hero.global_position, hero_start))
	if sample_clock >= .20:
		sample_clock = 0.0
		record("interval")
	return false

func start_phase(label: String) -> void:
	phase = label
	phase_elapsed = 0.0
	sample_clock = 0.0
	phase_metrics = {"frames": 0, "target_frames": 0, "nearest_frames": 0, "los_frames": 0, "moving_intent_frames": 0, "moving_velocity_frames": 0, "controlled_frames": 0, "states": {}, "max_memory": 0.0, "min_distance": INF, "max_foe_displacement": 0.0, "max_hero_displacement": 0.0}

func _hero_action_started(action: Dictionary) -> void:
	if not tracking: return
	shot_starts += 1
	events.append({"case": active_case, "type": "hero_action_started", "seconds": elapsed, "phase": phase, "action": action.get("id", ""), "range": action.get("range", 0), "costs": action.get("costs", {}), "paid_costs": action.get("paid_costs", {})})

func _foe_damage_received(amount: float) -> void:
	if not tracking: return
	hit_events += 1
	# Emitted inside receive_damage before engage/control handling finishes;
	# this event records impact only. The next process sample sees final state.
	events.append({"case": active_case, "type": "foe_hp_damage", "kind": "status_tick_candidate", "burn_active": foe.combat.statuses.has_status("burn"), "seconds": elapsed, "phase": phase, "amount": amount, "hero_local": local(hero.global_position), "foe_local": local(foe.global_position)})

func _hero_damage_dealt(result: Dictionary) -> void:
	if not tracking: return
	# hit_target emits this after hurtbox.receive returns. StatusComponent's
	# receive_damage(..., dot=true) path does not emit source damage_dealt.
	direct_hits += 1
	direct_damage += float(result.get("final", 0.0))
	for index in range(events.size() - 1, -1, -1):
		if events[index].get("case") == active_case and events[index].get("type") == "foe_hp_damage" and is_equal_approx(float(events[index].seconds), elapsed):
			events[index]["kind"] = "direct_hit"
			break
	events.append({"case": active_case, "type": "direct_hit_confirmed", "seconds": elapsed, "phase": phase, "result": result.duplicate(true)})

func _timeout() -> void:
	check(false, "probe watchdog exceeded 180 seconds")
	finish()

func run() -> void:
	watchdog = create_timer(180, true, false, true)
	watchdog.timeout.connect(_timeout)
	if DisplayServer.get_name() == "headless": root.size = Vector2i(1280, 720)
	var repo := Repository.new(isolated.path_join("adventures"))
	var created: Dictionary = repo.create("远程感知诊断", 0)
	check(created.get("ok", false), "create isolated ordinary Lv0 adventure")
	if not created.get("ok", false):
		await finish()
		return
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = repo
	root.add_child(app)
	app.set_process(false) # Skip frontend cinematic timing, not the live world.
	await ticks(3)
	app.selected_name = "远程感知诊断"
	app.selected_save = 0
	app.pending_snapshot = created.snapshot.duplicate(true)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	game = app.game
	hero = game.player
	game.sound.muted = true
	check(hero.progression.choose_career("mage"), "choose ordinary mage through progression service")
	check(hero.progression.learn_skill("mage_fireball"), "learn fireball through normal requirements")
	check(hero.loadout.assign_skill(0, 0, "mage_fireball"), "prepare learned fireball in normal first slot")
	app.ui.close_panel(true)
	await ticks(8)
	var deadline := Time.get_ticks_msec() + 10000
	while not game.world_navigation.navigation_ready() and Time.get_ticks_msec() < deadline: await process_frame
	check(game.world_navigation.navigation_ready(), "real map navigation published")
	check(Preferences.settings_path.begins_with(isolated) and app.saves.directory.begins_with(isolated), "Prefs and Repo isolated before App entered tree")
	check(hero.loadout.level == 1 and hero.loadout.combat_weapon().get("id", "") == "apprentice_staff", "ordinary Lv1 mage holds starting staff")
	check(not paused and not game.paused and hero.is_physics_processing(), "ordinary world and hero physics run without freeze")
	hero.combat.runner.action_started.connect(_hero_action_started)
	hero.combat.damage_dealt.connect(_hero_damage_dealt)
	if not failures.is_empty():
		await finish()
		return
	var open := choose_open_pair()
	if requested_case in ["all", "A_primary", "A_fireball"]:
		check(not open.is_empty(), "validate ground-supported clear reachable approximately 13m fixture")
		if not open.is_empty():
			if requested_case in ["all", "A_primary"]: await run_case("A_primary", open.hero, open.foe, "primary", false)
			if requested_case in ["all", "A_fireball"]: await run_case("A_fireball", open.hero, open.foe, "fireball", false)
	var terrain_cases := [
		{"id": "B64_primary", "hero": Vector3(33.37934, 2.200465, -15.2233), "foe": Vector3(41.98962, 1.74229, -24.75012), "attack": "primary"},
		{"id": "B69_primary", "hero": Vector3(33.88929, 2.200465, -15.92406), "foe": Vector3(41.68861, 1.861302, -24.56269), "attack": "primary"},
		{"id": "B69_fireball", "hero": Vector3(33.88929, 2.200465, -15.92406), "foe": Vector3(41.68861, 1.861302, -24.56269), "attack": "fireball"}]
	for item in terrain_cases:
		if requested_case in ["all", item.id]: await run_case(item.id, at(item.hero), at(item.foe), item.attack, true)
	check(not cases.is_empty(), "requested diagnostic cases were executed")
	await finish()

func choose_open_pair() -> Dictionary:
	# pre-v1's authored candidate search also required near-level ground and
	# no unit (including neutral NPCs) within 16m; it found no pair. Reuse the
	# independently verified B64 land/LOS/path coordinates, approximately 13m,
	# instead of silently changing production terrain or perception range.
	var a := at(Vector3(33.37934, 2.200465, -15.2233))
	var b := at(Vector3(41.98962, 1.74229, -24.75012))
	var a_ground := ground(a)
	var b_ground := ground(b)
	var action: Dictionary = hero.action_for("PRIMARY_TAP")
	var reach: float = hero.combat._action_reach(action)
	var supported := not a_ground.is_empty() and not b_ground.is_empty()
	if supported:
		supported = a.y - float(a_ground.position.y) > -.05 and a.y - float(a_ground.position.y) < .3 and b.y - float(b_ground.position.y) > -.05 and b.y - float(b_ground.position.y) < .3
	var clear: bool = game.combat_world.line_clear(a, b) and game.combat_world.line_clear(b, a)
	var reachable: bool = game.world_navigation.is_reachable(a, b)
	var distance := a.distance_to(b)
	var definition: Dictionary = Definition.for_enemy(game.combat_world.database, "ogre")
	var in_band: bool = distance > float(definition.ai.aggro_range) and distance < reach
	open_pair_validation = {"hero": v(a), "foe": v(b), "hero_ground": hit_info(a_ground), "foe_ground": hit_info(b_ground), "supported": supported, "clear": clear, "reachable": reachable, "distance": distance, "primary_reach": reach, "outside_aggro_inside_weapon": in_band,
		"body_fits": Arrival._body_fits(game.combat_world, b, definition.body), "selection": "Known B64 land coordinates, 12.849m; geometry includes a gentle slope, not an invented flat arena."}
	print("RANGED_PLACEMENT ", JSON.stringify(open_pair_validation))
	return {"hero": a, "foe": b} if supported and clear and reachable and in_band else {}

func run_case(id: String, hero_position: Vector3, foe_position: Vector3, attack: String, geometry_only: bool) -> void:
	active_case = id
	elapsed = 0.0
	shot_starts = 0
	hit_events = 0
	direct_hits = 0
	direct_damage = 0.0
	frame_count = 0
	# Fresh actor prevents previous target/memory/poise from leaking between cases.
	# No live actor is reset or moved again after this explicit starting fixture.
	hero.global_position = hero_position
	hero.velocity = Vector3.ZERO
	hero.surface_traversal.clear()
	foe = game.combat_world.spawn_enemy("ogre", foe_position)
	check(is_instance_valid(foe), id + " spawns unchanged production Ogre definition")
	if not is_instance_valid(foe): return
	foe.health.damage_received.connect(_foe_damage_received)
	hero_start = hero.global_position
	foe_start = foe.global_position
	start_phase("settle_before_shot")
	tracking = true
	var initial := record("fixture_start")
	await create_timer(2.0, false, false, true).timeout
	var before := record("before_shot")
	var before_metrics := phase_metrics.duplicate(true)
	var hp_before: float = foe.resources.current("HP")
	var energy_before: float = hero.resources.current("Energy")
	var original_physics: bool = foe.is_physics_processing()
	var original_ai: bool = foe.ai_enabled
	start_phase("single_shot_then_silence")
	game.combat_world.aim_override = foe.global_position
	game.aim_override = foe.global_position
	game.combat_world.refresh_aim()
	var started: bool
	if attack == "primary":
		started = hero.combat.weapon_action("PRIMARY_TAP")
	else:
		started = hero.skill_casting.press(0)
		if started: started = hero.skill_casting.confirm()
	var shot := record("shot_requested")
	events.append({"case": id, "type": "request", "attack": attack, "accepted": started, "error": hero.combat.last_condition_failed, "energy_before": energy_before, "energy_after": hero.resources.current("Energy")})
	await create_timer(2.0, false, false, true).timeout
	var after := record("two_seconds_after_shot")
	var after_metrics := phase_metrics.duplicate(true)
	tracking = false
	var damage: float = hp_before - foe.resources.current("HP")
	check(started and shot_starts == 1, id + " issues exactly one accepted real action")
	check(damage > 0 and direct_hits == 1, id + " one real direct projectile hit is recorded separately from status ticks")
	check(original_physics and original_ai and foe.is_physics_processing() and foe.ai_enabled and foe.control_mode == "ai", id + " AI and physics stay enabled")
	check(hero.loadout.level == 1, id + " ordinary mage level is unchanged")
	var fixture_valid := started and shot_starts == 1 and damage > 0 and direct_hits == 1
	if not geometry_only:
		var open_valid: bool = float(before.distance_3d) > float(before.aggro_range) and float(before.distance_3d) < 13.2 and bool(before.line_clear) and int(before_metrics.target_frames) == 0 and float(before_metrics.max_hero_displacement) < .15
		check(open_valid, id + " shot begins near 13m outside natural awareness without a prior target")
		fixture_valid = fixture_valid and open_valid
	var finding := "geometry_observation_only" if geometry_only else "awareness_observed" if int(after_metrics.target_frames) > 0 or float(after_metrics.max_memory) > 0 else "missing_damage_awareness"
	if not fixture_valid: finding = "invalid_fixture_no_behavior_conclusion"
	var result := {"case": id, "attack": attack, "geometry_only": geometry_only, "fixture_valid": fixture_valid, "finding": finding,
		"damage": damage, "hit_events": hit_events, "direct_hits": direct_hits, "direct_damage": direct_damage, "status_damage": damage - direct_damage, "hero_action_starts": shot_starts, "initial": initial, "before_shot": before, "at_shot": shot, "after_shot": after,
		"before_metrics": before_metrics, "after_metrics": after_metrics,
		"scope": "Fresh ordinary Lv1 mage/Ogre geometry; no replay of prior Lv2 damage, poise, target or movement history." if geometry_only else "Open 13m damage awareness; only starting placement and aim are fixtures."}
	cases.append(result)
	print("RANGED_CASE ", JSON.stringify(result))
	game.combat_world.aim_override = null
	game.aim_override = null
	game.world_navigation.forget(foe)
	game.combat_world.enemies.erase(foe)
	foe.queue_free()
	foe = null
	await ticks(5)

func finish() -> void:
	if finished: return
	finished = true
	tracking = false
	if watchdog != null and watchdog.timeout.is_connected(_timeout): watchdog.timeout.disconnect(_timeout)
	watchdog = null
	if is_instance_valid(app):
		app.selected_save = -1
		app.queue_free()
	await ticks(18)
	app = null
	game = null
	hero = null
	foe = null
	var report := {"probe_completed": failures.is_empty(), "checks": checks, "failures": failures, "cases": cases, "events": events, "open_pair_validation": open_pair_validation,
		"sample_count": samples.size(), "isolated": isolated, "requested_case": requested_case,
		"policy": "No behavior defect is asserted as passing. PASS checks validate fixtures/action execution only; cases.finding records observed awareness. No production changes, no AI freeze/direct damage/resource grants; only explicit starting placement and aim."}
	var file := FileAccess.open(evidence.path_join("report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	file = FileAccess.open(evidence.path_join("samples.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(samples, "\t"))
	file.close()
	print("RANGED_AWARENESS checks=%d failures=%d report=%s" % [checks, failures.size(), evidence.path_join("report.json")])
	quit(0 if failures.is_empty() else 1)
