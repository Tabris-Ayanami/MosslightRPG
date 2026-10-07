extends SceneTree
## Focused catalog execution; complements combat_integration.gd rather than re-testing input.
## Godot --headless --path . --fixed-fps 60 --script tests/combat_catalog_runtime.gd

const Attack = preload("res://combat/attack_instance.gd")
const ORIGIN := Vector3(0, .1, 7)
const SKILL_CASES := [
	["warrior_whirlwind", "warrior", "", "iron_longsword", 5, {"Energy": 20}, 112.5],
	["warrior_thrust", "warrior", "", "iron_longsword", 4, {}, 118.5],
	["warrior_impact", "warrior", "", "iron_longsword", 8, {"Energy": 20}, 71.5],
	["warrior_sword_wave", "warrior", "", "iron_longsword", 10, {"Energy": 40}, 112.0],
	["swordsman_fan_slash", "warrior", "swordsman", "iron_longsword", 7, {"Energy": 20}, 131.5],
	["duelist_finisher", "warrior", "duelist", "hunter_dagger", 9, {"Energy": 20}, 169.0],
	["duelist_fujian", "warrior", "duelist", "iron_longsword", 8, {"Energy": 20}, 0.0],
	["rogue_shadow_strike", "rogue", "", "hunter_dagger", 6, {"Energy": 20}, 123.0],
	["rogue_precision_shot", "rogue", "", "shortbow", 5, {"Energy": 20}, 159.45],
	["rogue_smoke", "rogue", "", "hunter_dagger", 14, {"Energy": 20}, 0.0],
	["rogue_throwing_blade", "rogue", "", "hunter_dagger", 4, {}, 113.5],
	["shadowblade_execute", "rogue", "shadowblade", "hunter_dagger", 8, {"Energy": 20}, 168.5],
	["ranger_piercing_arrow", "rogue", "ranger", "shortbow", 8, {"Energy": 20}, 172.1],
	["ranger_arrow_rain", "rogue", "ranger", "shortbow", 12, {"Energy": 40}, 53.15],
	["barbarian_leap", "barbarian", "", "bone_greataxe", 8, {"Energy": 20}, 180.8],
	["barbarian_fan_slash", "barbarian", "", "bone_greataxe", 6, {"Energy": 20}, 139.4],
	["barbarian_blood_rage", "barbarian", "", "bone_greataxe", 16, {}, 0.0],
	["barbarian_impact", "barbarian", "", "bone_greataxe", 9, {"Energy": 20}, 105.4],
	["berserker_quake", "barbarian", "berserker", "bone_greataxe", 12, {"Energy": 40}, 143.0],
	["vanguard_launch", "barbarian", "vanguard", "border_spear", 7, {"Energy": 20}, 102.2],
	["vanguard_piercing_thrust", "barbarian", "vanguard", "border_spear", 9, {"Energy": 20}, 130.0],
	["mage_fireball", "mage", "", "apprentice_staff", 6, {"Energy": 10}, 228.0],
	["mage_lightning", "mage", "", "apprentice_staff", 8, {"Energy": 10}, 228.4],
	["mage_earth_spike", "mage", "", "apprentice_staff", 7, {"Energy": 10}, 193.6],
	["mage_shield", "mage", "", "apprentice_staff", 14, {"Energy": 10}, 0.0],
	["evoker_ice_storm", "mage", "evoker", "apprentice_staff", 12, {"Energy": 35}, 67.0],
	["evoker_fire_wall", "mage", "evoker", "apprentice_staff", 14, {"Energy": 35}, 33.0],
	["evoker_earthquake", "mage", "evoker", "apprentice_staff", 15, {"Energy": 35}, 192.0],
	["conjurer_bind", "mage", "conjurer", "apprentice_staff", 10, {"Energy": 20}, 0.0],
	["conjurer_blink", "mage", "conjurer", "apprentice_staff", 9, {"Energy": 20}, 0.0],
	["conjurer_chain_lightning", "mage", "conjurer", "apprentice_staff", 11, {"Energy": 35}, 167.0],
	["conjurer_dreamwalk", "mage", "conjurer", "apprentice_staff", 20, {"Energy": 20}, 0.0]
]

var arena: Node
var player: Node
var database: RefCounted
var checks := 0
var failures: Array[String] = []
var damage_events: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func near(actual: float, expected: float, label: String, tolerance := .01) -> void:
	verify(absf(actual - expected) <= tolerance, "%s (%.4f / %.4f)" % [label, actual, expected])

func prepare(career := "warrior", subclass := "", weapon := "") -> void:
	arena.control.cancel_all()
	for action in InputMap.get_actions():
		Input.action_release(action)
	for child in arena.effects.get_children():
		if child.get_script() == Attack:
			child.queue_free()
	player.loadout.select_career(career)
	player.loadout.set_level(3)
	if not subclass.is_empty():
		verify(player.loadout.select_career(subclass), "setup selects " + subclass)
	if not weapon.is_empty():
		verify(player.loadout.equip_weapon(0, weapon), "setup equips " + weapon)
	player.combat.reset()
	player.global_position = ORIGIN
	player.velocity = Vector3.ZERO
	player.facing = Vector3.FORWARD
	arena.locked_target = null
	arena.aim_override = ORIGIN + Vector3.FORWARD * 2
	arena.aim_point = arena.aim_override
	arena.ui.toggle_menu(false)
	arena.input_blocked = false
	for enemy in arena.enemies:
		if not is_instance_valid(enemy):
			continue
		enemy.ai_enabled = false
		enemy.combat.reset()
		enemy.resources.configure("HP", float(database.enemies[enemy.enemy_id].hp))
		enemy.global_position = Vector3(18, .1, 18)
		enemy.velocity = Vector3.ZERO
	await ticks(3)
	damage_events.clear()

func enemy_of(id: String) -> Node:
	for enemy in arena.enemies:
		if is_instance_valid(enemy) and enemy.enemy_id == id:
			return enemy
	var enemy: Node = arena.spawn_enemy(id, Vector3(18, .1, 18))
	enemy.ai_enabled = false
	return enemy

func target(id := "soldier", offset := Vector3(0, 0, -2)) -> Node:
	var enemy := enemy_of(id)
	enemy.combat.reset()
	enemy.global_position = player.global_position + offset
	enemy.velocity = Vector3.ZERO
	enemy.facing = Vector3.BACK
	arena.locked_target = enemy
	arena.aim_override = enemy.global_position
	arena.aim_point = enemy.global_position
	return enemy

func run() -> void:
	var packed: PackedScene = load("res://scenes/demo/CombatTestArena.tscn")
	if packed == null:
		printerr("CombatTestArena scene missing")
		quit(1)
		return
	arena = packed.instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(3)
	if not is_instance_valid(arena.player) or not is_instance_valid(arena.ui):
		printerr("Catalog runtime aborted: arena/player/UI failed to initialize; check preceding script diagnostics")
		quit(1)
		return
	player = arena.player
	database = arena.database
	player.combat.damage_dealt.connect(func(result: Dictionary): damage_events.append(result.duplicate(true)))
	await check_every_active_skill()
	await check_every_weapon_action()
	await check_shield_weapon_and_soldier_pair()
	await check_dual_sword_career_and_groups()
	await check_reaction_catalog_execution()
	await check_caster_cantrip_shapes()
	await check_ice_storm_ticks()
	await check_status_expiry_and_consumption()
	await check_control_ownership()
	await check_critical_qi_cooldown()
	await check_sequence_boundaries()
	await check_remaining_passive_values()
	await check_status_stack_rules()
	print("COMBAT_CATALOG_RUNTIME: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures:
		printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)

func check_every_active_skill() -> void:
	verify(database.skills.size() == SKILL_CASES.size(), "every shipped active skill has an independent specification case")
	var covered: Array[String] = []
	for spec in SKILL_CASES:
		var id: String = spec[0]
		await prepare(spec[1], spec[2], spec[3])
		var enemy := target()
		enemy.resources.configure("HP", 10000)
		enemy.combat.current_poise = 10000
		if id in ["duelist_finisher", "shadowblade_execute"]:
			enemy.resources.change("HP", -7500)
		if id == "barbarian_blood_rage":
			player.resources.change("Energy", -player.resources.current("Energy"))
		var action: Dictionary = database.skills[id]
		verify(id in player.loadout.unlocked_skills, id + " automatically unlocked through its actual career chain")
		verify(player.combat.action_failure(action).is_empty(), id + " conditions permit intended weapon and target")
		var before := {}
		for resource in ["HP", "Energy", "Stamina"]:
			before[resource] = player.resources.current(resource)
		verify(player.combat.use_action(action), id + " starts through real CombatController")
		near(player.combat.cooldowns.get(id, -1), float(spec[4]), id + " cooldown matches specification at cast start")
		for resource in ["Energy", "Stamina"]:
			near(player.resources.current(resource), float(before[resource]) - float(spec[5].get(resource, 0)), id + " charges only declared " + resource + " cost")
		await ticks(132 if id == "duelist_fujian" else 100)
		if id == "conjurer_dreamwalk":
			verify(arena.control.controlled_actor() == enemy and player.control_mode == "none", "dreamwalk reaches actual possession service and leaves original body parked")
			verify(arena.control.remaining > 13.0 and arena.control.remaining < 15.0, "dreamwalk uses its configured fifteen-second lease")
			near(enemy.resources.current("HP"), 10000, "dreamwalk is non-damaging")
			verify(damage_events.is_empty(), "dreamwalk creates no damage callback")
			arena.control.release()
		verify(player.combat.can_start(), id + " finishes its action lifecycle")
		if float(spec[6]) > 0:
			verify(not damage_events.is_empty(), id + " reaches a real enemy through attack execution")
			if not damage_events.is_empty():
				near(float(damage_events[0].get("raw", 0)), float(spec[6]), id + " raw damage matches original formula reference")
		else:
			match id:
				"duelist_fujian":
					verify(damage_events.is_empty(), "negative-sword stance without an incoming attack never deals free damage")
					near(enemy.resources.current("HP"), 10000, "untriggered counter preserves enemy HP")
					verify(not player.combat.invulnerable(), "counter stance expires without leaving persistent immunity")
				"rogue_smoke": verify(player.combat.statuses.has_status("stealth"), "smoke retains its 2.5 second stealth after execution")
				"barbarian_blood_rage":
					near(player.resources.current("HP"), float(before.HP) * .92, "blood rage costs current HP percentage")
					near(player.resources.current("Energy"), 40, "blood rage adds exactly 40 Energy at ACTIVE")
				"mage_shield": near(player.health.shield, 232, "shield utility produces 120+INT*8 absorption")
				"conjurer_bind": verify(enemy.combat.statuses.has_status("root"), "bind utility controls its actual target")
				"conjurer_blink":
					verify(player.global_position.distance_to(ORIGIN) > 1.7, "blink utility moves the actual actor")
					verify(not player.combat.invulnerable(), "blink utility does not provide invulnerability")
		covered.append(id)
	for id in database.skills:
		verify(id in covered, "catalog execution coverage " + id)

func check_every_weapon_action() -> void:
	var loadouts := {
		"SINGLE_BLADE": ["warrior", "iron_longsword"],
		"SHORT_WEAPON": ["rogue", "hunter_dagger"],
		"POLEARM": ["barbarian", "border_spear"],
		"HEAVY_2H": ["barbarian", "bone_greataxe"],
		"BOW": ["rogue", "shortbow"],
		"CASTER": ["mage", "apprentice_staff"],
		"UNARMED": ["warrior", ""]
	}
	var covered: Array[String] = []
	for entry in database.actions.values():
		var id: String = entry.id
		var family: String = entry.animation_family
		var semantic: String = entry.semantic
		await prepare(loadouts[family][0], "", loadouts[family][1])
		if family == "UNARMED":
			player.loadout.set_level(0)
			player.combat.reset()
		var enemy := target("soldier", Vector3(0, 0, -1.2) if family == "UNARMED" else Vector3(0, 0, -2))
		enemy.resources.configure("HP", 10000)
		enemy.combat.current_poise = 10000
		var before := {}
		for resource in ["Energy", "Stamina"]:
			before[resource] = player.resources.current(resource)
		player.combat.combo = int(entry.combo_index)
		verify(player.combat.weapon_action(semantic), id + " executes through weapon_action and database family lookup")
		verify(player.combat.runner.current_action.get("id", "") == id, id + " resolves its exact zero-based combo index")
		verify(player.combat.runner.current_action.get("animation_family", "") == family and player.animation.weapon_family == family, id + " current weapon controls gameplay and presentation family")
		near(player.combat.cooldowns.get(id, -1), 0, id + " keeps the specified zero weapon-action cooldown")
		for resource in ["Energy", "Stamina"]:
			near(player.resources.current(resource), float(before[resource]) - float(entry.costs.get(resource, 0)), id + " pays its own " + resource + " action cost")
		if family == "CASTER":
			var expected_energy := 70 if semantic.ends_with("CHARGE") else 80
			near(player.resources.current("Energy"), expected_energy, id + " caster tap/charge spends zero/10 Energy from the unified pool")
		await ticks(100)
		verify(player.combat.can_start(), id + " completes startup-active-recovery without stale action")
		verify(not damage_events.is_empty() and enemy.resources.current("HP") < 10000, id + " damages a real enemy through its actual attack instance")
		covered.append(id)
	verify(covered.size() == 36 and covered.size() == database.actions.size(), "all 36 weapon actions across seven families including unarmed were executed")

func check_shield_weapon_and_soldier_pair() -> void:
	await prepare("warrior", "", "iron_longsword")
	verify(player.loadout.sets.size() == 2, "ordinary career has exactly two A/B weapon groups")
	for group in player.loadout.sets:
		verify(group.size() == 2 and group.has("weapon") and group.has("skills") and group.skills.size() == 3, "ordinary group contains one weapon and three prepared skills only")
	verify(not player.loadout.equip_weapon(0, "wooden_shield") and not player.loadout.equip_weapon(1, "buckler"), "ordinary warrior cannot equip shields without SHIELD proficiency")
	verify(player.loadout.weapon_at(0).id == "iron_longsword" and player.loadout.weapon_at(1).id == "hunter_dagger", "rejected shield placement preserves ordinary A sword and B dagger")
	verify(player.loadout.shield().is_empty(), "ordinary warrior does not carry an extra shield")
	verify(not player.combat.use_action(database.reactions.shield_raise.duplicate(true)), "direct shield raise rejects missing actual shield weapon")
	verify(player.combat.can_start(), "rejected shield raise leaves no running action")
	await prepare("barbarian", "", "iron_greatsword")
	verify(player.loadout.weapon_at(0).weapon_type == "Greatsword", "ordinary proficient career can equip the actual greatsword weapon")
	var charge: Dictionary = database.get_action(player.loadout.combat_weapon().animation_family, "PRIMARY_CHARGE")
	verify(charge.id == "heavy_2h_primary_charge_1" and charge.charge_guard_window.start_ratio == .65 and charge.charge_guard_window.end_ratio == .85, "greatsword resolves shared heavy charge precision window")
	await prepare("warrior", "soldier", "iron_longsword")
	verify(player.loadout.uses_paired_weapons() and player.loadout.paired_style() == "sword_shield_pair", "soldier activates the sword-shield pair loadout rule")
	verify(player.loadout.sets[0].weapon == "iron_longsword" and player.loadout.sets[1].weapon == "wooden_shield", "soldier equips its default sword in A and shield in B")
	verify(player.loadout.combat_weapon().id == "iron_longsword" and player.loadout.shield().id == "wooden_shield", "soldier resolves its A sword and B shield simultaneously")
	var skills_a: Array = player.loadout.sets[0].skills.duplicate()
	var skills_b: Array = player.loadout.sets[1].skills.duplicate()
	verify(skills_a.size() == 3 and skills_b.size() == 3 and skills_a != skills_b, "soldier keeps distinct three-skill preparations for A and B")
	verify(not player.loadout.equip_weapon(0, "hunter_dagger"), "soldier rejects a dagger in its sword-only A slot")
	verify(not player.loadout.equip_weapon(0, "iron_greatsword"), "soldier rejects a two-handed greatsword in its paired A slot")
	verify(not player.loadout.equip_weapon(1, "iron_longsword"), "soldier rejects a sword in its shield-only B slot")
	verify(player.loadout.equip_weapon(1, "buckler"), "soldier B accepts another shield weapon")
	verify(player.combat.switch_set(), "soldier switches its current skill preparation")
	verify(player.loadout.current_set == 1 and player.combat.can_start(), "paired preparation switch does not enter a weapon-swap lock")
	verify(player.loadout.weapon_at(0).id == "iron_longsword" and player.loadout.weapon_at(1).id == "buckler", "B preparation preserves the same simultaneously held sword and shield")
	verify(player.loadout.sets[0].skills == skills_a and player.loadout.sets[1].skills == skills_b, "changing preparation and shield does not overwrite either QER set")
	var enemy := target()
	enemy.resources.configure("HP", 10000)
	enemy.combat.current_poise = 10000
	var thrust: Dictionary = database.skills.warrior_thrust.duplicate(true)
	thrust.can_crit = false
	verify(player.combat.use_action(thrust), "soldier can execute an inherited sword skill while B is selected")
	verify(player.combat.runner.current_action.get("weapon_snapshot", {}).get("id", "") == "iron_longsword", "B sword skill snapshots the A sword rather than zero-damage shield")
	await ticks(50)
	verify(damage_events.size() == 1 and enemy.resources.current("HP") < 10000, "paired B skill damages one real target through its actual attack")
	if not damage_events.is_empty():
		near(damage_events[0].raw, 118.5, "paired B thrust keeps sword weapon scaling and inherited attributes")

func check_dual_sword_career_and_groups() -> void:
	await prepare("warrior", "", "iron_longsword")
	player.loadout.set_level(10)
	verify(not player.loadout.select_career("dual_swordsman"), "Lv10 warrior cannot skip swordsman to reach dual swords")
	verify(player.loadout.select_career("swordsman"), "warrior can first advance through the swordsman ancestor")
	player.loadout.set_level(9)
	verify(not player.loadout.select_career("dual_swordsman"), "Lv9 swordsman cannot advance to the Lv10 dual career")
	verify(player.loadout.career_ids == ["warrior", "swordsman"] and not player.loadout.is_dual_wielding(), "rejected early advancement preserves career chain and ordinary weapon rule")
	player.loadout.set_level(10)
	verify(player.loadout.level == 10, "runtime level reaches ten rather than clamping at three")
	verify(player.loadout.select_career("dual_swordsman"), "Lv10 swordsman legally advances to dual swords")
	verify(player.loadout.career_ids == ["warrior", "swordsman", "dual_swordsman"] and player.loadout.is_dual_wielding(), "dual sword career keeps all three ancestors and enables its pair rule")
	near(player.resources.max_value("HP"), 1520, "Lv10 warrior chain evaluates 1520 HP without Lv3 truncation")
	near(player.resources.max_value("Energy"), 180, "Lv10 warrior chain evaluates 180 Energy without Lv3 truncation")
	near(player.resources.max_value("Stamina"), 10, "Lv10 retains the formula-defined stamina pool")
	verify(player.loadout.weapon_at(0).id == "iron_longsword" and player.loadout.weapon_at(1).id == "azure_katana", "dual swords begin with an A longsword and B katana")
	verify("swordsman_fan_slash" in player.loadout.unlocked_skills and "warrior_thrust" in player.loadout.unlocked_skills, "dual swords inherit learned skills across both ancestor levels")
	verify("sword_saint" in player.loadout.passive_ids and "sword_momentum" in player.loadout.passive_ids, "dual swords retain swordsman career passives")
	verify("dual_sword_mastery" in player.loadout.passive_ids, "Lv10 dual career grants its actual sword-skill transformation passive")
	verify(not player.loadout.equip_weapon(0, "hunter_dagger") and not player.loadout.equip_weapon(1, "wooden_shield"), "both dual sword slots enforce sword or katana types")
	verify(player.loadout.equip_weapon(1, "iron_longsword"), "two swords of the same model can occupy A and B")
	verify(player.loadout.weapon_at(0).id == player.loadout.weapon_at(1).id and player.loadout.is_dual_wielding(), "same-model swords preserve the pair rule")
	verify(player.loadout.equip_weapon(1, "azure_katana"), "B sword can be restored independently")
	var skills_a: Array = player.loadout.sets[0].skills.duplicate()
	verify(player.loadout.assign_skill(1, 0, "warrior_whirlwind"), "B group can independently prepare an inherited skill")
	verify(player.loadout.sets[0].skills == skills_a and player.loadout.sets[1].skills[0] == "warrior_whirlwind", "editing B skill does not overwrite A preparation")
	verify(player.combat.switch_set() and player.loadout.current_set == 1 and player.combat.can_start(), "dual pair switches QER to B without a weapon change lock")
	verify(player.loadout.combat_weapon().id == "azure_katana", "dual QER source follows the current B weapon")
	var enemy := target()
	enemy.resources.configure("HP", 10000)
	enemy.combat.current_poise = 10000
	var skill: Dictionary = database.skills.warrior_whirlwind.duplicate(true)
	skill.can_crit = false
	var energy: float = player.resources.current("Energy")
	var skill_events: Array[String] = []
	var used := func(id: String): skill_events.append(id)
	player.combat.skill_used.connect(used)
	verify(player.combat.use_action(skill), "dual sword character starts a current-group ordinary active skill")
	verify(player.combat.runner.current_action.get("weapon_snapshot", {}).get("id", "") == "azure_katana", "parent skill preserves selected B group for costs and action events before ordered child hits")
	var repeated_weapons: Array = player.combat.runner.current_action.get("dual_weapons", [])
	verify(repeated_weapons.size() == 2 and repeated_weapons[0].id == "iron_longsword" and repeated_weapons[1].id == "azure_katana", "sword skill stores independent canonical A and B weapon snapshots")
	var blade_order: Array = player.combat.runner.current_action.get("dual_weapon_order", [])
	verify(blade_order.size() == 2 and int(blade_order[0]) == 1 and int(blade_order[1]) == 0, "skill sequence maps its first attack to left B then its second to right A")
	near(player.resources.current("Energy"), energy - 20, "QER skill pays exactly its declared 20 Energy cost")
	near(player.combat.cooldowns.get(skill.id, 0), 5, "repeated whirlwind starts its one original five-second cooldown")
	await ticks(50)
	verify(damage_events.size() == 2, "mastery repeats the whirlwind attack portion exactly twice")
	if damage_events.size() >= 2:
		near(damage_events[0].raw, 117.1, "left B katana whirlwind uses its full 34-point weapon formula")
		near(damage_events[1].raw, 112.5, "right A sword whirlwind uses its own full 30-point weapon formula")
	verify(skill_events == ["warrior_whirlwind"], "two attack portions emit just one parent skill-used event")
	player.combat.skill_used.disconnect(used)
	player.loadout.set_level(9)
	await ticks(3)
	verify(player.loadout.career_ids == ["warrior", "swordsman"] and not player.loadout.is_dual_wielding() and not player.loadout.uses_paired_weapons(), "dropping below Lv10 removes dual career and simultaneous second sword rule")
	verify("dual_sword_mastery" not in player.loadout.passive_ids, "downgrade removes the sword-skill transformation passive")
	verify(player.loadout.sets.size() == 2 and player.loadout.sets[1].skills.size() == 3, "downgrade retains normal A/B backup group and its independent preparation")
	verify(player.combat.can_start(), "downgrade leaves no stale dual action")
	near(player.resources.max_value("HP"), 1470, "downgrade recalculates actual Lv9 HP")
	near(player.resources.max_value("Energy"), 170, "Lv9 Energy follows its nonlinear growth formula")
	player.combat.reset()
	enemy = target()
	enemy.resources.configure("HP", 10000)
	enemy.combat.current_poise = 10000
	damage_events.clear()
	verify(player.combat.use_action(skill), "ordinary swordsman can still use the same metadata-bearing skill after downgrade")
	await ticks(50)
	verify(damage_events.size() == 1, "skill metadata alone does not repeat attacks after dual mastery is lost")
	player.loadout.set_level(1)
	verify(player.loadout.career_ids == ["warrior"] and "swordsman_fan_slash" not in player.loadout.unlocked_skills, "further downgrade removes inaccessible swordsman skills and career")
	player.loadout.set_level(0)
	verify(player.loadout.career_ids.is_empty() and not player.loadout.is_dual_wielding(), "Lv0 clears the full progression chain")

func check_reaction_catalog_execution() -> void:
	var cases := {"fujian_counter": 148.0, "guard_riposte": 124.0, "shield_raise": 0.0}
	verify(cases.size() == database.reactions.size(), "every reaction has an independent runtime case")
	for id in cases:
		await prepare("warrior", "soldier" if id == "shield_raise" else "", "iron_longsword")
		var enemy := target()
		enemy.resources.configure("HP", 10000)
		enemy.combat.current_poise = 10000
		var action: Dictionary = database.reactions[id].duplicate(true)
		action.can_crit = false
		var energy: float = player.resources.current("Energy")
		var stamina: float = player.resources.current("Stamina")
		verify(id not in player.loadout.unlocked_skills, id + " remains a reaction rather than a learned skill")
		verify(player.combat.use_action(action), id + " executes from its independent reaction definition")
		near(player.resources.current("Energy"), energy, id + " does not pay Energy a second time")
		near(player.resources.current("Stamina"), stamina, id + " does not pay an extra action stamina cost")
		near(player.combat.cooldowns.get(id, -1), 0, id + " has no extra cooldown")
		if id == "shield_raise":
			verify(not player.combat.runner.current_action.has("formula"), "shield raise starts without a hidden damage formula")
			near(player.combat.runner.current_action.startup, 0, "shield raise begins its defense action without startup delay")
			verify(player.combat.runner.current_action.get("weapon_snapshot", {}).get("weapon_type", "") == "Shield" and player.combat.runner.current_action.animation_family == "SHIELD", "shield raise snapshots the real shield and its defense animation family")
		await ticks(45)
		verify(player.combat.can_start(), id + " finishes without a stale action or defense state")
		if id == "shield_raise":
			verify(damage_events.is_empty(), "non-damaging shield raise emits no target damage event")
			near(enemy.resources.current("HP"), 10000, "shield raise does not damage a nearby enemy")
		else:
			verify(damage_events.size() == 1, id + " executes exactly one real attack instance")
			if not damage_events.is_empty():
				near(damage_events[0].raw, float(cases[id]), id + " applies its own reaction damage formula")

func check_caster_cantrip_shapes() -> void:
	await prepare("mage", "", "apprentice_staff")
	var first := target("soldier", Vector3(0, 0, -4))
	var second := target("heavy_guard", Vector3(1.6, 0, -4))
	var outside := target("fire_elemental", Vector3(2.4, 0, -4))
	arena.locked_target = first
	arena.aim_override = first.global_position
	arena.aim_point = first.global_position
	var spark: Dictionary = database.get_action("CASTER", "PRIMARY_TAP")
	spark["can_crit"] = false
	verify(player.combat.use_action(spark), "ordinary fire spark starts")
	await ticks(70)
	near(first.combat.last_damage.get("raw", 0), 70.4, "ordinary spark uses the demo single-target cantrip budget: 0.8 weapon + INT*4")
	near(player.resources.current("Energy"), 80, "ordinary spark leaves all Lv3 energy intact")
	near(second.resources.current("HP"), second.resources.max_value("HP"), "ordinary spark has no empowered explosion")
	player.combat.reset()
	first.combat.reset()
	second.combat.reset()
	outside.combat.reset()
	var enhanced: Dictionary = database.get_action("CASTER", "PRIMARY_CHARGE")
	enhanced["can_crit"] = false
	verify(player.combat.use_action(enhanced), "empowered spark starts")
	near(player.resources.current("Energy"), 70, "empowered spark spends exactly 10 Energy")
	await ticks(80)
	near(first.combat.last_damage.get("raw", 0), 126.72, "empowered spark multiplies ordinary formula by 1.8")
	near(second.combat.last_damage.get("raw", 0), 126.72, "two-meter empowered explosion damages adjacent off-axis target")
	near(outside.resources.current("HP"), outside.resources.max_value("HP"), "empowered explosion excludes a target outside two meters")
	await prepare("mage", "", "apprentice_staff")
	first = target("soldier", Vector3(0, 0, -3))
	second = target("heavy_guard", Vector3(0, 0, -5))
	outside = target("fire_elemental", Vector3(0, 0, -7))
	arena.locked_target = first
	arena.aim_override = first.global_position
	arena.aim_point = first.global_position
	var wind: Dictionary = database.get_action("CASTER", "SECONDARY_TAP")
	wind["can_crit"] = false
	verify(player.combat.use_action(wind), "ordinary wind blade starts")
	await ticks(80)
	near(first.combat.last_damage.get("raw", 0), 62.2, "wind blade trades per-target damage for penetration: 0.5 weapon + INT*3.2 + PER*0.7")
	near(second.combat.last_damage.get("raw", 0), 62.2, "wind blade penetrates one target to damage a second")
	near(outside.resources.current("HP"), outside.resources.max_value("HP"), "wind blade stops before a third target")
	near(player.resources.current("Energy"), 80, "ordinary wind blade costs no energy")
	await prepare("mage", "", "apprentice_staff")
	var lateral := sin(.18) * 5
	var depth := -cos(.18) * 5
	first = target("soldier", Vector3(-lateral, 0, depth))
	second = target("heavy_guard", Vector3(0, 0, -5))
	outside = target("fire_elemental", Vector3(lateral, 0, depth))
	arena.locked_target = null
	arena.aim_override = ORIGIN + Vector3.FORWARD * 10
	arena.aim_point = arena.aim_override
	player.facing = Vector3.FORWARD
	var split: Dictionary = database.get_action("CASTER", "SECONDARY_CHARGE")
	split["can_crit"] = false
	verify(player.combat.use_action(split), "split wind blade starts")
	near(player.resources.current("Energy"), 70, "split wind blade costs 10 Energy")
	await ticks(17)
	var projectiles := 0
	for node in arena.effects.get_children():
		if node.get_script() == Attack and node.action.id == split.id:
			projectiles += 1
	verify(projectiles == 3, "split wind blade creates exactly three independent projectiles")
	await ticks(65)
	for victim in [first, second, outside]:
		near(victim.combat.last_damage.get("raw", 0), 34.21, "split projectile deals exactly 55 percent of ordinary wind blade to " + victim.enemy_id)

func check_ice_storm_ticks() -> void:
	await prepare("mage", "evoker", "apprentice_staff")
	var enemy := target("soldier", Vector3(0, 0, -5))
	var hits: Array[float] = []
	var receiver := func(amount: float): hits.append(amount)
	enemy.health.damage_received.connect(receiver)
	var action: Dictionary = database.skills.evoker_ice_storm.duplicate(true)
	action["can_crit"] = false
	verify(player.combat.use_action(action), "ice storm starts for exact tick count")
	await ticks(30)
	near(enemy.combat.movement_multiplier(), .75, "ice storm immediately applies 25 percent slow")
	await ticks(160)
	verify(enemy.combat.statuses.has_status("slow"), "successive ice storm hits refresh slow before its 1.5 second expiry")
	await ticks(100)
	verify(hits.size() == 4, "four-second ice storm applies exactly four one-second hits (actual %d)" % hits.size())
	for amount in hits:
		near(amount, 73.7, "ice storm tick uses 67 raw and evoker ten-percent resistance penetration")
	near(enemy.combat.movement_multiplier(), 1, "last ice storm slow expires after final tick plus 1.5 seconds")
	var count := hits.size()
	await ticks(90)
	verify(hits.size() == count, "completed ice storm emits no residual ticks")
	enemy.health.damage_received.disconnect(receiver)

func check_status_expiry_and_consumption() -> void:
	await prepare("mage")
	player.combat.apply_effect(database.skills.mage_shield.effects[0], player)
	near(player.health.shield, 232, "shield obtains configured pool before lifetime test")
	player.combat.statuses.tick(19.9)
	verify(player.combat.statuses.has_status("shield") and player.health.shield > 0, "shield persists before its 20-second expiry")
	player.combat.statuses.tick(.11)
	verify(not player.combat.statuses.has_status("shield"), "shield status expires after 20 seconds")
	near(player.health.shield, 0, "expiring shield clears remaining absorption pool")
	await prepare("warrior", "duelist", "hunter_dagger")
	player.combat.statuses.add_status("keen_edge", database.status_effects.keen_edge, player)
	player.combat.statuses.tick(120)
	verify(player.combat.statuses.has_status("keen_edge"), "negative-duration next-attack buff survives a two-minute idle advance")
	player.combat.statuses.consume_for(database.skills.mage_shield)
	verify(player.combat.statuses.has_status("keen_edge"), "non-damaging utility does not consume next-damage buff")
	player.combat.statuses.consume_for(database.skills.warrior_thrust)
	verify(not player.combat.statuses.has_status("keen_edge"), "next damaging action consumes permanent buff once")
	player.combat.statuses.add_status("reversal", database.status_effects.reversal, player)
	player.combat.statuses.consume_for(database.get_action("SHORT_WEAPON", "PRIMARY_TAP"))
	verify(player.combat.statuses.has_status("reversal"), "ordinary attack cannot consume skill-only reversal")
	player.combat.statuses.consume_for(database.skills.mage_fireball)
	verify(player.combat.statuses.has_status("reversal"), "caster skill cannot consume weapon-only reversal")
	player.combat.statuses.tick(3.9)
	near(player.combat.costs_for(database.skills.warrior_whirlwind).get("Energy", -1), 0, "reversal keeps weapon skill free before four seconds")
	player.combat.statuses.tick(.11)
	verify(not player.combat.statuses.has_status("reversal"), "unused reversal expires at four seconds")
	near(player.combat.costs_for(database.skills.warrior_whirlwind).get("Energy", -1), 20, "expired reversal restores original Energy cost")
	player.combat.statuses.add_status("reversal", database.status_effects.reversal, player)
	player.combat.statuses.consume_for(database.skills.warrior_whirlwind)
	near(player.combat.costs_for(database.skills.warrior_whirlwind).get("Energy", -1), 20, "consumed reversal cannot waive a second skill")

func check_control_ownership() -> void:
	await prepare("mage", "conjurer", "apprentice_staff")
	var enemy := target()
	var other := enemy_of("heavy_guard")
	var bind: Dictionary = database.skills.conjurer_bind.effects[0]
	enemy.combat.apply_effect(bind, other)
	near(enemy.combat.movement_multiplier(), 0, "binding from another source still roots a normal enemy")
	var source: Dictionary = player.combat.source_data(database.skills.mage_lightning, enemy)
	near(source.get("vulnerability_all", 0), 0, "conjurer does not receive hex bonus from another caster's control")
	enemy.combat.statuses.clear()
	enemy.combat.apply_effect(bind, player)
	source = player.combat.source_data(database.skills.mage_lightning, enemy)
	near(source.get("vulnerability_all", 0), .15, "own control grants fifteen-percent all vulnerability through hex binding")
	var probe := {"formula": {"base": 100}, "can_crit": false, "damage_type": "LIGHTNING", "presentation_type": "CASTER_ACTION"}
	var hit: Dictionary = player.combat.hit_target(enemy, probe, Vector3.FORWARD)
	near(hit.final, 115, "hex binding affects actual damage pipeline by fifteen percent")
	enemy.combat.statuses.tick(2.01)
	near(enemy.combat.movement_multiplier(), 1, "root restores movement after two seconds")
	source = player.combat.source_data(database.skills.mage_lightning, enemy)
	near(source.get("vulnerability_all", 0), 0, "hex binding expires when the owned control ends")
	var boss := target("ogre", Vector3(4, 0, -2))
	boss.combat.apply_effect(bind, player)
	verify(not boss.combat.statuses.has_status("root") and boss.combat.statuses.has_status("binding_slow"), "boss converts root to configured binding slow status")
	near(boss.combat.movement_multiplier(), .7, "boss control keeps seventy percent movement speed")
	source = player.combat.source_data(database.skills.mage_lightning, boss)
	near(source.get("vulnerability_all", 0), .15, "owned boss control also satisfies hex binding")
	boss.combat.statuses.tick(2.01)
	near(boss.combat.movement_multiplier(), 1, "boss slow expires after the same two seconds")

func check_critical_qi_cooldown() -> void:
	await prepare("barbarian", "berserker", "bone_greataxe")
	var enemy := target()
	player.resources.change("Energy", -player.resources.current("Energy"))
	var hit := {"formula": {"base": 1}, "forced_crit": true}
	var result: Dictionary = player.combat.hit_target(enemy, hit, Vector3.FORWARD)
	verify(result.crit, "battle sustain fixture is an actual guaranteed critical hit")
	near(player.resources.current("Energy"), 20, "first critical restores 20 Energy")
	player.combat.hit_target(enemy, hit, Vector3.FORWARD)
	near(player.resources.current("Energy"), 20, "second same-frame critical cannot bypass three-second passive cooldown")
	player.combat.passives.tick(2.99)
	player.combat.hit_target(enemy, hit, Vector3.FORWARD)
	near(player.resources.current("Energy"), 20, "critical at 2.99 seconds remains on cooldown")
	player.combat.passives.tick(.02)
	player.combat.hit_target(enemy, hit, Vector3.FORWARD)
	near(player.resources.current("Energy"), 40, "critical after three seconds restores 20 more Energy")
	player.combat.passives.tick(3.01)
	player.combat.hit_target(enemy, {"formula": {"base": 1}, "can_crit": false}, Vector3.FORWARD)
	near(player.resources.current("Energy"), 40, "noncritical hit never triggers battle sustain")

func check_sequence_boundaries() -> void:
	await prepare("warrior", "swordsman", "iron_longsword")
	var enemy := target()
	player.loadout.set_level(2)
	verify("sword_saint" in player.loadout.passive_ids and "sword_momentum" not in player.loadout.passive_ids, "Lv2 inherits sword saint but does not activate Lv3 momentum")
	for i in range(3):
		player.combat.hit_target(enemy, {"formula": {"base": 1}, "can_crit": false}, Vector3.FORWARD)
	near(player.combat.passives.prepare_action(database.skills.swordsman_fan_slash), 0, "three hits at Lv2 cannot award Lv3 momentum")
	player.loadout.set_level(3)
	for i in range(3):
		player.combat.hit_target(enemy, {"formula": {"base": 1}, "can_crit": false}, Vector3.FORWARD)
	near(player.combat.passives.prepare_action(database.get_action("SINGLE_BLADE", "PRIMARY_TAP")), 0, "ordinary attack cannot spend three-hit skill bonus")
	near(player.combat.passives.prepare_action(database.skills.mage_fireball), 0, "caster action cannot spend weapon-only momentum")
	near(player.combat.passives.prepare_action(database.skills.swordsman_fan_slash), .2, "valid weapon skill consumes the ready twenty-percent momentum")
	near(player.combat.passives.prepare_action(database.skills.swordsman_fan_slash), 0, "momentum cannot award its bonus twice")
	await prepare("mage", "evoker", "apprentice_staff")
	player.loadout.set_level(2)
	for id in ["mage_fireball", "mage_earth_spike", "mage_lightning"]:
		near(player.combat.passives.prepare_action(database.skills[id]), 0, "Lv2 excludes elemental overload for " + id)
	player.loadout.set_level(3)
	player.combat.passives.reset_combat()
	near(player.combat.passives.prepare_action(database.skills.mage_fireball), 0, "first fire element has no overload bonus")
	near(player.combat.passives.prepare_action(database.skills.mage_fireball), 0, "repeated same element restarts sequence")
	near(player.combat.passives.prepare_action(database.skills.mage_earth_spike), 0, "second distinct element does not trigger early")
	near(player.combat.passives.prepare_action(database.skills.mage_lightning), .25, "third distinct element triggers twenty-five percent after repeat reset")
	near(player.combat.passives.prepare_action(database.skills.evoker_ice_storm), 0, "next different element starts a new overload sequence")

func check_remaining_passive_values() -> void:
	await prepare("barbarian", "berserker", "bone_greataxe")
	var enemy := target()
	var physical := {"presentation_type": "WEAPON_ACTION", "damage_type": "PHYSICAL", "animation_family": "HEAVY_2H"}
	near(player.combat.source_data(physical, enemy).crit_chance, .05, "last stand is inactive at full HP")
	player.resources.change("HP", -player.resources.current("HP") * .75)
	near(player.combat.source_data(physical, enemy).crit_chance, .20, "last stand adds fifteen percentage points below thirty-percent HP")
	near(player.combat.max_poise(), 171, "Lv3 unyielding rage adds forty poise to barbarian 131")
	near(player.combat.source_data(physical, enemy).crit_multiplier, 1.5, "bone axe has ordinary multiplier against healthy target")
	enemy.resources.change("HP", -enemy.resources.current("HP") * .75)
	near(player.combat.source_data(physical, enemy).crit_multiplier, 1.75, "bone axe adds quarter critical multiplier against low-HP target")
	await prepare("warrior", "swordsman", "iron_longsword")
	enemy = target()
	var sword := {"presentation_type": "WEAPON_ACTION", "animation_family": "SINGLE_BLADE"}
	near(player.combat.source_data(sword, enemy).crit_chance, .15, "sword saint adds ten percentage points to single-blade action")
	near(player.combat.source_data(sword, enemy).crit_multiplier, 1.85, "sword saint adds exactly 0.35 critical multiplier")
	var dagger := {"presentation_type": "WEAPON_ACTION", "animation_family": "SHORT_WEAPON"}
	near(player.combat.source_data(dagger, enemy).crit_chance, .05, "sword saint stays inactive for a different action family")
	player.loadout.equip_item("ring1", "hunter_ring")
	near(player.combat.source_data(sword, enemy).damage_bonus, 0, "hunter instinct is inactive above execution threshold")
	enemy.resources.change("HP", -enemy.resources.current("HP") * .75)
	near(player.combat.source_data(sword, enemy).damage_bonus, .15, "hunter instinct adds fifteen-percent damage against low-HP target")
	await prepare("rogue", "ranger", "shortbow")
	enemy = target("soldier", Vector3(0, 0, -8))
	near(player.combat.source_data(database.skills.rogue_precision_shot, enemy).crit_chance, .05, "eagle eye excludes exactly eight meters")
	enemy.global_position = player.global_position + Vector3.FORWARD * 8.1
	near(player.combat.source_data(database.skills.rogue_precision_shot, enemy).crit_chance, .17, "eagle eye adds twelve percentage points beyond eight meters")
	await prepare("mage", "", "apprentice_staff")
	enemy = target()
	player.loadout.equip_item("neck", "scholar_pendant")
	var source: Dictionary = player.combat.source_data(database.skills.mage_fireball, enemy)
	near(source.get("resistance_penetration", 0), .10, "elemental piercing applies ten percent to elemental spell")
	near(source.damage_bonus, 0, "adverse casting is inactive at high HP")
	player.resources.change("HP", -player.resources.current("HP") * .75)
	source = player.combat.source_data(database.skills.mage_fireball, enemy)
	near(source.damage_bonus, .15, "adverse casting adds fifteen-percent spell damage at low HP")
	source = player.combat.source_data(physical, enemy)
	near(source.damage_bonus, 0, "adverse casting excludes physical weapon actions")
	near(source.get("resistance_penetration", 0), 0, "elemental piercing excludes physical weapon actions")
	player.combat.reset()
	verify(player.combat.use_action(database.skills.mage_lightning), "staff spell begins for range verification")
	near(player.combat.runner.current_action.range, 14.7, "apprentice staff adds five percent to fourteen-meter spell range")
	await prepare("mage", "evoker", "apprentice_staff")
	enemy = target()
	verify(player.combat.use_action(database.skills.evoker_ice_storm), "evocation area spell begins")
	near(player.combat.runner.current_action.radius, 4.025, "evocation mastery increases 3.5-meter area radius by fifteen percent")
	near(player.combat.source_data(database.skills.evoker_ice_storm, enemy).get("resistance_penetration", 0), .10, "evocation mastery independently grants ten-percent elemental penetration")
	await prepare("warrior", "duelist", "hunter_dagger")
	enemy = target()
	player.combat.passives.trigger("perfect_dodge", player.combat.context(enemy))
	verify(player.combat.statuses.has_status("reversal"), "perfect dodge event activates duelist reversal")
	player.combat.statuses.remove_status("reversal")
	player.combat.passives.tick(4.99)
	player.combat.passives.trigger("perfect_dodge", player.combat.context(enemy))
	verify(not player.combat.statuses.has_status("reversal"), "duelist reversal internal cooldown lasts five seconds")
	player.combat.passives.tick(.02)
	player.combat.passives.trigger("perfect_dodge", player.combat.context(enemy))
	verify(player.combat.statuses.has_status("reversal"), "duelist reversal reactivates after five-second internal cooldown")
	await prepare("rogue", "shadowblade", "hunter_dagger")
	enemy = target()
	player.combat.passives.trigger("perfect_dodge", player.combat.context(enemy))
	verify(player.combat.statuses.has_status("stealth"), "Lv3 shadow escape grants stealth on perfect dodge event")
	near(player.combat.statuses.entries.stealth.remaining, 1.5, "shadow escape stealth lasts exactly 1.5 seconds")
	player.combat.statuses.remove_status("stealth")
	player.combat.passives.tick(5.99)
	player.combat.passives.trigger("perfect_dodge", player.combat.context(enemy))
	verify(not player.combat.statuses.has_status("stealth"), "shadow escape cannot bypass six-second internal cooldown")
	player.combat.passives.tick(.02)
	player.combat.passives.trigger("perfect_dodge", player.combat.context(enemy))
	verify(player.combat.statuses.has_status("stealth"), "shadow escape reactivates after six-second cooldown")

func check_status_stack_rules() -> void:
	await prepare("warrior")
	var status: Node = player.combat.statuses
	var stacked := {"duration": 2, "stack_rule": "stack", "max_stacks": 2, "effects": [{"type": "modifier", "stat": "crit_chance", "value": .10}]}
	for i in range(3):
		status.add_status("stack_test", stacked, player)
	verify(status.entries.stack_test.stacks == 2, "stack rule caps at declared maximum two stacks")
	near(status.modifiers().get("crit_chance", 0), .20, "stacked modifiers multiply by current stack count")
	status.tick(1.1)
	status.add_status("stack_test", stacked, player)
	near(status.entries.stack_test.remaining, 2, "reapplying stack refreshes duration without exceeding cap")
	status.clear()
	var refresh := {"duration": 2, "stack_rule": "refresh", "effects": [{"type": "modifier", "stat": "damage_bonus", "value": .2}]}
	status.add_status("refresh_test", refresh, player)
	status.tick(1.5)
	status.add_status("refresh_test", refresh, player)
	near(status.entries.refresh_test.remaining, 2, "refresh rule resets full duration")
	near(status.modifiers().get("damage_bonus", 0), .2, "refresh rule never doubles its modifier")
	status.clear()
	var ignored := {"duration": 5, "stack_rule": "ignore", "effects": [{"type": "modifier", "stat": "damage_bonus", "value": .1}]}
	status.add_status("ignore_test", ignored, player)
	status.tick(1)
	var replacement: Dictionary = ignored.duplicate(true)
	replacement.duration = 10
	replacement.effects[0].value = .8
	status.add_status("ignore_test", replacement, player)
	near(status.entries.ignore_test.remaining, 4, "ignore rule preserves original remaining duration")
	near(status.modifiers().get("damage_bonus", 0), .1, "ignore rule preserves original strength")
	replacement.stack_rule = "replace"
	status.add_status("ignore_test", replacement, player)
	near(status.entries.ignore_test.remaining, 10, "replace rule installs replacement lifetime")
	near(status.modifiers().get("damage_bonus", 0), .8, "replace rule installs replacement strength")
	status.clear()
	var conditional := {"duration": 10, "conditions": [{"type": "self_hp", "op": "<", "value": .3}], "effects": [{"type": "modifier", "stat": "damage_bonus", "value": .25}]}
	status.add_status("conditional_test", conditional, player)
	near(status.modifiers().get("damage_bonus", 0), 0, "status modifier remains inactive while its live condition fails")
	player.resources.change("HP", -player.resources.current("HP") * .75)
	near(status.modifiers().get("damage_bonus", 0), .25, "status live condition activates when HP enters threshold")
	player.resources.restore_all()
	near(status.modifiers().get("damage_bonus", 0), 0, "status live condition deactivates after HP recovery")
	status.clear()
	player.resources.change("Energy", -player.resources.current("Energy"))
	var conditional_tick := {"duration": 3, "tick_interval": 1, "conditions": [{"type": "resource", "resource": "Energy", "op": "<", "value": 40}], "tick_effects": [{"type": "resource", "resource": "Energy", "amount": 20}]}
	status.add_status("conditional_tick", conditional_tick, player)
	status.tick(3.01)
	near(player.resources.current("Energy"), 40, "tick conditions are reevaluated and stop effect after resource threshold")
	verify(not status.has_status("conditional_tick"), "large time step executes due ticks and then expires status")
	var dot := {"duration": 1, "tick_interval": 1, "stack_rule": "stack", "max_stacks": 3, "tick_damage": {"formula": {"base": 5}, "damage_type": "PHYSICAL", "can_crit": false, "is_dot": true}}
	var hostile_source := target()
	status.add_status("stacked_dot", dot, hostile_source)
	status.add_status("stacked_dot", dot, hostile_source)
	var hp: float = player.resources.current("HP")
	status.tick(1.01)
	near(player.resources.current("HP"), hp - 10, "stacked DOT multiplies damage by two without altering shared formula")
