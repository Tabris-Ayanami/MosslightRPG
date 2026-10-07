extends "res://tests/combat_feel.gd"
## Physical mouse input through InputMap; observe real action starts, emitted
## hit packets and health callbacks instead of merely inspecting the catalog.
const Attack = preload("res://combat/attack_instance.gd")
var packets: Array[Dictionary] = []
var hurts: Array[int] = []
var periods: Dictionary = {}
var foe: Node

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(3)
	player = arena.player
	foe = arena.enemies[0]
	player.combat.runner.action_started.connect(record_action)
	arena.effects.child_entered_tree.connect(func(node: Node):
		if node.get_script() == Attack and node.source == player:
			var packet: Dictionary = node.action.duplicate(true)
			packet["_frame"] = Engine.get_physics_frames()
			packets.append(packet))
	foe.health.damage_received.connect(func(amount: float):
		if amount > 0: hurts.append(Engine.get_physics_frames()))
	for family in ["SHORT_WEAPON", "SINGLE_BLADE", "POLEARM", "HEAVY_2H", "SOLDIER", "DUAL"]:
		await check_string(family)
	# The readable sword timings lengthen its old .5 s cycle; retain the actual
	# weapon identity gap without locking the new sword to that obsolete ratio.
	verify(float(periods.HEAVY_2H) > float(periods.SINGLE_BLADE) * 1.5, "greatsword's measured chain is at least 50 percent slower than the retimed sword")
	verify(float(periods.SHORT_WEAPON) < float(periods.SINGLE_BLADE) and float(periods.SINGLE_BLADE) < float(periods.POLEARM) and float(periods.POLEARM) < float(periods.HEAVY_2H), "measured mouse-input cadence orders dagger, sword, polearm, heavy weapon")
	near(periods.SOLDIER, periods.SINGLE_BLADE, "soldier keeps the single sword cadence while holding a shield", .04)
	await check_one_pending()
	await check_held_handoff()
	await check_idle_reset()
	await check_speed_modifier()
	await check_native_mouse()
	for action in InputMap.get_actions(): Input.action_release(action)
	print("COMBAT_ATTACK_CADENCE: %d checks; %d failures; observed periods %s" % [checks, failures.size(), periods])
	for failure in failures: printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)

func record_action(action: Dictionary) -> void:
	var observed := action.duplicate(true)
	observed["_observed_clock"] = player.input_router.clock
	observed["_frame"] = Engine.get_physics_frames()
	started.append(observed)

func fixture(family: String) -> void:
	foe.set_physics_process(true)
	await prepare("barbarian" if family in ["HEAVY_2H", "POLEARM"] else "warrior")
	if family == "SHORT_WEAPON": player.loadout.current_set = 1
	elif family == "POLEARM": player.loadout.equip_weapon(0, "border_spear")
	elif family == "HEAVY_2H": player.loadout.equip_weapon(0, "iron_greatsword")
	elif family == "SOLDIER":
		player.loadout.set_level(2)
		player.loadout.select_career("soldier")
	elif family == "DUAL":
		player.loadout.set_level(2)
		player.loadout.select_career("swordsman")
		player.loadout.set_level(10)
		player.loadout.select_career("dual_swordsman")
	foe.resources.configure("HP", 1000000)
	# Dagger reach now matches the short blade. Range boundaries are separately
	# exercised by melee_family_motion; this fixture measures connected cadence.
	foe.global_position = player.global_position + Vector3.FORWARD * (.95 if family == "SHORT_WEAPON" else 1.45)
	foe.facing = Vector3.FORWARD
	foe.set_physics_process(false)
	await ticks(2)
	started.clear()
	packets.clear()
	hurts.clear()

func total(action: Dictionary) -> float:
	return float(action.startup) + float(action.active) + float(action.recovery)

func legal_interval(action: Dictionary) -> float:
	return total(action) - minf(float(action.get("combo_window", .08)), float(action.recovery) * .35)

func check_string(family: String) -> void:
	await fixture(family)
	var count: int = arena.database.get_combo_count(player.loadout.combat_weapon().animation_family)
	var clicks := 0
	while started.size() < count + 1 and clicks < 180:
		await tap_mouse()
		clicks += 1
	await ticks(150)
	verify(started.size() >= count + 1, family + " physical rapid clicks produce a complete combo and restart")
	if started.size() < count + 1: return
	var order_ok := true
	var pace_ok := true
	for i in range(started.size()):
		order_ok = order_ok and int(started[i].combo_index) == i % count
		if i > 0:
			var elapsed := float(started[i]._observed_clock) - float(started[i - 1]._observed_clock)
			pace_ok = pace_ok and elapsed + .018 >= legal_interval(started[i - 1])
	verify(order_ok, family + " emits ordered combo stages and wraps, not repeated stage one")
	verify(pace_ok, family + " no click bypasses the action's recovery gate")
	verify(started.size() <= count + 2, family + " stopping input leaves at most one reserved follow-up")
	var strikes := 2 if family == "DUAL" else 1
	verify(packets.size() == started.size() * strikes and hurts.size() == packets.size(), family + " each declared strike creates one actual packet and one health callback")
	if family == "DUAL":
		var pairs_ok := true
		for i in range(0, packets.size(), 2):
			pairs_ok = pairs_ok and int(packets[i].dual_weapon_index) == 1 and int(packets[i + 1].dual_weapon_index) == 0 and int(packets[i + 1]._frame) > int(packets[i]._frame)
		verify(pairs_ok, "dual blades alternate left then right with separate timed hits")
	periods[family] = (float(started[count]._observed_clock) - float(started[0]._observed_clock)) / count
	print("CADENCE ", family, " average interval=", periods[family], " starts=", started.size(), " packets=", packets.size(), " mouse clicks=", clicks)

func check_one_pending() -> void:
	await fixture("HEAVY_2H")
	await tap_mouse()
	for i in range(4): await tap_mouse()
	verify(player.input_router.buffer.entries.size() == 1, "repeated clicks during wind-up reserve only one next swing")
	await ticks(170)
	verify(started.size() == 2 and packets.size() == 2, "four extra clicks during one wind-up produce exactly one follow-up")
	await fixture("HEAVY_2H")
	await tap_mouse()
	await tap_mouse()
	player.combat.force_control("HITSTUN", .3)
	await ticks(130)
	verify(started.size() == 1 and player.input_router.buffer.entries.is_empty(), "hit interruption discards the reserved weapon input")

func check_held_handoff() -> void:
	await fixture("HEAVY_2H")
	await tap_mouse()
	await wait_phase("ACTIVE")
	var first: Dictionary = started[0]
	mouse(MOUSE_BUTTON_LEFT, true)
	for i in range(100):
		if player.combat.state == "CHARGING": break
		await ticks(1)
	var elapsed: float = player.input_router.clock - float(first._observed_clock)
	verify(player.combat.state == "CHARGING" and elapsed + .018 >= legal_interval(first), "holding during a heavy swing cannot use the earlier skill-cancel recovery gate")
	verify(player.combat.charge_time <= .04, "waiting through the previous swing grants no free charge progress")
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(3)
	verify(started.size() == 2 and started[1].semantic == "PRIMARY_TAP" and int(started[1].combo_index) == 1, "immediate release after the legal handoff continues combo without a free charged attack")

func check_idle_reset() -> void:
	await fixture("HEAVY_2H")
	await tap_mouse()
	while player.combat.runner.busy(): await ticks(1)
	await ticks(12)
	await tap_mouse()
	verify(started.size() == 2 and int(started[1].combo_index) == 1, "a slow attack retains its next combo after recovery and a short pause")
	while player.combat.runner.busy(): await ticks(1)
	await ticks(55)
	await tap_mouse()
	verify(started.size() == 3 and int(started[2].combo_index) == 0, "an intentional longer pause resets the combo to its first stage")

func check_speed_modifier() -> void:
	await fixture("HEAVY_2H")
	player.combat.statuses.add_status("cadence_haste", {"duration": 10, "effects": [{"type": "modifier", "stat": "action_speed_multiplier", "value": .5}]})
	for i in range(24): await tap_mouse()
	await ticks(180)
	var base: Dictionary = arena.database.get_action("HEAVY_2H", "PRIMARY_TAP", 0)
	near(total(started[0]), total(base) / 1.5, "attack speed scales complete action duration")
	near(started[0].combo_window, float(base.combo_window) / 1.5, "attack speed scales the legal handoff window with animation time")
	var gated := true
	for i in range(1, started.size()):
		gated = gated and float(started[i]._observed_clock) - float(started[i - 1]._observed_clock) + .018 >= legal_interval(started[i - 1])
	verify(gated, "haste preserves cadence gates under physical mouse spam")

func check_native_mouse() -> void:
	await fixture("SINGLE_BLADE")
	# Possession uses the exact same input router and controller as the hero.
	var identity: Node = player
	verify(arena.control.possess(foe, 30), "possess a soldier for actual mouse combo verification")
	player = foe
	player.set_physics_process(true)
	player.combat.runner.action_started.connect(record_action)
	started.clear()
	for i in range(30): await tap_mouse()
	await ticks(100)
	var ordered := started.size() >= 4
	var paced := ordered
	for i in range(started.size()):
		ordered = ordered and int(started[i].get("combo_index", -1)) == i % 3
		if i > 0: paced = paced and float(started[i]._observed_clock) - float(started[i - 1]._observed_clock) + .018 >= legal_interval(started[i - 1])
	verify(ordered and paced, "possessed soldier mouse spam uses the same three-stage sequence and recovery enforcement")
	arena.control.release()
	player = identity
