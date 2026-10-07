extends SceneTree
## Exercises real actors, physics, InputMap, combat instances and shipped JSON.
## Godot --headless --path . --fixed-fps 60 --script tests/combat_integration.gd

const Attack = preload("res://combat/attack_instance.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
var arena: Node
var player: Node
var database: RefCounted
var checks := 0
var failures: Array[String] = []
var started: Array[Dictionary] = []
var semantics: Array[String] = []
var perfect_events := 0
const ORIGIN := Vector3(0, 0.1, 6)

func _initialize() -> void:
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-combat-integration-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
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

func near(actual: float, expected: float, label: String, tolerance := 0.01) -> void:
	verify(absf(actual - expected) <= tolerance, "%s (%.4f / %.4f)" % [label, actual, expected])

func record_action(action: Dictionary) -> void:
	var observed := action.duplicate(true)
	observed["_observed_clock"] = player.input_router.clock
	started.append(observed)

func press(action: String, count := 2) -> void:
	Input.action_press(action)
	await ticks(count)
	Input.action_release(action)
	await ticks(2)

func clear_attacks() -> void:
	for node in arena.effects.get_children():
		if node.get_script() == Attack:
			node.queue_free()

func prepare(career := "warrior") -> void:
	for action in InputMap.get_actions():
		Input.action_release(action)
	clear_attacks()
	player.resources.unlimited.clear()
	player.loadout.select_career(career)
	player.combat.reset()
	player.global_position = ORIGIN
	player.velocity = Vector3.ZERO
	player.facing = Vector3.FORWARD
	arena.aim_point = ORIGIN + Vector3.FORWARD * 10
	arena.aim_override = arena.aim_point
	arena.locked_target = null
	if is_instance_valid(arena.ui):
		arena.ui.toggle_menu(false)
	arena.input_blocked = false
	for enemy in arena.enemies:
		if is_instance_valid(enemy):
			enemy.ai_enabled = false
			enemy.combat.reset()
			enemy.global_position = Vector3(18, .1, 18)
	started.clear()
	semantics.clear()
	await ticks(3)

func enemy_of(id: String) -> Node:
	for enemy in arena.enemies:
		if is_instance_valid(enemy) and enemy.enemy_id == id:
			return enemy
	var enemy: Node = arena.spawn_enemy(id, Vector3(18, .1, 18))
	enemy.ai_enabled = false
	return enemy

func place_enemy(id := "soldier", offset := Vector3(0, 0, -2)) -> Node:
	var enemy := enemy_of(id)
	enemy.combat.reset()
	enemy.global_position = player.global_position + offset
	enemy.velocity = Vector3.ZERO
	enemy.facing = Vector3.BACK
	return enemy

func settle_action() -> void:
	for i in range(150):
		if player.combat.can_start():
			break
		await ticks(1)

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
	# Keep world aiming deterministic while leaving actor physics and combat active.
	arena.set_process(false)
	player = arena.player
	database = arena.database
	player.combat.runner.action_started.connect(record_action)
	player.input_router.command.connect(func(kind: String): semantics.append(kind))
	player.combat.perfect_dodge.connect(func(): perfect_events += 1)
	verify(player.loadout.level == 0, "arena starts at Lv0 for base career choice")
	verify(arena.enemies.size() >= 4, "arena contains all four test enemy types")
	await check_careers_and_equipment()
	await check_inputs_and_cooldowns()
	await check_dodge_and_damage()
	await check_statuses_and_passives()
	await check_projectiles_and_zones()
	await check_constraints_and_sequences()
	await check_active_windows_targeting_and_ai()
	await check_snapshots_and_runtime_modifiers()
	await check_configured_resource_policies()
	for action in InputMap.get_actions():
		Input.action_release(action)
	print("COMBAT_INTEGRATION: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures:
		printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)

func check_careers_and_equipment() -> void:
	var expected := {"warrior": [1070, 60, 3, 99], "rogue": [840, 60, 3, 70], "barbarian": [1236, 80, 4, 131], "mage": [720, 60, 2, 53]}
	for career in expected:
		await prepare(career)
		verify(player.loadout.level == 1 and career in player.loadout.career_ids, career + " selection reaches Lv1")
		for i in range(3):
			var resource: String = ["HP", "Energy", "Stamina"][i]
			near(player.resources.max_value(resource), expected[career][i], career + " " + resource + " formula")
		near(player.combat.base_poise, expected[career][3], career + " poise formula")
		var subclass: String = database.careers[career].next_careers[0]
		verify(not player.loadout.select_career(subclass), career + " subclass blocked before Lv2")
		player.loadout.set_level(2)
		verify(player.loadout.select_career(subclass), career + " subclass allowed at Lv2")
		verify(database.careers[subclass].skills[0] in player.loadout.unlocked_skills and database.careers[career].skills[0] in player.loadout.unlocked_skills, "subclass keeps base skills and automatically opens new skills")
		player.loadout.set_level(3)
		near(player.resources.max_value("HP"), float(expected[career][0]) + {"warrior": 100, "rogue": 90, "barbarian": 120, "mage": 70}[career], career + " Lv3 HP growth")
		near(player.resources.max_value("Energy"), float(expected[career][1]) + 20, career + " Lv3 continuous Energy growth")
	await prepare()
	verify(player.loadout.equipment.size() == 8, "all eight equipment slots exist")
	verify(not player.loadout.equip_weapon(0, "bone_greataxe"), "career proficiency prevents heavy axe equipment")
	verify(player.loadout.equip_item("head", "iron_helm"), "qualified character equips required helmet")
	near(player.stats.get_final_stat("Armor"), 8, "equipment modifies armor")
	verify("steadfast" in player.loadout.passive_ids, "equipment automatically grants passive")
	near(player.combat.max_poise(), 119, "steadfast adds poise above 80 percent HP")
	player.resources.change("HP", -player.resources.current("HP") * .3)
	near(player.combat.max_poise(), 99, "conditional passive updates as HP changes")
	verify(player.loadout.equip_item("head", "scout_hood"), "head appearance can be replaced")
	near(player.stats.get_final_stat("Armor"), 0, "replacing equipment removes old stat modifier")
	verify("steadfast" not in player.loadout.passive_ids, "unequipped item passive is removed")
	for pair in [["torso", "linen_tunic"], ["legs", "traveler_pants"], ["feet", "soft_shoes"], ["belt", "vigor_belt"], ["ring1", "qi_ring"], ["ring2", "hunter_ring"], ["neck", "scholar_pendant"]]:
		verify(player.loadout.equip_item(pair[0], pair[1]), "equips visual/stat slot " + pair[0])
	near(player.resources.max_value("HP"), 1100, "CON equipment recomputes career HP formula")
	verify(not player.loadout.equip_item("ring2", "qi_ring"), "one physical ring cannot occupy both ring slots")
	await prepare("mage")
	verify(not player.loadout.equip_item("head", "iron_helm"), "insufficient CON rejects helmet before mutation")

func check_inputs_and_cooldowns() -> void:
	await prepare()
	for action in ["move_up", "move_down", "move_left", "move_right", "attack_primary", "attack_secondary", "skill_q", "skill_e", "skill_r", "dodge_dash", "switch_combat_set", "interact", "quick_item_1", "quick_item_2", "quick_item_3", "quick_item_4", "lock_target"]:
		verify(InputMap.has_action(action) and not InputMap.action_get_events(action).is_empty(), "InputMap binding " + action)
	for action in ["move_up", "move_down", "move_left", "move_right"]:
		var before: Vector3 = player.global_position
		await press(action, 8)
		verify(player.global_position.distance_to(before) > .25, action + " moves the real CharacterBody")
	await prepare()
	await press("attack_primary")
	verify(started.size() == 1 and started[0].semantic == "PRIMARY_TAP", "short left press starts only ordinary attack")
	await ticks(6)
	await press("attack_primary")
	for _frame in range(90):
		if started.size() >= 2: break
		await ticks(1)
	verify(started.size() >= 2 and int(started[1].combo_index) == 1, "buffered input advances A1 to A2 only at its recovery gate")
	if started.size() >= 2:
		var first_gate: float = float(started[0].startup) + float(started[0].active) + float(started[0].recovery) - minf(float(started[0].get("combo_window", .08)), float(started[0].recovery) * .35)
		var first_interval: float = float(started[1]._observed_clock) - float(started[0]._observed_clock)
		verify(first_interval + 1.0 / 60.0 >= first_gate, "A2 does not bypass the measured A1 recovery gate")
		verify(first_interval <= first_gate + 2.0 / 60.0, "queued A2 starts promptly at the gate, before A1 fully finishes")
		await press("attack_primary")
		for _frame in range(90):
			if started.size() >= 3: break
			await ticks(1)
		verify(started.size() >= 3 and int(started[2].combo_index) == 2, "buffered combo follows the fixed A1 A2 A3 sequence")
		if started.size() >= 3:
			var second_gate: float = float(started[1].startup) + float(started[1].active) + float(started[1].recovery) - minf(float(started[1].get("combo_window", .08)), float(started[1].recovery) * .35)
			var second_interval: float = float(started[2]._observed_clock) - float(started[1]._observed_clock)
			verify(second_interval + 1.0 / 60.0 >= second_gate, "A3 does not bypass the measured A2 recovery gate")
			verify(second_interval <= second_gate + 2.0 / 60.0, "queued A3 starts promptly at the gate, before A2 fully finishes")
	await settle_action()
	await ticks(50)
	verify(started.size() == 3, "each buffered input is consumed once and stopping input does not replay")
	await prepare()
	await press("attack_primary", 18)
	verify(semantics.count("PRIMARY_CHARGE") == 1 and semantics.count("PRIMARY_TAP") == 0, "long left press never emits tap as well")
	verify(started.size() == 1 and started[0].semantic == "PRIMARY_CHARGE", "left hold launches charged action")
	await settle_action()
	verify(player.loadout.shield().is_empty(), "ordinary warrior has only A/B weapon groups")
	await press("attack_secondary")
	verify(not started.is_empty() and started.back().get("semantic", "") == "SECONDARY_TAP", "right short press launches sword special action")
	await settle_action()
	await press("attack_secondary", 18)
	verify(not started.is_empty() and started.back().get("semantic", "") == "SECONDARY_CHARGE" and semantics.count("SECONDARY_CHARGE") == 1, "right hold launches only sword special charge")
	await prepare()
	var enemy := place_enemy("soldier", Vector3(0, 0, -1.4))
	arena.locked_target = enemy
	var hp: float = enemy.resources.current("HP")
	await press("attack_primary")
	await ticks(30)
	verify(enemy.resources.current("HP") < hp, "ordinary InputMap attack reaches live enemy health")
	verify(float(enemy.combat.last_damage.raw) == 80, "ordinary attack uses equipped sword scaling and stats")
	var after_hit: float = enemy.resources.current("HP")
	await ticks(30)
	near(enemy.resources.current("HP"), after_hit, "single swing cannot damage target repeatedly")
	await prepare()
	verify(player.loadout.assign_skill(1, 1, "warrior_whirlwind"), "same skill may be assigned across groups and slots")
	await press("skill_q")
	verify(player.combat.cooldowns.get("warrior_whirlwind", 0) > 4 and is_equal_approx(player.resources.current("Energy"), 40.0), "Q pays warrior whirlwind's authored 20 Energy once and starts its Skill ID cooldown")
	verify(not player.combat.switch_set(), "cannot switch while an action is running")
	await settle_action()
	await press("switch_combat_set")
	verify(player.loadout.current_set == 1 and player.combat.state == "SWITCH", "Shift swaps full group and enters 0.35 second switch")
	verify(not player.combat.weapon_action("PRIMARY_TAP"), "switch period prevents overlapping actions")
	await ticks(24)
	verify(player.animation.weapon_family == "SHORT_WEAPON", "switch changes weapon animation family")
	var before_count := started.size()
	await press("skill_e")
	verify(started.size() == before_count and player.combat.last_condition_failed.contains("冷却"), "duplicate skill in B shares A skill cooldown")
	player.combat.cooldowns.clear()
	await press("skill_e")
	verify(started.size() == before_count + 1, "E operates independently after shared cooldown reset")
	await settle_action()
	await press("skill_r")
	verify(not started.is_empty() and started.back().id == "warrior_impact", "R uses current group's third skill")
	await prepare()
	player.resources.change("HP", -500)
	await press("quick_item_1")
	near(player.resources.current("HP"), 891, "quick slot 1 heals 30 percent of maximum HP")
	player.resources.change("Energy", -45)
	await press("quick_item_2")
	near(player.resources.current("Energy"), 55, "quick slot 2 restores forty shared Energy")
	await prepare("mage")
	player.resources.change("Energy", -30)
	await press("quick_item_3")
	near(player.resources.current("Energy"), 50, "quick slot 3 restores twenty shared Energy")
	enemy = place_enemy()
	arena.aim_point = enemy.global_position
	arena.aim_override = arena.aim_point
	hp = enemy.resources.current("HP")
	await press("quick_item_4")
	verify(enemy.resources.current("HP") < hp and player.combat.quick_counts[3] == 4, "quick slot 4 creates a damaging fire bomb")

func check_dodge_and_damage() -> void:
	await prepare()
	var enemy := place_enemy("soldier", Vector3(0, 0, -6))
	var start: Vector3 = player.global_position
	await press("dodge_dash")
	verify(player.combat.dodge_is_dash and not player.combat.invulnerable(), "out-of-combat Space creates dash without invulnerability")
	near(player.resources.current("Stamina"), 3, "dash consumes no stamina")
	await ticks(28)
	verify(player.global_position.distance_to(start) > 3, "dash causes real displacement")
	await prepare()
	enemy = place_enemy("soldier", Vector3(0, 0, -6))
	player.loadout.equip_item("ring1", "qi_ring")
	player.resources.change("Energy", -40)
	player.combat.in_combat = true
	player.combat.combat_timeout = 1000
	player.combat.engage()
	await press("dodge_dash", 1)
	near(player.resources.current("Stamina"), 2, "combat dodge pays one stamina at start")
	var hp: float = player.resources.current("HP")
	var poise: float = player.combat.current_poise
	var events := perfect_events
	var incoming := {"formula": {"base": 100}, "can_crit": false, "poise_damage": 1000, "knockback_force": 20, "effects": [{"type": "status", "status": "burn"}]}
	var result: Dictionary = player.combat.receive_damage(incoming, enemy, Vector3.BACK)
	verify(result.blocked and perfect_events == events + 1, "an actual incoming hit triggers perfect dodge event")
	near(player.resources.current("Stamina"), 3, "perfect dodge returns the stamina just spent")
	near(player.resources.current("Energy"), 40, "perfect dodge activates the equipped Energy-reflux passive")
	player.combat.receive_damage(incoming, enemy, Vector3.BACK)
	verify(perfect_events == events + 1, "one dodge cannot refund multiple times")
	near(player.resources.current("HP"), hp, "invulnerability blocks HP damage")
	near(player.combat.current_poise, poise, "invulnerability blocks poise damage")
	verify(not player.combat.statuses.has_status("burn") and player.combat.knockback == Vector3.ZERO, "invulnerability blocks statuses and knockback")
	await ticks(13)
	verify(not player.combat.invulnerable() and player.combat.state == "DODGE", "invulnerability ends before dodge recovery")
	player.combat.receive_damage({"formula": {"base": 100}, "can_crit": false}, enemy, Vector3.BACK)
	near(player.resources.current("HP"), hp - 100, "late dodge recovery can take damage")
	await prepare()
	enemy = place_enemy()
	var ordinary := {"formula": {"base": 20}, "can_crit": false, "poise_damage": 90, "knockback_force": 3, "launch_force": 6, "knockdown": true}
	player.combat.hit_target(enemy, ordinary, Vector3.FORWARD)
	verify(enemy.combat.state == "KNOCKDOWN" and enemy.velocity.y > 0 and enemy.combat.knockback.length() > 0, "poise break applies knockdown launch and knockback to normal enemy")
	var boss := place_enemy("ogre", Vector3(3, 0, -2))
	boss.combat.current_poise = 20
	player.combat.hit_target(boss, ordinary, Vector3.FORWARD)
	verify(boss.combat.state == "HITSTUN" and boss.velocity.y <= 0, "boss launch and knockdown immunities preserve ordinary hitstun")
	verify(boss.resources.current("HP") < boss.resources.max_value("HP"), "boss immunity does not prevent damage")
	await prepare()
	enemy = place_enemy()
	player.combat.hit_target(enemy, {"formula": {"base": 1}, "can_crit": false, "poise_damage": 10}, Vector3.FORWARD)
	await ticks(60)
	near(enemy.combat.current_poise, 70, "poise does not recover before 1.2 seconds")
	await ticks(40)
	near(enemy.combat.current_poise, 80, "poise rapidly recovers after quiet interval")
	await ticks(230)
	verify(not player.combat.in_combat and player.combat.first_damage, "five quiet seconds ends combat and resets first strike")

func check_statuses_and_passives() -> void:
	await prepare("barbarian")
	var enemy := place_enemy()
	player.resources.change("Energy", -70)
	player.combat.in_combat = true
	player.combat.combat_timeout = 1000
	var hp: float = player.resources.current("HP")
	verify(player.combat.use_action(database.skills.barbarian_blood_rage), "blood rage starts as a cost-free action before its effects")
	await ticks(14)
	near(player.resources.current("HP"), hp * .92, "blood rage costs eight percent of current HP")
	near(player.resources.current("Energy"), 50, "blood rage's effect restores forty shared Energy")
	var source: Dictionary = player.combat.source_data({"presentation_type": "WEAPON_ACTION"}, enemy)
	near(source.get("damage_bonus", 0), .2, "blood rage status contributes twenty percent damage")
	await prepare("mage")
	enemy = place_enemy()
	enemy.combat.apply_effect({"type": "status", "status": "slow"}, player)
	near(enemy.combat.movement_multiplier(), .75, "slow status reduces movement by 25 percent")
	await ticks(95)
	near(enemy.combat.movement_multiplier(), 1, "slow expires and restores movement")
	enemy.combat.apply_effect({"type": "status", "status": "burn"}, player)
	hp = enemy.resources.current("HP")
	await ticks(184)
	near(enemy.resources.current("HP"), hp - 72, "burn deals exactly three noncritical 10+INT ticks")
	verify(not enemy.combat.statuses.has_status("burn"), "burn expires after final duration tick")
	verify(player.combat.use_action(database.skills.mage_shield), "arcane shield is usable")
	await ticks(15)
	near(player.health.shield, 232, "shield formula reads caster INT")
	hp = player.resources.current("HP")
	player.combat.receive_damage({"formula": {"base": 100}, "can_crit": false}, enemy, Vector3.BACK)
	near(player.resources.current("HP"), hp, "shield absorbs damage before HP")
	near(player.health.shield, 132, "shield pool is reduced by absorbed amount")
	await prepare()
	enemy = place_enemy()
	player.loadout.equip_weapon(0, "azure_katana")
	player.combat.engage()
	player.combat.start_dodge()
	player.combat.receive_damage({"formula": {"base": 1}}, enemy, Vector3.BACK)
	await ticks(30)
	verify(player.combat.statuses.has_status("keen_edge"), "perfect-dodge katana buff persists until next damage attack")
	source = player.combat.source_data({"presentation_type": "WEAPON_ACTION"}, enemy)
	near(source.get("crit_chance", 0), .20, "katana next-attack crit bonus contributes fifteen points")
	await press("attack_primary")
	await ticks(30)
	verify(not player.combat.statuses.has_status("keen_edge"), "next damage attack consumes katana buff")
	await prepare("barbarian")
	enemy = place_enemy()
	player.loadout.equip_weapon(0, "border_spear")
	source = player.combat.source_data({}, enemy)
	near(source.get("poise_damage_bonus", 0), .1, "spear special effect increases poise damage")
	player.loadout.set_level(3)
	player.loadout.select_career("berserker")
	player.resources.change("HP", -player.resources.current("HP") * .75)
	near(player.combat.target_data().get("damage_taken_bonus", 0), .1, "low-HP berserker correctly takes ten percent extra damage")
	await prepare("mage")
	enemy = place_enemy()
	player.loadout.equip_weapon(0, "storm_orb")
	source = player.combat.source_data(database.skills.mage_lightning, enemy)
	near(source.get("resistance_penetration", 0), .1, "storm orb penetrates lightning resistance")
	source = player.combat.source_data(database.skills.mage_fireball, enemy)
	near(source.get("resistance_penetration", 0), 0, "storm orb does not penetrate unrelated elements")
	player.loadout.set_level(2)
	player.loadout.select_career("conjurer")
	enemy.combat.apply_effect(database.skills.conjurer_bind.effects[0], player)
	near(enemy.combat.movement_multiplier(), 0, "binding roots ordinary enemies")
	var context: Dictionary = player.combat.context(enemy, database.skills.mage_lightning)
	verify("controlled_by_self" in context.target_statuses, "control marker identifies owning caster for hex binding")
	var boss := place_enemy("ogre", Vector3(4, 0, -2))
	boss.combat.apply_effect(database.skills.conjurer_bind.effects[0], player)
	near(boss.combat.movement_multiplier(), .7, "binding slows boss by thirty percent instead of rooting")

func check_projectiles_and_zones() -> void:
	await prepare("rogue")
	player.loadout.set_level(2)
	player.loadout.select_career("ranger")
	player.loadout.equip_weapon(0, "shortbow")
	var first := place_enemy("soldier", Vector3(0, 0, -3))
	var second := place_enemy("heavy_guard", Vector3(0, 0, -5))
	arena.aim_point = player.global_position + Vector3.FORWARD * 10
	arena.aim_override = arena.aim_point
	var hp1: float = first.resources.current("HP")
	var hp2: float = second.resources.current("HP")
	verify(player.combat.use_action(database.skills.ranger_piercing_arrow), "ranger can cast penetrating arrow")
	await ticks(60)
	verify(first.resources.current("HP") < hp1 and second.resources.current("HP") < hp2, "actual moving projectile penetrates two targets")
	await prepare("rogue")
	player.loadout.set_level(2)
	player.loadout.select_career("ranger")
	player.loadout.equip_weapon(0, "shortbow")
	first = place_enemy("soldier", Vector3(0, 0, -5))
	arena.aim_point = first.global_position
	arena.aim_override = arena.aim_point
	var hits: Array = []
	first.health.damage_received.connect(func(amount: float): hits.append(amount))
	verify(player.combat.use_action(database.skills.ranger_arrow_rain), "ranger arrow rain begins")
	await ticks(205)
	verify(hits.size() == 3, "arrow rain applies exactly three waves to stationary target")
	await prepare("mage")
	player.loadout.set_level(2)
	player.loadout.select_career("evoker")
	first = place_enemy("soldier", Vector3(0, 0, -5))
	second = place_enemy("heavy_guard", Vector3(2.5, 0, -5))
	arena.aim_point = first.global_position
	arena.aim_override = arena.aim_point
	hp2 = second.resources.current("HP")
	var wall_hits: Array = []
	first.health.damage_received.connect(func(amount: float): wall_hits.append(amount))
	verify(player.combat.use_action(database.skills.evoker_fire_wall), "evoker fire wall begins")
	await ticks(385)
	verify(first.resources.current("HP") < first.resources.max_value("HP"), "fire wall damages a target in its line")
	verify(wall_hits.size() == 12, "six-second fire wall ticks exactly twelve times at half-second intervals (actual %d)" % wall_hits.size())
	near(second.resources.current("HP"), hp2, "fire wall does not act as a circle outside its line width")

func check_constraints_and_sequences() -> void:
	await prepare("barbarian")
	await press("attack_primary")
	await press("attack_primary")
	for _frame in range(120):
		if started.size() >= 2: break
		await ticks(1)
	verify(started.size() == 2 and int(started[1].combo_index) == 1, "heavy-weapon buffered tap survives until its late A2 combo gate")
	if started.size() >= 2:
		var heavy_gate: float = float(started[0].startup) + float(started[0].active) + float(started[0].recovery) - minf(float(started[0].get("combo_window", .08)), float(started[0].recovery) * .35)
		var heavy_interval: float = float(started[1]._observed_clock) - float(started[0]._observed_clock)
		verify(heavy_interval + 1.0 / 60.0 >= heavy_gate, "heavy A2 respects its measured late recovery gate")
		verify(heavy_interval <= heavy_gate + 2.0 / 60.0, "queued heavy A2 starts at its gate instead of waiting for full recovery")
	await settle_action()
	await ticks(40)
	verify(started.size() == 2, "heavy buffered tap executes once and does not replay after release")
	await prepare("mage")
	var mage_energy: float = player.resources.current("Energy")
	await press("attack_primary")
	near(player.resources.current("Energy"), mage_energy, "ordinary caster primary tap is free")
	await settle_action()
	await press("attack_primary", 18)
	verify(started.back().id == "caster_primary_charge_1" and is_equal_approx(float(started.back().costs.get("Energy", 0.0)), 10.0), "enhanced caster primary is the authored ten-Energy charged action")
	near(player.resources.current("Energy"), mage_energy - 10.0, "enhanced caster primary pays one ten-Energy cost")
	await settle_action()
	player.resources.change("Energy", -player.resources.current("Energy") + 9.0)
	var enemy := place_enemy()
	arena.locked_target = enemy
	var before := started.size()
	await press("skill_e")
	verify(started.size() == before and not player.combat.cooldowns.has("mage_lightning"), "nine Energy cannot pay the ten-Energy mage lightning action or start cooldown")
	await prepare()
	player.loadout.current_set = 1
	var energy_before_rejection: float = player.resources.current("Energy")
	verify(not player.combat.use_action(database.skills.warrior_sword_wave), "single-blade skill rejects dagger before release")
	near(player.resources.current("Energy"), energy_before_rejection, "failed weapon condition never consumes Energy")
	await prepare()
	player.loadout.set_level(2)
	player.loadout.select_career("duelist")
	player.loadout.equip_weapon(0, "hunter_dagger")
	enemy = place_enemy()
	arena.locked_target = enemy
	verify(not player.combat.use_action(database.skills.duelist_finisher), "execution rejects target at full HP")
	enemy.resources.change("HP", -enemy.resources.max_value("HP") * .75)
	verify(player.combat.use_action(database.skills.duelist_finisher), "execution accepts target below 30 percent HP")
	await settle_action()
	player.combat.cooldowns.clear()
	player.combat.statuses.add_status("reversal", database.status_effects.reversal, player)
	await press("attack_primary")
	await settle_action()
	verify(player.combat.statuses.has_status("reversal"), "ordinary weapon attack does not consume skill-only reversal")
	player.resources.change("Energy", -player.resources.current("Energy"))
	verify(player.combat.use_action(database.skills.warrior_whirlwind), "reversal permits next weapon skill with zero Energy")
	await settle_action()
	verify(not player.combat.statuses.has_status("reversal"), "weapon skill consumes reversal once")
	await prepare("rogue")
	player.loadout.set_level(2)
	player.loadout.select_career("shadowblade")
	enemy = place_enemy()
	player.combat.first_damage = false
	enemy.facing = Vector3.FORWARD
	var hit := {"formula": {"base": 100}, "presentation_type": "WEAPON_ACTION"}
	var result: Dictionary = player.combat.hit_target(enemy, hit, Vector3.FORWARD)
	verify(result.crit, "shadow assassin guarantees a backstab critical")
	near(result.final, 100 * 1.1 * 1.5 / 1.35, "dagger backstab bonus combines with forced critical and enemy armor")
	var source: Dictionary = player.combat.source_data(database.skills.rogue_shadow_strike, enemy)
	near(source.get("damage_bonus", 0), .3, "shadow strike adds its own twenty percent behind bonus to dagger ten percent")
	await prepare("rogue")
	enemy = place_enemy()
	player.combat.hit_target(enemy, {"formula": {"base": 0}, "can_crit": false}, Vector3.FORWARD)
	verify(player.combat.first_damage, "zero-damage utility does not spend first strike")
	result = player.combat.hit_target(enemy, hit, Vector3.FORWARD)
	verify(result.crit and not player.combat.first_damage, "first real damaging attack consumes guaranteed first strike")
	await prepare()
	player.loadout.set_level(3)
	player.loadout.select_career("swordsman")
	enemy = place_enemy()
	for i in range(3):
		player.combat.hit_target(enemy, {"formula": {"base": 1}, "can_crit": false}, Vector3.FORWARD)
	verify(player.combat.use_action(database.skills.swordsman_fan_slash), "Lv3 sword momentum skill starts after three hits")
	near(player.combat.runner.current_action.get("sequence_bonus", 0), .2, "third hit prepares twenty percent next weapon skill damage")
	near(player.combat.passives.counters.get("sword_momentum", 0), 0, "sword momentum is consumed at next skill")
	await prepare("mage")
	player.loadout.set_level(3)
	player.loadout.select_career("evoker")
	player.combat.use_action(database.skills.mage_fireball)
	await settle_action()
	player.combat.use_action(database.skills.mage_earth_spike)
	await settle_action()
	player.resources.restore_all()
	verify(player.combat.use_action(database.skills.evoker_ice_storm), "third different elemental spell starts")
	near(player.combat.runner.current_action.get("sequence_bonus", 0), .25, "elemental overload boosts third different element by twenty-five percent")
	verify(player.combat.passives.element_history.is_empty(), "elemental overload clears its history after trigger")
	await prepare("mage")
	player.loadout.set_level(2)
	player.loadout.select_career("conjurer")
	var victims: Array[Node] = []
	for pair in [["soldier", Vector3(0, 0, -2)], ["heavy_guard", Vector3(0, 0, -4)], ["fire_elemental", Vector3(0, 0, -6)], ["ogre", Vector3(0, 0, -8)]]:
		victims.append(place_enemy(pair[0], pair[1]))
	arena.locked_target = victims[0]
	var chain: Dictionary = database.skills.conjurer_chain_lightning.duplicate(true)
	chain["can_crit"] = false
	verify(player.combat.use_action(chain), "chain lightning starts on locked target")
	await ticks(18)
	for i in range(4):
		near(victims[i].combat.last_damage.get("raw", 0), 167 * pow(.8, i), "chain lightning jump %d applies cumulative 0.8 multiplier" % (i + 1))
	await prepare("rogue")
	enemy = place_enemy()
	arena.locked_target = enemy
	player.combat.use_action(database.skills.rogue_smoke)
	await ticks(15)
	verify(player.combat.statuses.has_status("stealth"), "smoke activates stealth status")
	await settle_action()
	await press("attack_primary")
	await ticks(65)
	verify(not player.attack_assist.approaching() and not player.combat.statuses.has_status("stealth"), "approach finishes and damaging attack breaks stealth")
	await prepare()
	enemy = place_enemy()
	player.combat.weapon_action("PRIMARY_CHARGE")
	player.combat.receive_damage({"formula": {"base": 5000}, "can_crit": false}, enemy, Vector3.BACK)
	verify(player.combat.state == "DEAD" and not player.combat.runner.busy(), "lethal damage cancels active action and enters DEAD")
	verify(not player.combat.switch_set() and not player.combat.start_dodge(), "dead actor cannot switch or dodge")
	await ticks(60)
	verify(player.combat.state == "DEAD", "old action cannot revive actor after death")
	player.combat.reset()
	verify(player.combat.state == "NORMAL" and player.collision_layer == 2, "debug reset restores alive state and player collision layer")

func check_active_windows_targeting_and_ai() -> void:
	await prepare()
	var enemy := place_enemy("soldier", Vector3(0, 0, -5))
	var hp: float = enemy.resources.current("HP")
	var sweep := {"id": "active_window_probe", "formula": {"base": 100}, "can_crit": false, "targeting": "CIRCLE", "radius": 2.5, "startup": .1, "active": .5, "recovery": .2, "presentation_type": "WEAPON_ACTION"}
	verify(player.combat.use_action(sweep), "long active-window probe starts through ActionRunner")
	await ticks(10)
	near(enemy.resources.current("HP"), hp, "active hitbox excludes enemy outside its shape")
	enemy.global_position = player.global_position + Vector3.FORWARD * 2
	await ticks(2)
	verify(enemy.resources.current("HP") < hp, "enemy entering after ACTIVE begins still receives the swing")
	var after: float = enemy.resources.current("HP")
	await ticks(8)
	near(enemy.resources.current("HP"), after, "extended ACTIVE window still hits each actor only once")
	player.combat.receive_damage({"formula": {"base": 1}, "can_crit": false, "poise_damage": 200}, enemy, Vector3.BACK)
	var other := place_enemy("heavy_guard", Vector3(0, 0, -2))
	hp = other.resources.current("HP")
	await ticks(5)
	near(other.resources.current("HP"), hp, "poise interruption disables remaining melee active hitbox")
	await prepare()
	enemy = place_enemy("soldier", Vector3(0, 0, -1.4))
	arena.aim_point = player.global_position + Vector3.BACK * 10
	arena.aim_override = arena.aim_point
	await ticks(3)
	hp = enemy.resources.current("HP")
	await press("attack_primary")
	await settle_action()
	near(enemy.resources.current("HP"), hp, "unlocked attack follows mouse direction away from enemy")
	arena.aim_point = enemy.global_position
	arena.aim_override = arena.aim_point
	await ticks(3)
	await press("attack_primary")
	await settle_action()
	verify(enemy.resources.current("HP") < hp, "mouse world aiming turns next attack toward enemy")
	await prepare()
	enemy = place_enemy("soldier", Vector3(-3, 0, -2))
	other = place_enemy("heavy_guard", Vector3(3, 0, -2))
	var motion := InputEventMouseMotion.new()
	motion.position = arena.world_to_screen(other.global_position)
	motion.global_position = motion.position
	Input.parse_input_event(motion)
	await ticks(2)
	await press("lock_target")
	verify(arena.locked_target == other, "Tab lock prefers visible enemy nearest mouse screen position")
	await press("lock_target")
	verify(arena.locked_target == null, "Tab toggles lock back off")
	await prepare()
	enemy = place_enemy("soldier", Vector3(0, 0, -3.5))
	tarena_aim(enemy.global_position)
	var start: Vector3 = player.global_position
	var target_start: Vector3 = enemy.global_position
	var thrust_energy: float = player.resources.current("Energy")
	var thrust_stamina: float = player.resources.current("Stamina")
	verify(player.combat.costs_for(database.skills.warrior_thrust).is_empty(), "warrior thrust's authored cost is empty")
	verify(player.combat.use_action(database.skills.warrior_thrust), "free warrior thrust still starts through the actual controller")
	near(player.resources.current("Energy"), thrust_energy, "warrior thrust spends no Energy")
	near(player.resources.current("Stamina"), thrust_stamina, "warrior thrust spends no Stamina")
	await ticks(15)
	near(player.global_position.distance_to(start), 2.55, "thrust advances once and stops short of the enemy", .05)
	verify(enemy.global_position.distance_to(target_start) < .7, "thrust applies ordinary hit knockback without teleporting the target")
	await prepare()
	player.loadout.equip_item("ring1", "qi_ring")
	player.resources.change("Energy", -50)
	player.combat.in_combat = true
	player.combat.combat_timeout = 1000
	enemy = place_enemy()
	var reflux_damage := {"formula": {"base": 1}, "can_crit": false}
	var energy_before_reflux: float = player.resources.current("Energy")
	player.combat.engage()
	player.combat.start_dodge()
	player.combat.receive_damage(reflux_damage, enemy, Vector3.BACK)
	near(player.resources.current("Energy") - energy_before_reflux, 20, "Energy reflux immediately restores twenty on the first perfect dodge")
	await ticks(28)
	var energy_before_reflux_cooldown: float = player.resources.current("Energy")
	player.combat.engage()
	player.combat.start_dodge()
	player.combat.receive_damage(reflux_damage, enemy, Vector3.BACK)
	near(player.resources.current("Energy"), energy_before_reflux_cooldown, "Energy reflux internal cooldown blocks an immediate second perfect dodge")
	await ticks(185)
	var energy_before_reflux_ready: float = player.resources.current("Energy")
	player.combat.engage()
	player.combat.start_dodge()
	player.combat.receive_damage(reflux_damage, enemy, Vector3.BACK)
	near(player.resources.current("Energy") - energy_before_reflux_ready, 20, "Energy reflux restores twenty again after its internal cooldown")
	await prepare()
	enemy = place_enemy("soldier", Vector3(0, 0, -1.5))
	enemy.ai_enabled = true
	enemy.ai_cooldown = 0
	hp = player.resources.current("HP")
	await ticks(4)
	verify(player.combat.in_combat and enemy.combat.runner.busy(), "real enemy aggro engages player and starts a telegraphed action")
	await ticks(90)
	verify(player.resources.current("HP") < hp, "enemy AI action actually damages player")
	await ticks(310)
	verify(player.combat.in_combat, "continuing enemy aggro prevents the five-second disengage timeout")
	enemy.ai_enabled = false
	enemy.global_position = Vector3(18, .1, 18)
	await ticks(310)
	verify(not player.combat.in_combat, "removing damage and enemy aggro allows disengagement")
	await prepare()
	database.passives["test_heavy_permission"] = {"id": "test_heavy_permission", "conditions": [], "effects": [{"type": "proficiency", "value": ["GreatAxe", "HEAVY_2H"]}]}
	player.loadout.passive_ids.append("test_heavy_permission")
	player.stats.add_modifier("test_strength", {"STR": 1})
	verify(player.loadout.equip_weapon(0, "bone_greataxe"), "special proficiency passive can bypass career restriction through unified requirements")
	database.passives.erase("test_heavy_permission")

func tarena_aim(point: Vector3) -> void:
	arena.aim_point = point
	arena.aim_override = point

func check_snapshots_and_runtime_modifiers() -> void:
	await prepare("mage")
	player.loadout.equip_weapon(0, "storm_orb")
	player.loadout.equip_weapon(1, "apprentice_staff")
	player.stats.add_modifier("snapshot_casting_buff", {"INT": 4})
	var enemy := place_enemy("soldier", Vector3(0, 0, -10))
	var original_resistance: Dictionary = enemy.resistances.duplicate(true)
	enemy.resistances["LIGHTNING"] = .5
	tarena_aim(enemy.global_position)
	await ticks(2)
	# A deliberately slow version of the existing spell exercises the same API and
	# hit instance as ordinary projectiles while making the flight/switch observable.
	var bolt: Dictionary = database.skills.mage_lightning.duplicate(true)
	bolt["targeting"] = "DIRECTION"
	bolt["projectile_speed"] = 6.0
	bolt["can_crit"] = false
	verify(player.combat.use_action(bolt), "orb lightning projectile starts with temporary INT buff")
	await settle_action()
	near(enemy.resources.current("HP"), enemy.resources.max_value("HP"), "slow projectile remains in flight after caster recovery")
	player.stats.remove_modifier("snapshot_casting_buff")
	verify(player.combat.switch_set(), "caster switches to staff while original orb projectile flies")
	await ticks(115)
	near(player.stats.get_final_stat("INT"), 14, "casting buff is gone before projectile impact")
	verify(player.loadout.weapon().id == "apprentice_staff", "different weapon is active at projectile impact")
	near(enemy.combat.last_damage.get("raw", 0), 275.6, "delayed hit keeps original INT 18 and orb weapon scaling 22")
	near(enemy.combat.last_damage.get("effective_defense", 0), .4, "delayed hit keeps original orb's ten-percent lightning penetration")
	near(enemy.combat.last_damage.get("final", 0), 165.36, "delayed projectile final damage resolves using original caster snapshot")
	enemy.resistances = original_resistance
	await prepare("rogue")
	player.loadout.equip_weapon(0, "shortbow")
	player.combat.statuses.add_status("deterministic_crit", {"duration": -1, "effects": [{"type": "modifier", "stat": "crit_chance", "value": -.05}]}, player)
	enemy = place_enemy("soldier", Vector3(0, 0, -10))
	tarena_aim(enemy.global_position)
	await ticks(2)
	var arrows: Array[float] = []
	enemy.health.damage_received.connect(func(amount: float): arrows.append(amount))
	var arrow: Dictionary = database.get_action("BOW", "PRIMARY_TAP")
	arrow["projectile_speed"] = 3
	arrow["poise_damage"] = 0
	player.combat.use_action(arrow)
	await settle_action()
	player.combat.use_action(arrow)
	await settle_action()
	await ticks(240)
	verify(arrows.size() == 2, "two independent first-strike candidate projectiles both reach target")
	if arrows.size() == 2:
		near(arrows[0], 83 * 1.5 / 1.35, "first arriving damage instance gains first-strike forced critical")
		near(arrows[1], 83 / 1.35, "second already-flying attack does not inherit first-strike critical")
	await prepare()
	await press("attack_primary", 10)
	verify(semantics.count("PRIMARY_TAP") == 1, "ten-frame hold is a tap at default quarter-second threshold")
	await prepare()
	database.passives["test_timing"] = {"id": "test_timing", "event": "stat_update", "conditions": [], "effects": [{"type": "modifier", "stat": "action_speed_multiplier", "value": .5}, {"type": "modifier", "stat": "charge_time_multiplier", "value": -.25}]}
	player.loadout.passive_ids.append("test_timing")
	player.combat.statuses.add_status("timing_buff", {"duration": 10, "effects": [{"type": "modifier", "stat": "action_speed_multiplier", "value": .5}, {"type": "modifier", "stat": "charge_time_multiplier", "value": -.25}]}, player)
	await ticks(2)
	near(player.input_router.hold_threshold, .125, "passive and buff jointly halve charge hold threshold")
	await press("attack_primary", 10)
	verify(semantics.count("PRIMARY_CHARGE") == 1 and semantics.count("PRIMARY_TAP") == 0, "same ten-frame press becomes only a charge under timing modifiers")
	var running: Dictionary = player.combat.runner.current_action
	near(running.get("startup", 0), float(database.combat_feel.SINGLE_BLADE.charge_release_startup) / 2.0, "action-speed bonuses halve the new short charged-release startup")
	near(running.get("active", 0), .05, "combined action-speed bonuses halve active duration")
	near(running.get("recovery", 0), .18, "combined action-speed bonuses halve recovery")
	await ticks(24)
	verify(player.combat.can_start(), "faster action really completes within half the original timeline")
	player.combat.statuses.remove_status("timing_buff")
	player.loadout.passive_ids.erase("test_timing")
	database.passives.erase("test_timing")
	await ticks(2)
	near(player.input_router.hold_threshold, .25, "removing passive and buff restores default hold time")
	await prepare()
	player.resources.configure("Stamina", 0)
	player.combat.engage()
	verify(player.combat.start_dodge() and player.combat.dodge_paid == 0, "zero-capacity stamina policy permits free combat dodge")
	await ticks(28)
	player.resources.pools.erase("Stamina")
	player.combat.engage()
	verify(player.combat.start_dodge() and player.combat.dodge_paid == 0, "actor without stamina module can still dodge")
	await ticks(28)
	player.resources.configure("Stamina", 3)
	player.resources.change("Stamina", -3)
	player.resources.unlimited["Stamina"] = true
	player.combat.engage()
	verify(player.combat.start_dodge(), "unlimited-stamina policy permits dodge at zero stored points")
	near(player.resources.current("Stamina"), 0, "unlimited stamina does not spend or manufacture points")
	await ticks(28)
	verify(player.combat.weapon_action("PRIMARY_CHARGE"), "unlimited-stamina policy also pays weapon action costs")
	near(player.resources.current("Stamina"), 0, "unlimited resource applies consistently to weapon costs")
	await settle_action()
	player.resources.unlimited.clear()
	player.resources.change("Stamina", -player.resources.current("Stamina"))
	player.combat.engage()
	verify(not player.combat.start_dodge(), "ordinary finite stamina still rejects an empty dodge")
	await prepare()
	near(player.stats.get_stat("CON"), 13, "StatsComponent retains original base attribute")
	player.loadout.equip_item("belt", "vigor_belt")
	player.stats.add_modifier("passive_test_constitution", {"CON": 2})
	player.combat.statuses.add_status("constitution_buff", {"duration": 5, "stats": {"CON": 3}}, player)
	player.combat.statuses.add_status("constitution_debuff", {"duration": 5, "stats": {"CON": -1}}, player)
	near(player.stats.get_final_stat("CON"), 18, "equipment passive buff and debuff modifier sources compose")
	near(player.resources.max_value("HP"), 1220, "combined attribute sources update derived career HP immediately")
	near(player.stats.get_stat("CON"), 13, "modifiers never overwrite base CON")
	player.combat.statuses.remove_status("constitution_buff")
	near(player.resources.max_value("HP"), 1130, "removing buff recomputes derived HP without losing other sources")
	player.combat.statuses.remove_status("constitution_debuff")
	player.stats.remove_modifier("passive_test_constitution")
	player.loadout.equip_item("belt", "")
	near(player.stats.get_final_stat("CON"), 13, "removing every source restores exact base attribute")
	near(player.resources.max_value("HP"), 1070, "derived resources return to original career values")
	await prepare("rogue")
	player.stats.add_modifier("borrowed_dexterity", {"DEX": 2})
	database.weapons["test_dex_blade"] = database.weapons.hunter_dagger.duplicate(true)
	database.weapons.test_dex_blade["id"] = "test_dex_blade"
	database.weapons.test_dex_blade["conditions"] = [{"type": "proficiency", "value": "SHORT_WEAPON"}, {"type": "stat", "stat": "DEX", "op": ">=", "value": 16}]
	verify(player.loadout.equip_weapon(0, "test_dex_blade"), "temporary attribute buff can meet a weapon requirement")
	player.stats.remove_modifier("borrowed_dexterity")
	verify(not player.combat.weapon_action("PRIMARY_TAP"), "weapon use rechecks requirement after enabling buff disappears")
	verify(not player.combat.last_condition_failed.is_empty(), "invalid equipped weapon reports its unmet requirement")
	database.weapons.erase("test_dex_blade")
	await prepare()
	verify(not player.combat.use_action(database.skills.mage_fireball), "direct action API rejects skills outside earned career pool")
	verify(not player.combat.cooldowns.has("mage_fireball"), "rejected foreign career skill starts no cooldown")
	var zero_cd: Dictionary = database.skills.warrior_whirlwind.duplicate(true)
	zero_cd["cooldown"] = 0
	zero_cd["costs"] = {}
	verify(player.combat.use_action(zero_cd), "zero-cooldown QER skill starts through the ordinary API")
	await settle_action()
	verify(player.combat.use_action(zero_cd), "zero-cooldown skill can be reused immediately after recovery")
	await settle_action()

func check_configured_resource_policies() -> void:
	var original_warrior: Dictionary = database.careers.warrior.duplicate(true)
	database.careers.warrior["resource_rules"] = {"Stamina": {"unlimited": true}}
	await prepare()
	player.resources.change("Stamina", -player.resources.current("Stamina"))
	verify(player.resources.unlimited.get("Stamina", false), "career data configures unlimited stamina without controller edits")
	verify(player.combat.weapon_action("PRIMARY_CHARGE"), "configured unlimited profession pays a charged weapon action at zero points")
	await settle_action()
	player.combat.engage()
	verify(player.combat.start_dodge() and player.combat.dodge_paid == 0, "configured unlimited profession also grants combat dodge")
	var enemy := place_enemy()
	player.combat.receive_damage({"formula": {"base": 1}, "can_crit": false}, enemy, Vector3.BACK)
	near(player.resources.current("Stamina"), 0, "perfect dodge refunds nothing when unlimited policy paid nothing")
	database.careers.warrior = original_warrior.duplicate(true)
	database.careers.warrior["resource_rules"] = {"Stamina": {"cost_overrides": {"DODGE": 0}}}
	await prepare()
	player.combat.engage()
	verify(player.combat.start_dodge(), "career can waive only the DODGE action category cost")
	near(player.resources.current("Stamina"), 3, "DODGE-only override leaves stamina intact")
	await ticks(28)
	verify(player.combat.weapon_action("PRIMARY_CHARGE"), "DODGE-only profession still permits normal weapon actions")
	near(player.resources.current("Stamina"), 2, "DODGE exemption does not waive charged weapon stamina cost")
	database.careers.warrior = original_warrior.duplicate(true)
	database.careers.warrior["resource_rules"] = {"Stamina": {"cost_overrides": {"DODGE": 2}}}
	await prepare()
	player.combat.engage()
	verify(player.combat.start_dodge(), "configured two-point dodge is payable")
	near(player.resources.current("Stamina"), 1, "custom dodge cost is deducted at start")
	enemy = place_enemy()
	player.combat.receive_damage({"formula": {"base": 1}, "can_crit": false}, enemy, Vector3.BACK)
	near(player.resources.current("Stamina"), 3, "perfect dodge refunds the exact two points paid by the resource rule")
	database.careers.warrior = original_warrior.duplicate(true)
	await prepare()
	database.passives["test_conditional_dodge"] = {"id": "test_conditional_dodge", "event": "stat_update", "conditions": [{"type": "self_hp", "value": .3, "op": "<"}, {"type": "presentation_type", "value": "DODGE"}], "effects": [{"type": "modifier", "stat": "stamina_cost_override", "value": 0}]}
	player.loadout.passive_ids.append("test_conditional_dodge")
	player.resources.change("Stamina", -3)
	player.combat.engage()
	verify(not player.combat.start_dodge(), "conditional cost passive does not activate while HP condition is false")
	player.resources.change("HP", -player.resources.current("HP") * .75)
	verify(player.combat.start_dodge(), "conditional low-HP passive makes DODGE free at zero points")
	await ticks(28)
	verify(not player.combat.weapon_action("PRIMARY_CHARGE"), "conditional DODGE passive leaves weapon action costs unchanged")
	player.loadout.passive_ids.erase("test_conditional_dodge")
	database.passives.erase("test_conditional_dodge")
	await prepare()
	player.resources.change("Stamina", -3)
	player.combat.statuses.add_status("test_free_stamina", {"duration": 2, "effects": [{"type": "modifier", "stat": "stamina_cost_override", "value": 0}]}, player)
	verify(player.combat.weapon_action("PRIMARY_CHARGE"), "temporary stamina exemption buff pays a charged weapon action")
	await settle_action()
	player.combat.engage()
	verify(player.combat.start_dodge(), "same temporary exemption buff pays combat dodge")
	near(player.resources.current("Stamina"), 0, "buff exemption changes cost without creating stamina")
	await ticks(145)
	verify(not player.combat.statuses.has_status("test_free_stamina"), "temporary stamina exemption expires normally")
	player.resources.change("Stamina", -player.resources.current("Stamina"))
	player.combat.engage()
	verify(not player.combat.start_dodge(), "expired exemption restores finite dodge cost")
	database.careers.warrior = original_warrior
