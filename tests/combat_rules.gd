extends SceneTree
## Run: Godot --headless --path . --script tests/combat_rules.gd
## Deterministic boundary and reference-value checks, independent of the arena.

const Conditions = preload("res://combat/condition_system.gd")
const Damage = preload("res://combat/damage_pipeline.gd")
const Targeting = preload("res://combat/targeting.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	check_conditions()
	check_damage()
	check_targeting()
	print("COMBAT_RULES: %d checks; %d failures" % [checks, failures.size()])
	for label in failures:
		printerr("FAIL: ", label)
	quit(0 if failures.is_empty() else 1)

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func near(actual: float, expected: float, label: String) -> void:
	verify(absf(actual - expected) <= 0.0001, "%s (%.6f / %.6f)" % [label, actual, expected])

func check_conditions() -> void:
	var context := {
		"stats": {"STR": 13, "DEX": 11, "CON": 13, "INT": 8, "PER": 10, "CHA": 9},
		"weapon_family": "SINGLE_BLADE", "weapon_type": "Sword", "hp_ratio": 0.25,
		"target_hp_ratio": 0.29, "behind": true, "in_combat": true, "state": "NORMAL",
		"statuses": ["Stealth"], "target_statuses": ["Burn"], "careers": ["warrior", "swordsman"],
		"resources": {"Qi": 2, "Stamina": 3}, "proficiencies": ["SINGLE_BLADE", "SHORT_WEAPON"],
		"first_hit": true, "event": "perfect_dodge", "distance": 8.1, "damage_type": "FIRE",
		"presentation_type": "CASTER_ACTION", "level": 2, "crit": true, "area": true
	}
	var all := [
		{"type": "weapon_family", "value": ["SINGLE_BLADE", "POLEARM"], "op": "in"},
		{"type": "weapon_type", "value": "Sword"},
		{"type": "stat", "stat": "STR", "value": 13},
		{"type": "attribute", "stat": "DEX", "value": 11, "op": ">="},
		{"type": "self_hp", "value": 0.3, "op": "<"},
		{"type": "target_hp", "value": 0.3, "op": "<"},
		{"type": "behind_target", "value": true},
		{"type": "combat_state", "value": "NORMAL"},
		{"type": "combat_state", "value": true},
		{"type": "combat_state", "value": "IN_COMBAT"},
		{"type": "self_status", "value": "Stealth"},
		{"type": "target_status", "status": "Burn", "value": true},
		{"type": "career", "value": ["rogue", "warrior"], "op": "in"},
		{"type": "career", "value": "swordsman"},
		{"type": "resource", "resource": "Qi", "value": 2},
		{"type": "proficiency", "value": "SHORT_WEAPON"},
		{"type": "first_hit", "value": true},
		{"type": "first_damage", "value": true},
		{"type": "distance", "op": ">", "value": 8},
		{"type": "elemental", "value": true},
		{"type": "level", "value": 2},
		{"type": "event", "value": "perfect_dodge"},
		{"type": "damage_type", "value": "FIRE"},
		{"type": "presentation_type", "value": "CASTER_ACTION"},
		{"type": "spell", "value": true},
		{"type": "critical", "value": true},
		{"type": "area", "value": true}
	]
	for entry in all:
		verify(Conditions.check(entry, context), "condition %s" % str(entry))
	verify(Conditions.check_all(all, context).is_empty(), "all valid conditions succeed together")
	verify(Conditions.check_all([], context).is_empty(), "empty requirements are unrestricted")
	var failures_to_check := [
		{"type": "stat", "stat": "STR", "value": 14},
		{"type": "attribute", "stat": "Missing", "value": 0},
		{"type": "resource", "resource": "SpellSlot", "value": 0},
		{"type": "resource", "resource": "Qi", "value": 3},
		{"type": "proficiency", "value": "HEAVY_2H"},
		{"type": "career", "value": ["rogue", "mage"], "op": "in"},
		{"type": "weapon_family", "value": "CASTER"},
		{"type": "self_status", "value": "Burn"},
		{"type": "target_status", "status": "Burn", "value": false},
		{"type": "first_hit", "value": false},
		{"type": "behind", "value": false},
		{"type": "combat_state", "value": "OUT_OF_COMBAT"},
		{"type": "level", "value": 3},
		{"type": "damage_type", "value": "LIGHTNING"},
		{"type": "self_hp", "value": 0.1, "op": "<"},
		{"type": "target_hp", "value": 0.3, "op": ">="},
		{"type": "stat", "stat": "STR", "value": 5, "op": "typo"},
		{"type": "nonexistent", "value": true}
	]
	for entry in failures_to_check:
		verify(not Conditions.check(entry, context), "fails closed %s" % str(entry))
		verify(not Conditions.check_all([entry], context).is_empty(), "failure includes readable reason %s" % entry.type)
	verify(not Conditions.check({"type": "target_hp", "op": "<", "value": 0.3}, {}), "missing target cannot satisfy execution HP condition")
	verify(not Conditions.check({"type": "target_hp", "op": ">", "value": 0.3}, {"has_target": false, "target_hp_ratio": 1.0}), "missing target marker rejects artificial default high HP ratio")
	verify(not Conditions.check({"type": "target_hp", "op": "<", "value": 0.3}, {"target_hp_ratio": 0.3}), "execution excludes exactly 30 percent HP")
	verify(not Conditions.check({"type": "distance", "op": ">", "value": 8}, {"distance": 8}), "eagle eye excludes exactly 8 meters")
	verify(Conditions.check({"type": "self_status", "value": "Burn", "op": "!="}, context), "absence condition succeeds for missing status")
	verify(not Conditions.check_all([42], context).is_empty(), "malformed condition reports a failure")
	verify(Conditions.check_all(failures_to_check, context) == Conditions.failure_reason(failures_to_check[0]), "UI reports first unmet condition")
	verify(not Conditions.check({"type": "elemental", "value": true}, {"damage_type": "PHYSICAL"}), "physical attack is not elemental")

func check_damage() -> void:
	var action := {"formula": {"base": 10, "weapon": 0.5, "STR": 1, "DEX": 2, "CON": 3, "INT": 4, "PER": 5, "CHA": 6}, "damage_type": "PHYSICAL"}
	var source := {"stats": {"STR": 2, "DEX": 3, "CON": 4, "INT": 5, "PER": 6, "CHA": 7}, "weapon_scaling": 30}
	near(Damage.calculate(action, source, {}, 0.9).raw, 137, "formula reads weapon scaling and all six attributes")
	near(Damage.calculate(action, source, {}, 0.9).final, 137, "no implicit attribute to damage conversion")
	var base := {"formula": {"base": 100}}
	near(Damage.calculate(base, {}, {}, 0.0).final, 150, "default critical multiplier is 1.5")
	verify(Damage.calculate(base, {}, {}, 0.049).crit, "default critical chance is five percent")
	verify(not Damage.calculate(base, {}, {}, 0.05).crit, "critical threshold is exclusive")
	near(Damage.calculate(base, {"forced_crit": true}, {}, 0.99).final, 150, "passive forced critical overrides random roll")
	near(Damage.calculate({"formula": {"base": 100}, "forced_crit": true}, {}, {}, 0.99).final, 150, "action forced critical works")
	near(Damage.calculate({"formula": {"base": 100}, "can_crit": false, "forced_crit": true}, {"forced_crit": true}, {}, 0.0).final, 100, "can_crit false excludes all critical modifiers")
	near(Damage.calculate({"formula": {"base": 100}, "is_dot": true}, {}, {}, 0.0).final, 100, "DOT cannot crit by default")
	near(Damage.calculate({"formula": {"base": 100}, "crit_chance_bonus": 0.15, "crit_multiplier_bonus": 0.35}, {}, {}, 0.19).final, 185, "per-action critical bonuses add to source values")
	verify(Damage.calculate(base, {"crit_chance": 2}, {}, 1).crit, "critical chance is clamped at certainty")
	verify(not Damage.calculate(base, {"crit_chance": -1}, {}, 0).crit, "negative critical chance cannot crit")
	near(Damage.calculate(base, {}, {"armor": 100}, 0.9).final, 50, "100 armor halves physical damage")
	near(Damage.calculate(base, {"armor_penetration": 50}, {"armor": 100}, 0.9).final, 100.0 / 1.5, "armor penetration subtracts before mitigation")
	near(Damage.calculate(base, {"armor_penetration": 200}, {"armor": 100}, 0.9).final, 100, "excess armor penetration cannot amplify damage")
	near(Damage.calculate(base, {}, {"armor": -50}, 0.9).final, 100, "negative armor clamps to zero")
	for element in ["FIRE", "ICE", "LIGHTNING", "EARTH", "WIND"]:
		var resistance := {element: 0.6}
		var hit := {"formula": {"base": 100}, "damage_type": element}
		near(Damage.calculate(hit, {}, {"armor": 10000, "resistance": resistance}, 0.9).final, 40, element + " uses resistance instead of armor")
		near(Damage.calculate(hit, {"resistance_penetration": 0.1}, {"resistance": resistance}, 0.9).final, 50, element + " scalar penetration")
	var fire := {"formula": {"base": 100}, "damage_type": "FIRE"}
	near(Damage.calculate(fire, {}, {"resistance": {"FIRE": 2}}, 0.9).final, 25, "element resistance cap is 75 percent")
	near(Damage.calculate(fire, {}, {"resistance": {"FIRE": -2}}, 0.9).final, 150, "element weakness cap is minus 50 percent")
	near(Damage.calculate(fire, {"resistance_penetration": {"ALL": 0.1, "FIRE": 0.2, "ICE": 0.5}}, {"resistance": {"FIRE": 0.6}}, 0.9).final, 70, "typed penetration combines ALL and matching element")
	near(Damage.calculate(base, {}, {"vulnerability": {"ALL": 0.1, "PHYSICAL": 0.2, "FIRE": 0.8}}, 0.9).final, 130, "only applicable vulnerabilities contribute")
	near(Damage.calculate(base, {"damage_bonus": 0.2, "forced_crit": true, "armor_penetration": 20}, {"armor": 120, "vulnerability": {"PHYSICAL": 0.1}, "damage_taken_bonus": 0.1}, 0.9).final, 108.9, "full physical pipeline combines separate modifier stages")
	var blocked: Dictionary = Damage.calculate(base, {"forced_crit": true}, {"invulnerable": true, "vulnerability": {"ALL": 5}}, 0)
	verify(blocked.blocked and blocked.final == 0.0 and not blocked.crit, "invulnerability blocks even forced critical damage")
	near(blocked.raw, 100, "blocked result retains formula for debugging")
	near(Damage.calculate({"formula": {"base": -20}}, {}, {}, 0.9).final, 0, "damage cannot heal via negative formula")
	near(Damage.calculate(base, {"damage_bonus": -2}, {}, 0.9).final, 0, "damage reduction cannot produce healing")
	verify(not Damage.calculate({}, {"forced_crit": true}, {}, 0).crit, "zero-damage utility actions do not generate critical events")
	verify(action.formula.size() == 8 and source.stats.STR == 2, "pipeline leaves input snapshots unchanged")

func check_targeting() -> void:
	var origin := Vector3.ZERO
	var forward := Vector3.FORWARD
	verify(Targeting.contains("CIRCLE", origin, forward, Vector3(3, 0, 4), {"radius": 5}, origin), "circle includes its boundary")
	verify(not Targeting.contains("CIRCLE", origin, forward, Vector3(3.01, 0, 4), {"radius": 5}, origin), "circle excludes beyond radius")
	verify(Targeting.contains("SELF", origin, Vector3.ZERO, Vector3(0, .8, 0), {"radius": 1}, origin), "self area tolerates a shallow slope independently of facing")
	verify(not Targeting.contains("SELF", origin, Vector3.ZERO, Vector3(0, 20, 0), {"radius": 1}, origin), "self area cannot hit a different floor")
	for shape in ["CONE", "LINE", "DIRECTION", "CIRCLE"]:
		verify(Targeting.contains(shape, origin, forward, Vector3(0, 1.25, -1), {"range": 3, "radius": 3}, origin), shape + " includes reachable height boundary")
		verify(not Targeting.contains(shape, origin, forward, Vector3(0, 1.26, -1), {"range": 3, "radius": 3}, origin), shape + " rejects targets above contact height")
		verify(not Targeting.contains(shape, Vector3.UP * 4, forward, Vector3(0, 0, -1), {"range": 3, "radius": 3}, origin), shape + " rejects targets on ground below a roof")
	var raised_aim := Vector3(10, 4, 8)
	for shape in ["POINT", "POINT/CIRCLE", "POINT/LINE", "TARGET"]:
		verify(Targeting.contains(shape, origin, forward, raised_aim, {"range": 3, "radius": 3}, raised_aim), shape + " uses the elevated impact surface")
		verify(not Targeting.contains(shape, origin, forward, raised_aim - Vector3.UP * 4, {"range": 3, "radius": 3}, raised_aim), shape + " cannot splash through the impact floor")
	verify(Targeting.contains("CONE", origin, forward, Vector3(0, 2, -1), {"vertical_reach": 2.5}, origin), "explicit action envelope can support a tall attack")
	var aim := Vector3(10, 0, 8)
	verify(Targeting.contains("POINT", origin, forward, aim + Vector3.RIGHT, {"radius": 1}, aim), "point area is centered at mouse world point")
	verify(not Targeting.contains("POINT", origin, forward, origin, {"radius": 1}, aim), "point area does not hit at caster origin")
	verify(Targeting.contains("TARGET", origin, forward, aim, {}, aim), "target targeting includes locked actor position")
	verify(not Targeting.contains("TARGET", origin, forward, aim + Vector3.RIGHT, {}, aim), "target targeting excludes unrelated actor")
	var cone := {"range": 5, "angle": 120}
	verify(Targeting.contains("CONE", origin, forward, Vector3(4.330127, 0, -2.5), cone, origin), "cone includes 60 degree boundary")
	verify(not Targeting.contains("CONE", origin, forward, Vector3(4.4, 0, -2.4), cone, origin), "cone excludes outside half angle")
	verify(not Targeting.contains("CONE", origin, forward, Vector3(0, 0, 1), cone, origin), "cone excludes target behind caster")
	verify(not Targeting.contains("CONE", origin, forward, Vector3(0, 0, -5.01), cone, origin), "cone excludes target beyond reach")
	verify(Targeting.contains("CONE", origin, forward * 10, Vector3(0, 0, -4), cone, origin), "cone normalizes facing vector")
	verify(not Targeting.contains("CONE", origin, Vector3.ZERO, Vector3(0, 0, -1), cone, origin), "zero direction cannot aim a cone")
	var line := {"range": 8, "width": 2}
	for shape in ["DIRECTION", "LINE"]:
		verify(Targeting.contains(shape, origin, forward, Vector3(1, 0, -8), line, origin), shape + " includes rectangular far corner")
		verify(not Targeting.contains(shape, origin, forward, Vector3(1.01, 0, -2), line, origin), shape + " excludes beyond width")
		verify(not Targeting.contains(shape, origin, forward, Vector3(0, 0, 0.01), line, origin), shape + " excludes targets behind start")
		verify(not Targeting.contains(shape, origin, forward, Vector3(0, 0, -8.01), line, origin), shape + " excludes beyond reach")
	verify(Targeting.contains("POINT/LINE", origin, forward, aim + Vector3(0, 0, 4), line, aim), "ground line extends half length either side of aim point")
	verify(not Targeting.contains("POINT/LINE", origin, forward, origin, line, aim), "ground line does not start from caster")
	verify(not Targeting.contains("unknown", origin, forward, origin, {}, origin), "unknown targeting shape fails closed")
	verify(Targeting.is_behind(Vector3.BACK, origin, forward), "backstab succeeds directly behind target")
	verify(not Targeting.is_behind(Vector3.FORWARD, origin, forward), "backstab fails directly in front")
	verify(not Targeting.is_behind(Vector3.RIGHT, origin, forward), "backstab fails at target side")
	verify(Targeting.is_behind(Vector3(0.8660254, 0, 0.5), origin, forward), "backstab includes rear sector 60 degree edge")
	verify(not Targeting.is_behind(Vector3(0.88, 0, 0.48), origin, forward), "backstab excludes outside rear 120 degree sector")
	verify(not Targeting.is_behind(origin, origin, forward), "overlapping actors have no backstab direction")
	verify(not Targeting.is_behind(Vector3.BACK, origin, Vector3.ZERO), "unknown target facing cannot award backstab")
