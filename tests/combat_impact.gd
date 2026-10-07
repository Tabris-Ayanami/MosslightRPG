extends "res://tests/combat_feel.gd"
const Impact = preload("res://combat/impact_feedback.gd")
const Motion = preload("res://combat/melee_motion.gd")
var foe: Node
var hits := 0
var observations: Array[Dictionary] = []
class Probe extends Node:
	var test: SceneTree
	func _physics_process(_delta: float) -> void:
		var p: Node = test.player
		if is_instance_valid(p):
			test.observations.append({"clock": p.input_router.clock, "time": p.combat.runner.action_time, "stop": p.combat.hitstop_remaining, "frozen": p.combat.stopped_this_tick, "position": p.global_position, "phase": p.combat.runner.action_phase, "clip": p.animation.skeletal_clip, "sample": p.animation.skeletal_time})

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(4)
	player = arena.player
	foe = arena.enemies[0]
	player.combat.runner.action_started.connect(record_action)
	foe.health.damage_received.connect(func(amount: float):
		if amount > 0.0: hits += 1)
	var probe := Probe.new()
	probe.test = self
	probe.process_physics_priority = 100
	root.add_child(probe)
	await fixture()
	await tap_mouse()
	await ticks(70)
	verify(hits == 1, "one real mouse tap produces exactly one contact through extended active frames")
	var frozen := 0
	var stable := true
	for i in range(1, observations.size()):
		var now := observations[i]
		var before := observations[i - 1]
		if now.frozen and now.stop > .0001 and before.phase == "ACTIVE":
			frozen += 1
			stable = stable and is_equal_approx(now.time, before.time) and now.position.is_equal_approx(before.position) and is_equal_approx(now.sample, before.sample) and now.clock > before.clock
	verify(frozen >= 1 and stable, "contact freezes action, skeleton and movement while input clock continues")
	verify(foe.combat.state not in ["HITSTUN", "KNOCKDOWN"], "ordinary contact reaction does not create a poise break or interrupt")
	verify(is_equal_approx(Engine.time_scale, 1.0), "global simulation and rendering time scale remains one")
	await fixture()
	foe.global_position += Vector3.RIGHT * 8
	await tap_mouse()
	await ticks(60)
	verify(hits == 0 and observations.all(func(row: Dictionary): return row.stop == 0), "empty swing never freezes")
	await fixture()
	await tap_mouse()
	await wait_phase("ACTIVE")
	await tap_mouse()
	await ticks(120)
	verify(started.size() == 2 and hits == 2 and int(started[1].combo_index) == 1, "a click during contact reserves one next blade and never an extra swing")
	await fixture()
	await tap_mouse()
	await wait_phase("ACTIVE")
	key(KEY_SPACE, true)
	await ticks(1)
	key(KEY_SPACE, false)
	await ticks(10)
	verify(player.combat.state == "DODGE" or player.combat.dodge_time > 0.0, "dodge pressed during hitstop is executed in the legal recovery window")
	await fixture()
	var action: Dictionary = arena.database.get_action("SINGLE_BLADE", "PRIMARY_TAP", 0)
	var guard := {"final": 0.0, "defense": "block"}
	Impact.deliver(foe, player, action, Vector3.FORWARD, guard, false)
	near(player.combat.hitstop_remaining, .04, "fully guarded contact has its own short stop")
	player.combat.clear_hitstop()
	foe.combat.clear_hitstop()
	Impact.deliver(foe, player, action, Vector3.FORWARD, {"final": 10.0}, true)
	verify(player.combat.hitstop_remaining == 0 and foe.combat.hitstop_remaining == 0, "damage over time cannot freeze either participant")
	var projectile := action.duplicate(true)
	projectile["projectile_speed"] = 10.0
	Impact.deliver(foe, player, projectile, Vector3.FORWARD, {"final": 10.0}, false)
	verify(player.combat.hitstop_remaining == 0, "projectile hits do not freeze the distant shooter")
	foe.is_boss = true
	Impact.deliver(foe, player, action, Vector3.FORWARD, {"final": 10.0}, false)
	verify(foe.combat.hitstop_remaining == 0 and foe.combat.state == "NORMAL", "boss contact presentation preserves its control and action clock")
	foe.is_boss = false
	var first_stop: float = player.combat.hitstop_remaining
	arena.enemies[1].global_position = player.global_position + Vector3.FORWARD * 1.3
	Impact.deliver(arena.enemies[1], player, action, Vector3.FORWARD, {"final": 10.0}, false)
	near(player.combat.hitstop_remaining, first_stop, "multiple targets take the maximum stop, without addition")
	player.combat.reset()
	verify(player.combat.hitstop_remaining == 0, "reset clears transient hitstop")
	for i in range(3):
		action = arena.database.get_action("SINGLE_BLADE", "PRIMARY_TAP", i)
		verify(Motion.error_for(action).is_empty(), "sword %d source and recovery markers fit the actual shipped resources" % i)
		var sample := Motion.sample(action, "ACTIVE", 0)
		player.animation.play_action(action)
		player.animation.rotation.y = 0.0
		player.animation.update_pose(0, Vector3.FORWARD, "ACTION", "ACTIVE", 0)
		var tip: Vector3 = player.animation.to_local(player.animation._weapon.to_global(Vector3(0, 0, -1.05)))
		verify(tip.z < -.7 and absf(tip.x) < .55 and player.animation.hand_attachment_error < .001, "sword %d blade passes the frontal target at the damage marker with its grip attached" % i)
		verify(player.animation.skeletal_clip == sample.clip and absf(player.animation.skeletal_time - float(sample.time)) < .001, "sword %d visual samples its calibrated contact" % i)
	var broken := action.duplicate(true)
	broken.motion.contact = 5.0
	verify(not Motion.error_for(broken).is_empty(), "runtime rejects an out-of-range authored contact")
	probe.queue_free()
	for action_id in InputMap.get_actions(): Input.action_release(action_id)
	print("COMBAT_IMPACT ", JSON.stringify({"checks": checks, "failures": failures, "frozen_observations": frozen}))
	arena.queue_free()
	await ticks(4)
	quit(0 if failures.is_empty() else 1)

func fixture() -> void:
	await prepare()
	foe.resources.configure("HP", 100000)
	foe.global_position = player.global_position + Vector3.FORWARD * 1.4
	foe.facing = Vector3.FORWARD
	foe.combat.base_poise = 100000
	foe.combat.current_poise = 100000
	await ticks(3)
	hits = 0
	observations.clear()
