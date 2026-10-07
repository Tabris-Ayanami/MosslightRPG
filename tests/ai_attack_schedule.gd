extends SceneTree
## Real brain/controller scheduling at fixed 60 Hz, without a rendered window.
const Preferences = preload("res://rpg/game_preferences.gd")
const Definition = preload("res://combat/unit_definition.gd")
const STEP := 1.0 / 60.0
var arena: Node
var clock := 0.0
var started: Array[Dictionary] = []
var checks := 0
var failures: Array[String] = []
var max_pending := 0

func _initialize() -> void:
	Preferences.settings_path = OS.get_environment("TEMP").path_join("mosslight-ai-schedule-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func prepare(id: String, distance := 1.8) -> Node:
	for old in arena.enemies:
		old.ai_enabled = false
		old.set_physics_process(false)
		old.global_position = Vector3(100, .1, 100)
	arena.player.combat.reset()
	arena.player.combat.statuses.add_status("invulnerable", {"duration": -1.0, "effects": []})
	arena.player.global_position = Vector3(0, .1, 6)
	var enemy: Node = arena.spawn_enemy(id, arena.player.global_position + Vector3.FORWARD * distance)
	enemy.set_physics_process(false)
	enemy.ai_enabled = true
	enemy.ai_cooldown = 0.0
	enemy.facing = Vector3.BACK
	clock = 0.0
	started.clear()
	max_pending = 0
	enemy.combat.runner.action_started.connect(func(action: Dictionary):
		started.append({"id": str(action.id), "time": snappedf(clock, .001),
			"distance": enemy.global_position.distance_to(arena.player.global_position),
			"paid": action.get("paid_costs", {}).duplicate(true)}))
	return enemy

func simulate(enemy: Node, seconds: float, move := false) -> void:
	for frame in range(roundi(seconds / STEP)):
		enemy.move_direction = Vector3.ZERO
		enemy.combat.tick(STEP)
		enemy._tick_ai(STEP)
		max_pending = maxi(max_pending, enemy.brain._pending_skills.size())
		if move and enemy.combat.state in ["NORMAL", "MOVE"]:
			enemy.global_position += enemy.move_direction * enemy.move_speed * STEP
		clock += STEP

func ids() -> Array[String]:
	var result: Array[String] = []
	for event in started: result.append(event.id)
	return result

func special(id: String, every: int, costs: Dictionary = {}) -> Dictionary:
	return {"id": id, "name": id, "is_skill": true, "presentation_type": "WEAPON_ACTION",
		"animation_family": "SINGLE_BLADE", "targeting": "SELF", "range": 3.0,
		"startup": .1, "active": .1, "recovery": .1, "cooldown": 0.0,
		"costs": costs, "formula": {}, "conditions": [], "effects": [], "ai_attack_every": every}

func check_complete_primary_and_grab() -> void:
	var enemy := prepare("ogre")
	simulate(enemy, 30)
	var expected := ["ogre_attack", "ogre_attack_2", "ogre_slam_3", "ogre_grab"]
	verify(started.size() >= 8, "ogre completes at least two primary-plus-grab cycles")
	for i in range(mini(8, started.size())):
		verify(started[i].id == expected[i % 4], "ogre schedule position %d keeps all three primary swings before grab" % i)
	verify(max_pending <= 3, "periodic requests never exceed the three skill slots")
	verify(float(started[3].time) >= float(started[2].time) + .82 + .24 + .85,
		"deferred grab starts after the real third swing's full recovery")
	print("OGRE_SCHEDULE ", JSON.stringify(started))

func check_ordinary_and_single_swing() -> void:
	var enemy := prepare("soldier")
	simulate(enemy, 8)
	var expected := ["soldier_attack", "soldier_attack_2", "soldier_attack_3"]
	verify(started.size() >= 6, "no-skill soldier continues complete strings")
	for i in range(mini(6, started.size())):
		verify(started[i].id == expected[i % 3], "ordinary soldier swing %d is unchanged" % i)
	verify(absf(float(started[3].time) - 3.5) < .04, "soldier retains its original inter-string cooldown")
	enemy = prepare("heavy_guard")
	enemy.innate_skills.assign([special("single_special", 2)])
	simulate(enemy, 14)
	verify(ids().slice(0, 4) == ["heavy_guard_attack", "single_special", "heavy_guard_attack", "single_special"],
		"single-swing primary alternates normally with a due special")

func check_generic_due_and_fairness() -> void:
	var enemy := prepare("soldier")
	enemy.innate_skills.assign([special("periodic", 2)])
	simulate(enemy, 14)
	verify(ids().slice(0, 4) == ["soldier_attack", "soldier_attack_2", "soldier_attack_3", "periodic"],
		"generic every-two request survives until the entire primary string finishes")
	verify(ids().count("periodic") >= 2, "generic request is scheduled again after being consumed")
	enemy = prepare("soldier")
	enemy.innate_skills.assign([special("frequent_a", 1), special("frequent_b", 1), special("frequent_c", 1)])
	simulate(enemy, 30)
	for id in ["frequent_a", "frequent_b", "frequent_c"]:
		verify(id in ids(), "bounded pending queue eventually serves " + id)
	verify(ids().count("soldier_attack_3") >= 3, "every-one skills cannot starve complete primary strings")
	verify(max_pending <= 3, "unavailable or repeated due requests remain bounded")
	var primary_since := 3
	var alternates := true
	for id in ids():
		if id.begins_with("frequent_"):
			alternates = alternates and primary_since >= 3
			primary_since = 0
		else: primary_since += 1
	verify(alternates, "at most one special occurs between complete primary strings")

func check_cost_failure_and_later_payment() -> void:
	var enemy := prepare("ogre")
	enemy.innate_skills[0]["costs"] = {"Energy": 5.0}
	enemy.resources.configure("Energy", 0)
	simulate(enemy, 10)
	verify("ogre_grab" not in ids() and ids().count("ogre_slam_3") >= 2,
		"unpayable grab falls back to complete primary strings")
	verify(enemy.brain._pending_skills.filter(func(entry: Dictionary): return entry.id == "ogre_grab").size() == 1, "unpayable grab keeps exactly one pending request")
	enemy.resources.configure("Energy", 10)
	simulate(enemy, 12)
	verify("ogre_grab" in ids(), "pending grab executes after its resource becomes available")
	var paid_once := false
	for event in started:
		if event.id == "ogre_grab": paid_once = is_equal_approx(float(event.paid.get("Energy", -1)), 5.0)
	verify(paid_once, "the controller pays the deferred grab's real Energy cost")

func check_out_of_range_approach() -> void:
	var enemy := prepare("ogre", 3.0)
	simulate(enemy, 6.7)
	verify(ids().slice(0, 3) == ["ogre_attack", "ogre_attack_2", "ogre_slam_3"] and "ogre_grab" not in ids(),
		"longer ordinary reach does not start the deferred grab outside its own range")
	verify(enemy.move_direction.length() > .1 and enemy.brain._pending_skills.filter(func(entry: Dictionary): return entry.id == "ogre_grab").size() == 1,
		"out-of-range grab remains pending and requests approach instead of disappearing")
	simulate(enemy, 2, true)
	verify("ogre_grab" in ids(), "real brain approaches and eventually starts deferred grab")
	for event in started:
		if event.id == "ogre_grab": verify(float(event.distance) <= 2.6 * .8 + .03, "grab begins at its own engagement distance")

func check_stale_slots_and_forms() -> void:
	var enemy := prepare("soldier")
	enemy.innate_skills.assign([special("old_form_skill", 2)])
	simulate(enemy, .8)
	verify(enemy.brain._pending_skills.size() == 1, "fixture queues a special in the middle of a primary string")
	enemy.innate_skills.assign([special("new_form_skill", 1)])
	simulate(enemy, 8)
	verify("old_form_skill" not in ids() and "new_form_skill" in ids(), "changed slot identity drops the former skill and schedules its replacement")
	enemy = prepare("ogre")
	simulate(enemy, 3)
	verify(enemy.brain._pending_skills.filter(func(entry: Dictionary): return entry.id == "ogre_grab").size() == 1, "ogre holds a deferred grab while third swing is active")
	enemy.apply_definition(Definition.for_enemy(arena.database, "soldier"), true)
	enemy.combat.reset()
	simulate(enemy, 8)
	verify("ogre_grab" not in ids() and "soldier_attack_3" in ids(), "changing the real unit definition discards former body's pending grab")
	verify(enemy.brain._pending_skills.is_empty(), "new skill-free form has no stale pending slots")

func check_skill_only_and_disabled() -> void:
	var enemy := prepare("soldier")
	enemy.innate_actions = {"SECONDARY_TAP": enemy.action_for("PRIMARY_TAP")}
	enemy.innate_skills.assign([special("only_special", 1)])
	simulate(enemy, 8)
	verify(ids().size() >= 3 and ids().count("only_special") == ids().size(), "skill-only unit is not trapped waiting for a nonexistent primary string")
	enemy = prepare("soldier")
	enemy.innate_actions = {"SECONDARY_TAP": enemy.action_for("PRIMARY_TAP")}
	enemy.innate_skills.assign([special("unpayable_old", 1, {"Energy": 5})])
	enemy.resources.configure("Energy", 0)
	simulate(enemy, 1)
	verify(started.is_empty() and enemy.brain._pending_skills.size() == 1, "skill-only fixture waits on its unavailable request")
	enemy.innate_skills.assign([special("replacement_only", 1)])
	simulate(enemy, 1)
	verify(ids() == ["replacement_only"], "skill-only replacement is rescheduled even when no attack counter advanced")
	enemy = prepare("soldier")
	enemy.innate_skills.assign([special("disabled_special", 0)])
	simulate(enemy, 8)
	verify("disabled_special" not in ids() and "soldier_attack_3" in ids(), "zero cadence disables the special without changing ordinary attacks")

func check_ranged_response() -> void:
	var enemy := prepare("ogre", 8.0)
	simulate(enemy, 14)
	verify(ids().size() >= 3 and ids().count("ogre_stone_throw") == ids().size(), "visible ranged target receives repeated throws without requiring an unreachable melee string")
	var cooldown_honored := true
	for index in range(1, started.size()):
		cooldown_honored = cooldown_honored and float(started[index].time) - float(started[index - 1].time) >= 6.0 - STEP
	verify(cooldown_honored, "ranged response pays the real six-second cooldown")
	verify(max_pending <= 3 and enemy.brain._pending_skills.filter(func(entry: Dictionary): return entry.id == "ogre_grab").size() == 1, "ranged response preserves a single due grab without growing the queue")
	enemy.global_position = arena.player.global_position + Vector3.FORWARD * 1.8
	var at := started.size()
	simulate(enemy, 12)
	verify(ids().slice(at, at + 4) == ["ogre_attack", "ogre_attack_2", "ogre_slam_3", "ogre_grab"], "returning to melee restores the complete string and deferred grab")
	enemy = prepare("ogre", 8.0)
	enemy.innate_skills[1]["costs"] = {"Energy": 5}
	enemy.resources.configure("Energy", 0)
	simulate(enemy, 2)
	verify(started.is_empty() and enemy.move_direction.length() > .1, "unpayable ranged ability falls back to approach without free attacks")
	enemy.resources.configure("Energy", 5)
	simulate(enemy, .1)
	verify(ids() == ["ogre_stone_throw"] and is_equal_approx(float(started[0].paid.get("Energy", 0)), 5.0), "ranged selection uses the normal slot payment path")
	enemy = prepare("ogre", 8.0)
	enemy.innate_skills[1]["ai_attack_every"] = 0
	simulate(enemy, 8)
	verify(started.is_empty() and enemy.move_direction.length() > .1, "zero cadence disables both periodic and ranged selection")
	enemy = prepare("ogre", 8.0)
	enemy.innate_skills[1].erase("ai_use_at_range")
	enemy.innate_skills[1]["ai_attack_every"] = 3
	simulate(enemy, 8)
	verify(started.is_empty() and enemy.move_direction.length() > .1, "unmarked projectiles retain their normal attack-count cadence")
	enemy = prepare("ogre", 4.5)
	simulate(enemy, 3)
	verify(started.is_empty() and enemy.move_direction.length() > .1, "AI minimum range leaves the near band to melee approach")
	enemy = prepare("ogre", 16.0)
	simulate(enemy, 3)
	verify(started.is_empty(), "ranged response never bypasses normal sight acquisition")
	enemy = prepare("ogre", 8.0)
	enemy.innate_skills[1]["conditions"] = [{"type":"self_hp","op":"<","value":.1}]
	simulate(enemy, 2)
	verify(started.is_empty() and enemy.move_direction.length() > .1, "ranged response honors conditions as well as cost and cooldown")

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await process_frame
	await physics_frame
	arena.set_physics_process(false)
	arena.input_blocked = false
	arena.player.set_physics_process(false)
	arena.player.loadout.select_career("warrior")
	check_complete_primary_and_grab()
	check_ordinary_and_single_swing()
	check_generic_due_and_fairness()
	check_cost_failure_and_later_payment()
	check_out_of_range_approach()
	check_stale_slots_and_forms()
	check_skill_only_and_disabled()
	check_ranged_response()
	print("AI_ATTACK_SCHEDULE: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures: printerr("FAIL: ", failure)
	arena.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
