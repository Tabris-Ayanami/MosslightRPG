extends "res://tests/combat_defense.gd"
## Real InputMap events, real AttackInstance packets, and independent health
## callbacks verify the two blades. Catalog advancement matrices live separately.

var strike_packets: Array[Dictionary] = []
var outgoing_results: Array[Dictionary] = []
var hurt_events: Array[Dictionary] = []
var skill_events: Array[String] = []
var stamina_paid := 0.0
var _last_stamina := 0.0

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(3)
	if not is_instance_valid(arena.get("player")) or not is_instance_valid(arena.get("ui")):
		printerr("COMBAT_DUAL_WIELD: arena initialization failed")
		quit(1)
		return
	player = arena.player
	player.combat.runner.action_started.connect(record_parent)
	player.combat.damage_dealt.connect(func(result: Dictionary): outgoing_results.append(result.duplicate(true)))
	player.combat.skill_used.connect(func(id: String): skill_events.append(id))
	player.resources.resource_changed.connect(record_resource)
	arena.enemies[0].health.damage_received.connect(func(amount: float):
		if amount > 0.0:
			hurt_events.append({"amount": amount, "frame": Engine.get_physics_frames()}))
	arena.effects.child_entered_tree.connect(record_packet)
	await prepare_dual()
	verify(player.loadout.level == 10 and player.loadout.is_dual_wielding(), "real warrior-to-swordsman progression reaches dual wield at level ten")
	verify(player.loadout.weapon_at(0).id != player.loadout.weapon_at(1).id, "dual fixture equips two distinct sword definitions in A and B")
	await check_weapon_inputs()
	await check_parent_payment()
	await check_snapshot_passives()
	await check_interruptions()
	await check_shift_and_skills()
	await check_queued_skill_group_snapshot()
	await check_shared_dodge_passive()
	await check_thrust_displacement()
	await check_skill_effects_and_gates()
	await check_invalid_second_sword_gate()
	await check_skill_interruptions()
	await check_projectile_interruptions()
	await check_ordinary_skills()
	for action in InputMap.get_actions():
		Input.action_release(action)
	print("COMBAT_DUAL_WIELD: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures:
		printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)

func record_parent(action: Dictionary) -> void:
	var observed := action.duplicate(true)
	observed["_frame"] = Engine.get_physics_frames()
	started.append(observed)

func parent_elapsed() -> float:
	return float(Engine.get_physics_frames() - int(started[-1]._frame)) / 60.0

func record_resource(id: String, current: float, _maximum: float) -> void:
	if id == "Stamina":
		stamina_paid += maxf(0.0, _last_stamina - current)
		_last_stamina = current

func record_packet(node: Node) -> void:
	if node.get_script() != Attack or node.source != player:
		return
	var observed: Dictionary = node.action.duplicate(true)
	observed["_frame"] = Engine.get_physics_frames()
	observed["_action_time"] = player.combat.runner.action_time
	observed["_origin"] = node.origin
	observed["_actor_position"] = player.global_position
	strike_packets.append(observed)

func clear_observations() -> void:
	strike_packets.clear()
	outgoing_results.clear()
	hurt_events.clear()
	skill_events.clear()
	started.clear()
	stamina_paid = 0.0
	_last_stamina = player.resources.current("Stamina")

func prepare_dual() -> void:
	await prepare("warrior")
	player.loadout.set_level(2)
	player.loadout.select_career("swordsman")
	player.loadout.set_level(10)
	player.loadout.select_career("dual_swordsman")
	# Calibrated blade reach replaces the old 2.8m cone.
	foe.global_position = player.global_position + Vector3.FORWARD * 1.4
	foe.facing = Vector3.BACK
	await ticks(2)
	clear_observations()

func weapon_input(semantic: String) -> void:
	var button := MOUSE_BUTTON_LEFT if semantic.begins_with("PRIMARY") else MOUSE_BUTTON_RIGHT
	mouse(button, true)
	await ticks(50 if semantic.ends_with("CHARGE") else 2)
	mouse(button, false)
	await ticks(2)

func wait_hurts(count: int, budget := 100) -> void:
	for i in range(budget):
		if hurt_events.size() >= count:
			return
		await ticks(1)

func wait_packets(count: int, budget := 100) -> void:
	for i in range(budget):
		if strike_packets.size() >= count:
			return
		await ticks(1)

func check_pair(label: String) -> void:
	verify(strike_packets.size() == 2 and hurt_events.size() == 2, label + " creates two actual attack packets and two independent hurt callbacks")
	if strike_packets.size() != 2:
		return
	verify(int(strike_packets[0].get("dual_strike_index", -1)) == 0 and int(strike_packets[1].get("dual_strike_index", -1)) == 1, label + " has two ordered attack stages")
	verify(int(strike_packets[0].get("dual_weapon_index", -1)) == 1 and int(strike_packets[1].get("dual_weapon_index", -1)) == 0, label + " attacks with the left B sword before the right A sword")
	verify(strike_packets[0].weapon_snapshot.id == player.loadout.weapon_at(1).id and strike_packets[1].weapon_snapshot.id == player.loadout.weapon_at(0).id, label + " each blade carries its corresponding weapon snapshot")
	verify(strike_packets[0].instance_id != strike_packets[1].instance_id and strike_packets[0].parent_instance_id == strike_packets[1].parent_instance_id, label + " uses separate hit identities under one cancellable parent")
	var gap := float(int(strike_packets[1]._frame) - int(strike_packets[0]._frame)) / 60.0
	var expected_gap := .10
	if strike_packets[0].get("is_skill", false):
		expected_gap = .24 if strike_packets[0].get("dual_sequence", {}).get("template", "") == "spin" else .14
	near(float(strike_packets[1]._action_time) - float(strike_packets[0]._action_time), expected_gap, label + " preserves its weapon or skill interval on the local action clock", .02)
	verify(gap + .02 >= expected_gap and gap <= expected_gap + .16, label + " wall-clock interval also includes the bounded contact stop")
	if outgoing_results.size() == 2:
		for i in range(2):
			var formula: Dictionary = strike_packets[i].formula
			var expected_raw := float(formula.get("base", 0.0)) + float(player.loadout.weapon_at(1 - i).weapon_scaling) * float(formula.get("weapon", 0.0))
			for stat in ["STR", "DEX", "CON", "INT", "PER", "CHA"]:
				expected_raw += player.stats.get_final_stat(stat) * float(formula.get(stat, 0.0))
			near(float(outgoing_results[i].raw), expected_raw, label + " attack %d deals its own sword's actual formula damage" % i)
	print("DUAL_STRIKE_TRACE ", JSON.stringify({"semantic": label, "gap": gap,
		"weapons": [strike_packets[0].weapon_snapshot.id, strike_packets[1].weapon_snapshot.id], "hurts": hurt_events}))

func check_weapon_inputs() -> void:
	for semantic in ["PRIMARY_TAP", "SECONDARY_TAP", "PRIMARY_CHARGE", "SECONDARY_CHARGE"]:
		await prepare_dual()
		var stamina: float = player.resources.current("Stamina")
		await weapon_input(semantic)
		await wait_hurts(2)
		check_pair(semantic)
		verify(started.size() == 1 and started[0].get("dual_wield", false), semantic + " has one paid parent action for its two blades")
		verify(skill_events.is_empty(), semantic + " does not emit an active-skill event")
		var expected_cost := 1.0 if semantic.ends_with("CHARGE") else 0.0
		near(stamina_paid, expected_cost, semantic + " pays its weapon resource cost once")
		near(player.resources.current("Stamina"), stamina - expected_cost, semantic + " second blade consumes no extra stamina")
		await ticks(55)
		verify(strike_packets.size() == 2 and hurt_events.size() == 2, semantic + " cannot repeat either blade during late recovery")

func check_parent_payment() -> void:
	await prepare_dual()
	var id := "single_blade_primary_charge_1"
	var original: Dictionary = arena.database.actions[id].duplicate(true)
	arena.database.actions[id]["cooldown"] = 2.0
	arena.database.actions[id]["gains"] = {"Energy": 20}
	player.resources.change("Energy", -40)
	var energy: float = player.resources.current("Energy")
	await weapon_input("PRIMARY_CHARGE")
	await wait_hurts(2)
	near(player.resources.current("Energy"), energy + 20, "two-blade parent applies its resource gain once")
	near(stamina_paid, 1, "two-blade parent applies its declared stamina payment once")
	near(float(player.combat.cooldowns.get(id, 0)), maxf(0.0, 2.0 - parent_elapsed()), "second blade does not restart the parent's cooldown", .02)
	verify(skill_events.is_empty() and started.size() == 1, "follow-up blade starts neither a second action charge nor a skill event")
	arena.database.actions[id] = original
	arena.database._index_actions()

func check_snapshot_passives() -> void:
	await prepare_dual()
	var a_id: String = player.loadout.weapon_at(0).id
	var b_id: String = player.loadout.weapon_at(1).id
	var a_original: Dictionary = arena.database.weapons[a_id].duplicate(true)
	var b_original: Dictionary = arena.database.weapons[b_id].duplicate(true)
	var action_id := "single_blade_primary_tap_1"
	var action_original: Dictionary = arena.database.actions[action_id].duplicate(true)
	arena.database.actions[action_id]["can_crit"] = false
	for entry in [[a_id, .25, 1], [b_id, .60, 2]]:
		arena.database.weapons[entry[0]]["special_effects"] = [
			{"id": "dual_test_bonus_" + str(entry[0]), "event": "damage_before", "conditions": [], "effects": [{"type": "modifier", "stat": "damage_bonus", "value": entry[1]}]},
			{"id": "dual_test_gain_" + str(entry[0]), "event": "damage_after", "conditions": [], "effects": [{"type": "resource", "resource": "Energy", "amount": entry[2] * 20}]}]
	player.resources.change("Energy", -100)
	var energy: float = player.resources.current("Energy")
	await weapon_input("PRIMARY_TAP")
	await wait_hurts(1)
	verify(strike_packets.size() == 1 and hurt_events.size() == 1, "left B blade lands independently before the delayed right A blade")
	# Editing the live catalog between strikes must not alter the parent's captured A.
	arena.database.weapons[a_id]["weapon_scaling"] = 999
	arena.database.weapons[a_id]["special_effects"] = []
	await wait_hurts(2)
	verify(outgoing_results.size() == 2 and strike_packets.size() == 2, "both distinct snapshot-driven hits reach real damage resolution")
	if outgoing_results.size() == 2 and strike_packets.size() == 2:
		near(float(strike_packets[1].weapon_snapshot.weapon_scaling), float(a_original.weapon_scaling), "A keeps its original scaling despite an intervening live-catalog edit")
		var armor_factor: float = 100.0 / (100.0 + foe.stats.get_final_stat("Armor"))
		near(float(outgoing_results[0].final), float(outgoing_results[0].raw) * 1.60 * armor_factor, "B applies only the B weapon damage passive")
		near(float(outgoing_results[1].final), float(outgoing_results[1].raw) * 1.25 * armor_factor, "A applies only its captured A weapon damage passive")
		var raw_delta := float(outgoing_results[1].raw) - float(outgoing_results[0].raw)
		near(raw_delta, (float(a_original.weapon_scaling) - float(b_original.weapon_scaling)) * float(strike_packets[0].formula.weapon), "the two raw damages differ by their own weapon scaling")
	near(player.resources.current("Energy"), energy + 60, "each blade triggers only its own on-hit weapon resource effect once")
	arena.database.weapons[a_id] = a_original
	arena.database.weapons[b_id] = b_original
	arena.database.actions[action_id] = action_original
	arena.database._index_actions()

func check_interruptions() -> void:
	for interruption in ["stun", "death", "grab"]:
		await prepare_dual()
		await weapon_input("PRIMARY_TAP")
		await wait_hurts(1)
		verify(strike_packets.size() == 1, interruption + " scenario interrupts after left B and before right A")
		var incoming := {"formula": {"base": 99999 if interruption == "death" else 1}, "poise_damage": 999 if interruption == "stun" else 0}
		if interruption == "grab":
			incoming.merge({"attack_kind": "GRAB", "blockable": false, "grab_duration": 1.0}, true)
		impact(incoming)
		var expected_state: String = {"stun": "HITSTUN", "death": "DEAD", "grab": "GRABBED"}[interruption]
		verify(player.combat.state == expected_state, "real incoming " + interruption + " cancels the dual parent action")
		await ticks(60)
		verify(strike_packets.size() == 1 and hurt_events.size() == 1, interruption + " prevents the delayed right A attack and any ghost damage")
	await prepare_dual()
	var old_shield: Dictionary = foe.enemy_shield.duplicate(true)
	foe.enemy_shield = arena.database.weapons.wooden_shield.duplicate(true)
	await weapon_input("PRIMARY_TAP")
	foe.combat.defense.start_guard(true)
	await ticks(35)
	verify(foe.combat.defense.last_outcome == "parry", "enemy's actual precise shield window parries the first blade")
	verify(strike_packets.size() == 1 and hurt_events.is_empty(), "first-blade parry cancels right A before it can spawn or hurt")
	verify(not player.combat.runner.busy(), "first-blade parry cancels the shared dual action runner")
	foe.enemy_shield = old_shield

func check_shift_and_skills() -> void:
	await prepare_dual()
	var a_id: String = player.loadout.weapon_at(0).id
	var b_id: String = player.loadout.weapon_at(1).id
	var a_skills: Array = player.loadout.sets[0].skills.duplicate()
	await tap(KEY_SHIFT)
	verify(player.loadout.current_set == 1 and player.combat.state != "SWITCH", "dual Shift changes the selected skill group without a weapon-switch lock")
	verify(player.loadout.weapon_at(0).id == a_id and player.loadout.weapon_at(1).id == b_id, "Shift keeps both swords in their original A/B slots")
	verify(player.loadout.sets[1].skills != a_skills, "dual A and B expose independent QER skill loadouts")
	await weapon_input("PRIMARY_TAP")
	await wait_hurts(2)
	check_pair("B-selected PRIMARY_TAP")
	for group in [0, 1]:
		for slot in range(3):
			await prepare_dual()
			if group == 1:
				await tap(KEY_SHIFT)
			var id: String = player.loadout.sets[group].skills[slot]
			var skill: Dictionary = arena.database.skills[id]
			var energy: float = player.resources.current("Energy")
			if id == "warrior_thrust":
				foe.global_position = player.global_position + Vector3.FORWARD * 5.5
			await tap([KEY_Q, KEY_E, KEY_R][slot])
			await wait_hurts(2)
			verify(started.size() == 1 and started[0].id == id, "QER launches exactly the requested skill from group %d slot %d" % [group, slot])
			check_pair("group %d slot %d %s" % [group, slot, id])
			verify(skill_events.size() == 1 and skill_events[0] == id, id + " emits skill_used once")
			var expected_energy := minf(player.resources.max_value("Energy"), energy - float(skill.get("costs", {}).get("Energy", 0)) + float(skill.get("gains", {}).get("Energy", 0)))
			near(player.resources.current("Energy"), expected_energy, id + " pays and grants declared Energy once")
			near(float(player.combat.cooldowns.get(id, 0)), float(skill.cooldown) - parent_elapsed(), id + " second attack does not restart skill cooldown", .02)
			await ticks(65)
			verify(strike_packets.size() == 2 and hurt_events.size() == 2, id + " cannot repeat its two hits after recovery")

func check_queued_skill_group_snapshot() -> void:
	await prepare_dual()
	var skill_id := "warrior_whirlwind"
	verify(player.loadout.assign_skill(0, 0, skill_id) and player.loadout.assign_skill(1, 0, "warrior_impact"), "buffer fixture gives A Q and B Q distinct skills")
	var a_weapon: Dictionary = player.loadout.weapon_at(0).duplicate(true)
	var b_weapon: Dictionary = player.loadout.weapon_at(1).duplicate(true)
	var formula: Dictionary = arena.database.skills[skill_id].formula
	var expected_raw := float(a_weapon.weapon_scaling) * float(formula.weapon) + float(formula.get("base", 0))
	for stat in ["STR", "DEX", "CON", "INT", "PER", "CHA"]:
		expected_raw += player.stats.get_final_stat(stat) * float(formula.get(stat, 0))
	var skill_results: Array[Dictionary] = []
	var capture_skill := func(result: Dictionary):
		if player.combat.runner.current_action.get("id", "") == skill_id:
			skill_results.append(result.duplicate(true))
	player.combat.damage_dealt.connect(capture_skill)
	await weapon_input("PRIMARY_TAP")
	await wait_hurts(1)
	verify(player.combat.runner.action_phase == "ACTIVE", "A Q is pressed during the real dual weapon active phase")
	await tap(KEY_Q)
	verify(player.combat.queued_command.get("action_id", "") == skill_id, "A Q queues its requested skill while the two-blade action is active")
	await tap(KEY_SHIFT)
	verify(player.loadout.current_set == 1, "real Shift selects B before the buffered A skill starts")
	await ticks(65)
	player.combat.damage_dealt.disconnect(capture_skill)
	var skill_packets: Array[Dictionary] = []
	for observed in strike_packets:
		if observed.get("is_skill", false):
			skill_packets.append(observed)
	verify(skill_packets.size() == 2 and skill_events == [skill_id], "cross-group buffered Q launches the original A skill once with two attacks")
	if skill_packets.size() == 2:
		verify(skill_packets[0].weapon_snapshot.id == b_weapon.id and skill_packets[1].weapon_snapshot.id == a_weapon.id, "buffered A skill uses fixed left B then right A sword snapshots after Shift")
		verify(int(skill_packets[0].get("skill_set", -1)) == 0 and int(skill_packets[1].get("skill_set", -1)) == 0, "both buffered attacks retain the original skill group metadata")
	verify(skill_results.size() == 2, "cross-group buffered A skill deals two real damage packets")
	if skill_results.size() == 2:
		near(float(skill_results[0].raw), expected_raw + (float(b_weapon.weapon_scaling) - float(a_weapon.weapon_scaling)) * float(formula.weapon), "buffered A skill left attack uses B scaling")
		near(float(skill_results[1].raw), expected_raw, "buffered A skill right attack uses A scaling")
		print("DUAL_QUEUE_TRACE ", JSON.stringify({"queued_group": 0, "selected_group": player.loadout.current_set,
			"skill": skill_id, "weapons": [skill_packets[0].weapon_snapshot.id, skill_packets[1].weapon_snapshot.id] if skill_packets.size() == 2 else [],
			"raw": [skill_results[0].raw, skill_results[1].raw], "expected_a_raw": expected_raw}))

func check_shared_dodge_passive() -> void:
	for scenario in ["A_selected", "B_selected", "same_sword_pair"]:
		await prepare_dual()
		if scenario == "B_selected":
			await tap(KEY_SHIFT)
		elif scenario == "same_sword_pair":
			verify(player.loadout.equip_weapon(0, "azure_katana"), "two identical swords are valid for the shared passive deduplication fixture")
		var additions: Array[String] = []
		var record_status := func(id: String):
			if id == "keen_edge":
				additions.append(id)
		player.combat.statuses.status_added.connect(record_status)
		player.combat.engage()
		var hp: float = player.resources.current("HP")
		await tap(KEY_SPACE)
		verify(player.combat.state == "DODGE", scenario + " starts dodge through the real Space input")
		impact()
		player.combat.statuses.status_added.disconnect(record_status)
		near(player.resources.current("HP"), hp, scenario + " avoids the real incoming hit during perfect dodge")
		verify(player.combat.statuses.has_status("keen_edge"), scenario + " activates the held azure sword's perfect-dodge passive")
		verify(additions.size() == 1, scenario + " applies the shared passive exactly once")
		near(float(player.combat.statuses.modifiers().get("crit_chance", 0)), .15, scenario + " keeps a single fifteen-point next-attack critical bonus")

func check_thrust_displacement() -> void:
	await prepare_dual()
	player.loadout.assign_skill(0, 0, "warrior_thrust")
	foe.global_position = player.global_position + Vector3.FORWARD * 5.5
	var initial: Vector3 = player.global_position
	var original: Dictionary = arena.database.skills.warrior_thrust.duplicate(true)
	arena.database.skills.warrior_thrust.effects.append({"type": "resource", "resource": "Energy", "amount": 20, "target": "self"})
	arena.database.skills.warrior_thrust.effects.append({"type": "status", "status": "dual_self_test", "duration": 1, "target": "self"})
	player.resources.change("Energy", -60)
	var energy: float = player.resources.current("Energy")
	var self_additions: Array[String] = []
	var record_self := func(id: String):
		if id == "dual_self_test":
			self_additions.append(id)
	player.combat.statuses.status_added.connect(record_self)
	await tap(KEY_Q)
	await wait_hurts(2)
	player.combat.statuses.status_added.disconnect(record_self)
	check_pair("dual thrust after movement")
	near(initial.z - player.global_position.z, 3, "two thrust attacks perform the declared three-meter dash only once", .03)
	near(player.resources.current("Energy"), energy + 20, "dual thrust self resource effect is applied once")
	verify(self_additions.size() == 1, "dual thrust self status effect is applied once")
	if strike_packets.size() == 2:
		for i in range(2):
			near(strike_packets[i]._origin.distance_to(strike_packets[i]._actor_position), 0, "thrust stage %d originates at the actor's post-dash position" % i, .03)
		near(strike_packets[0]._origin.distance_to(strike_packets[1]._origin), 0, "second thrust starts at the same post-dash origin", .03)
	print("DUAL_THRUST_TRACE ", JSON.stringify({"start": str(initial), "end": str(player.global_position),
		"origins": strike_packets.map(func(value: Dictionary): return str(value._origin)), "self_effects": self_additions.size()}))
	arena.database.skills.warrior_thrust = original
	await prepare_dual()
	player.loadout.assign_skill(0, 0, "warrior_thrust")
	initial = player.global_position
	await tap(KEY_Q)
	await wait_hurts(2)
	verify(strike_packets.size() == 2 and hurt_events.size() == 2, "nearby enemy receives both thrust attacks without being overrun")
	near(initial.z - player.global_position.z, .45, "nearby target limits the single thrust dash to its approach distance", .04)
	await prepare_dual()
	player.loadout.assign_skill(0, 0, "warrior_thrust")
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(4, 3, .4)
	collision.shape = shape
	wall.add_child(collision)
	arena.actor_parent.add_child(wall)
	wall.global_position = player.global_position + Vector3(0, 1.4, -1.5)
	foe.global_position = player.global_position + Vector3.FORWARD * 4
	await ticks(2)
	initial = player.global_position
	await tap(KEY_Q)
	await wait_packets(2)
	verify(strike_packets.size() == 2, "wall-blocked thrust still executes its two attack stages")
	var travel: float = initial.z - player.global_position.z
	verify(travel > .1 and travel < 1.3, "thrust dash stops at the real physics wall instead of crossing it (%.3fm)" % travel)
	if strike_packets.size() == 2:
		near(strike_packets[0]._origin.distance_to(strike_packets[1]._origin), 0, "wall collision cannot cause a second displacement on the delayed thrust", .03)
		near(strike_packets[1]._origin.distance_to(player.global_position), 0, "both wall-blocked attacks retain the collision-limited endpoint", .03)
	verify(hurt_events.is_empty(), "two thrust hitboxes cannot damage an enemy through the wall")
	wall.queue_free()
	await ticks(2)

func check_skill_effects_and_gates() -> void:
	await prepare_dual()
	player.loadout.assign_skill(0, 0, "warrior_impact")
	var applications: Array[String] = []
	var record_debuff := func(id: String):
		if id == "physical_vulnerability":
			applications.append(id)
	foe.combat.statuses.status_added.connect(record_debuff)
	await tap(KEY_Q)
	await wait_hurts(2)
	foe.combat.statuses.status_added.disconnect(record_debuff)
	verify(hurt_events.size() == 2 and applications.size() == 2, "each impact attack applies its on-hit vulnerability once")
	await prepare_dual()
	player.loadout.assign_skill(0, 0, "warrior_whirlwind")
	player.resources.change("Energy", -player.resources.current("Energy"))
	await tap(KEY_Q)
	await ticks(35)
	verify(started.is_empty() and strike_packets.is_empty() and skill_events.is_empty(), "unaffordable dual skill produces no parent, attacks, or skill event")
	verify(not player.combat.cooldowns.has("warrior_whirlwind"), "unaffordable dual skill starts no cooldown")
	player.resources.change("Energy", 20)
	await tap(KEY_Q)
	await wait_hurts(2)
	verify(strike_packets.size() == 2 and skill_events.size() == 1, "exactly 20 Energy permits both attacks of one dual skill")
	near(player.resources.current("Energy"), 0, "delayed skill attack does not require or consume another 20 Energy")
	await ticks(50)
	player.resources.change("Energy", 40)
	await tap(KEY_Q)
	await ticks(45)
	verify(started.size() == 1 and strike_packets.size() == 2 and skill_events.size() == 1, "positive cooldown rejects another dual skill without replaying either attack")
	near(player.resources.current("Energy"), 40, "cooldown rejection makes no additional skill payment")

func check_skill_interruptions() -> void:
	for timing in ["startup", "between"]:
		for interruption in ["stun", "death", "grab"]:
			await prepare_dual()
			player.loadout.assign_skill(0, 0, "warrior_whirlwind")
			var energy: float = player.resources.current("Energy")
			await tap(KEY_Q)
			if timing == "between":
				await wait_hurts(1)
			var expected_hits := 1 if timing == "between" else 0
			verify(strike_packets.size() == expected_hits, "%s %s fixture interrupts at its intended skill stage" % [timing, interruption])
			var incoming := {"formula": {"base": 99999 if interruption == "death" else 1}, "poise_damage": 999 if interruption == "stun" else 0}
			if interruption == "grab":
				incoming.merge({"attack_kind": "GRAB", "blockable": false, "grab_duration": 1.0}, true)
			impact(incoming)
			await ticks(60)
			verify(strike_packets.size() == expected_hits and hurt_events.size() == expected_hits, "%s %s cancels all remaining dual skill attacks" % [timing, interruption])
			verify(skill_events.size() == 1, "%s %s preserves one original skill event" % [timing, interruption])
			near(player.resources.current("Energy"), energy - 20, "%s %s leaves exactly the original skill payment" % [timing, interruption])
	await prepare_dual()
	player.loadout.assign_skill(0, 0, "warrior_whirlwind")
	var old_shield: Dictionary = foe.enemy_shield.duplicate(true)
	foe.enemy_shield = arena.database.weapons.wooden_shield.duplicate(true)
	await tap(KEY_Q)
	foe.combat.defense.start_guard(true)
	await ticks(45)
	verify(foe.combat.defense.last_outcome == "parry" and strike_packets.size() == 1 and hurt_events.is_empty(), "parrying the first skill attack prevents its second attack")
	foe.enemy_shield = old_shield

func check_invalid_second_sword_gate() -> void:
	await prepare_dual()
	player.loadout.assign_skill(0, 0, "warrior_whirlwind")
	mouse(MOUSE_BUTTON_LEFT, true)
	await ticks(5)
	verify(player.combat.state == "CHARGING", "second-sword gate fixture begins a real held charge")
	player.stats.add_modifier("dual_gate_test", {"DEX": -1})
	verify(player.loadout.can_equip_set_weapon(0, "iron_longsword").is_empty() and not player.loadout.can_equip_set_weapon(1, "azure_katana").is_empty(), "temporary attribute loss invalidates only B while A remains usable")
	var energy: float = player.resources.current("Energy")
	await tap(KEY_Q)
	verify(player.combat.state == "CHARGING" and not player.combat.charge_action.is_empty(), "invalid B sword makes A skill reject before cancelling a held charge")
	verify(skill_events.is_empty() and not player.combat.cooldowns.has("warrior_whirlwind"), "invalid second-sword skill produces no event or cooldown")
	near(player.resources.current("Energy"), energy, "invalid second-sword skill costs no Energy")
	player.stats.remove_modifier("dual_gate_test")
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(45)
	await prepare_dual()
	player.loadout.assign_skill(0, 0, "warrior_whirlwind")
	await weapon_input("PRIMARY_TAP")
	await wait_hurts(1)
	var parent_id: String = player.combat.runner.current_action.get("instance_id", "")
	await tap(KEY_Q)
	verify(player.combat.queued_command.get("action_id", "") == "warrior_whirlwind", "valid two-sword skill queues before B loses its attribute requirement")
	player.stats.add_modifier("dual_gate_test", {"DEX": -1})
	energy = player.resources.current("Energy")
	for i in range(35):
		if not player.combat.runner.busy() or player.combat.runner.action_phase == "RECOVERY":
			break
		await ticks(1)
	verify(player.combat.runner.current_action.get("instance_id", "") == parent_id and player.combat.runner.action_phase == "RECOVERY", "second-sword revalidation preserves original weapon recovery when the buffered skill becomes invalid")
	verify(player.combat.queued_command.is_empty() and skill_events.is_empty(), "second-sword revalidation clears the invalid queue without a skill event")
	near(player.resources.current("Energy"), energy, "second-sword queue rejection never pays the buffered skill")
	player.stats.remove_modifier("dual_gate_test")

func check_projectile_interruptions() -> void:
	for issued in [1, 2]:
		await prepare_dual()
		player.loadout.assign_skill(0, 0, "warrior_sword_wave")
		var target_position: Vector3 = player.global_position + Vector3.FORWARD * 6
		foe.global_position = target_position
		await tap(KEY_Q)
		await wait_packets(issued)
		verify(strike_packets.size() == issued and hurt_events.is_empty(), "%d sword waves leave the source before reaching the distant target" % issued)
		impact({"formula": {"base": 99999 if issued == 2 else 1}, "poise_damage": 999})
		foe.global_position = target_position
		await ticks(65)
		verify(strike_packets.size() == issued, "interrupting after %d sword waves prevents any unissued attack" % issued)
		verify(hurt_events.size() == issued, "all %d already-issued sword waves remain live after source control or death" % issued)
		verify(skill_events.size() == 1, "interrupted sword-wave pair still emits only one skill event")

func check_ordinary_skills() -> void:
	for id in ["warrior_whirlwind", "warrior_thrust", "warrior_impact", "warrior_sword_wave"]:
		await prepare("warrior")
		clear_observations()
		player.loadout.assign_skill(0, 0, id)
		if id == "warrior_thrust":
			foe.global_position = player.global_position + Vector3.FORWARD * 5.5
		await tap(KEY_Q)
		await ticks(65)
		verify(strike_packets.size() == 1 and hurt_events.size() == 1, "ordinary warrior %s retains one attack and one hurt event" % id)
		verify(strike_packets.size() == 1 and not strike_packets[0].has("dual_strike_index"), "ordinary warrior %s does not acquire the dual template" % id)

