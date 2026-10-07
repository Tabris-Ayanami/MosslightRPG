extends SceneTree

func _init() -> void:
	var db = load("res://combat/combat_database.gd").new()
	assert(db.errors.is_empty(), str(db.errors))
	assert(db.careers.size() == 14)
	assert(db.weapons.size() == 11)
	assert(db.equipment.size() == 12)
	assert(db.enemies.size() == 4)
	assert(db.skills.size() == 32)
	assert(db.actions.size() == 36)
	assert(db.shields.size() == 2)
	assert(db.reactions.size() == 3)
	var dream: Dictionary = db.skills.conjurer_dreamwalk
	assert(dream.name == "梦行" and dream.is_skill and dream.min_level == 2)
	assert(dream.presentation_type == "CASTER_ACTION" and dream.animation_family == "CASTER" and dream.targeting == "TARGET" and dream.range == 12)
	assert(dream.costs.size() == 1 and dream.costs.Energy == 20 and dream.cooldown == 20 and not dream.can_crit)
	assert(dream.formula.size() == 2 and dream.formula.base == 0 and dream.formula.weapon == 0 and dream.poise_damage == 0)
	assert(dream.conditions == [{"type": "target_level_at_most_self"}])
	assert(dream.effects.size() == 1 and dream.effects[0].size() == 4)
	assert(dream.effects[0].type == "possess" and dream.effects[0].target == "self" and dream.effects[0].duration == 15 and dream.effects[0].max_level_delta == 0)
	assert(dream.target_relation == "any", "Dreamwalk can select any relationship but excludes the caster")
	assert("conjurer_dreamwalk" in db.careers.conjurer.skills and db.careers.conjurer.default_sets.is_empty())
	for career in db.careers.values():
		for prepared in career.default_sets:
			assert("conjurer_dreamwalk" not in prepared.skills, "Dreamwalk is manually learned and prepared")
	var unit_levels := {"soldier": 1, "heavy_guard": 2, "fire_elemental": 3, "ogre": 10}
	for unit in unit_levels: assert(db.enemies[unit].level == unit_levels[unit])
	var consumables: Array = db.items.values().filter(func(item): return item.get("category", "") == "consumable")
	assert(consumables.size() == 5 and db.items.magic_candy.effect == "level")
	assert(db.progression.rules.max_level == 10 and not db.progression.starter.items.has("magic_candy"))
	assert("magic_candy" not in db.progression.starter.quickslots, "Debug candy must not occupy a formal starter quick slot")
	for level in range(1, 10):
		assert(int(db.progression.rules.xp_to_next.get(str(level), 0)) > 0)
	var obtainable: Dictionary = {}
	for enemy in db.enemies:
		assert(db.progression.has(enemy) and db.progression[enemy].experience > 0)
		assert(not db.progression[enemy].drops.has("magic_candy"), "Debug candy must not enter ordinary enemy drops")
		for item in db.progression[enemy].equipment_rotation:
			assert(db.weapons.has(item) or db.equipment.has(item))
			obtainable[item] = true
		for item in db.progression[enemy].drops:
			assert(db.items.has(item) and db.progression[enemy].drops[item] > 0)
	for item in db.weapons.keys() + db.equipment.keys():
		assert(obtainable.has(item), "Every existing equipment entry has a deterministic reward source")
	assert(db.progression.starter.quickslots.size() == 4)
	for item in db.progression.starter.items:
		assert(db.items.has(item) or db.equipment.has(item))
	for item in consumables:
		assert(item.cooldown >= 0)
		assert(item.effect in ["resource", "action", "level"])
	assert("shields" not in db.CATALOGS, "Shields must derive from the weapon catalog")
	assert(db.careers.warrior.next_careers.has("soldier"))
	assert(db.careers.soldier.parent_career == "warrior" and db.careers.soldier.required_level == 2)
	assert(db.careers.soldier.loadout_rule == "sword_shield_pair")
	assert(db.careers.swordsman.next_careers.has("dual_swordsman"))
	assert(db.careers.dual_swordsman.parent_career == "swordsman" and db.careers.dual_swordsman.required_level == 10)
	assert(db.careers.dual_swordsman.base_career == "warrior" and db.careers.dual_swordsman.loadout_rule == "dual_sword_pair")
	assert(db.careers.dual_swordsman.skills.is_empty(), "Dual swords inherit existing skills rather than inventing new active skills")
	var dual_profile: Dictionary = db.combat_feel.DUAL_SWORD
	assert(dual_profile.startup_multiplier == .60 and dual_profile.strike_active_multiplier == .50)
	assert(dual_profile.strike_gap == .10 and dual_profile.minimum_recovery == .08 and dual_profile.cycle_multiplier == 1.0)
	assert(dual_profile.strike_order.size() == 2 and int(dual_profile.strike_order[0]) == 1 and int(dual_profile.strike_order[1]) == 0, "Every dual sequence starts with left B sword then right A sword")
	assert(db.careers.dual_swordsman.passives.has("dual_sword_mastery"))
	var mastery: Dictionary = db.passives.dual_sword_mastery
	assert(mastery.event == "action_transform" and mastery.action_rule == "dual_sword_skill_repeat" and mastery.min_level == 10)
	assert(mastery.effects.is_empty(), "Dual mastery describes an action rule, not a pretend statistical modifier")
	var dual_templates := {"warrior_whirlwind": "spin", "warrior_thrust": "thrust", "warrior_impact": "slash", "warrior_sword_wave": "slash", "swordsman_fan_slash": "slash"}
	var tagged_skills := 0
	for skill in db.skills.values():
		if not skill.has("dual_sequence"):
			continue
		tagged_skills += 1
		assert(dual_templates.has(skill.id) and skill.dual_sequence.template == dual_templates[skill.id])
		assert(skill.is_skill and skill.presentation_type == "WEAPON_ACTION" and skill.has("formula"))
		assert(skill.dual_sequence.origin == ("after_movement" if skill.id == "warrior_thrust" else "action_origin"))
		assert(dual_profile.skill_templates.has(skill.dual_sequence.template))
	assert(tagged_skills == 5, "Exactly five inherited sword skills declare repeat templates")
	for template in dual_profile.skill_templates.values():
		assert(template.strike_active > 0 and template.strike_gap > template.strike_active)
	assert(dual_profile.skill_templates.spin.strike_active == .20 and dual_profile.skill_templates.spin.strike_gap == .24)
	assert(dual_profile.skill_templates.thrust.strike_active == .10 and dual_profile.skill_templates.thrust.strike_gap == .14)
	assert(dual_profile.skill_templates.slash.strike_active == .10 and dual_profile.skill_templates.slash.strike_gap == .14)
	var thrust_movements := 0
	for effect in db.skills.warrior_thrust.effects:
		if effect.type == "dash":
			thrust_movements += 1
			assert(effect.target == "self" and effect.distance == 3)
	assert(thrust_movements == 1, "Thrust data keeps one self movement before the mirrored attacks")
	assert(db.careers.warrior.default_sets[0].weapon == "iron_longsword" and db.careers.warrior.default_sets[1].weapon == "hunter_dagger")
	var greatsword: Dictionary = db.weapons.iron_greatsword
	assert(greatsword.weapon_type == "Greatsword" and greatsword.animation_family == "HEAVY_2H")
	assert(greatsword.weapon_scaling == db.weapons.bone_greataxe.weapon_scaling and greatsword.requirements == db.weapons.bone_greataxe.requirements)
	var greatsword_charge: Dictionary = db.get_action(greatsword.animation_family, "PRIMARY_CHARGE")
	assert(greatsword_charge.id == "heavy_2h_primary_charge_1" and greatsword_charge.charge_guard_window.start_ratio == 0.65 and greatsword_charge.charge_guard_window.end_ratio == 0.85)
	assert(greatsword_charge.charge_release_guard_window.end == 0.20)
	for career in db.careers.values():
		assert(career.max_level == 10 and career.required_level <= career.max_level)
		var inherited_skills: Array = career.skills.duplicate()
		var ancestors: Array[String] = [str(career.id)]
		var node: Dictionary = career
		while node.has("parent_career"):
			assert(db.careers.has(node.parent_career))
			assert(str(node.parent_career) not in ancestors, "Career graph cannot contain an ancestor cycle")
			ancestors.append(str(node.parent_career))
			node = db.careers[node.parent_career]
			inherited_skills.append_array(node.skills)
		assert(node.id == career.base_career, "Every advancement chain must reach its declared base career")
		for id in career.skills:
			assert(db.skills.has(id), str(id))
		for id in career.passives:
			assert(db.passives.has(id), str(id))
		for id in career.next_careers:
			assert(db.careers.has(id), str(id))
		if career.has("preferred_skill"):
			assert(career.skills.has(career.preferred_skill), "Preferred skill must belong to its career")
		for set_index in career.default_sets.size():
			var combat_set: Dictionary = career.default_sets[set_index]
			assert(db.weapons.has(combat_set.weapon))
			assert(not combat_set.has("shield") and not combat_set.has("offhand_weapon"), "Each A/B group contains only its own weapon and three prepared skills")
			assert(combat_set.skills.size() == 3)
			for id in combat_set.skills:
				assert(inherited_skills.has(id), "Default skills must be learned or inherited")
		if career.get("loadout_rule", "") == "sword_shield_pair":
			assert(career.default_sets.size() == 2)
			assert(db.weapons[career.default_sets[0].weapon].weapon_type in ["Sword", "Katana"])
			assert(db.weapons[career.default_sets[1].weapon].weapon_type == "Shield")
			assert(career.default_sets[0].skills != career.default_sets[1].skills, "Soldier pair keeps two distinct skill preparations")
		if career.get("loadout_rule", "") == "dual_sword_pair":
			assert(career.default_sets.size() == 2)
			for combat_set in career.default_sets:
				assert(db.weapons[combat_set.weapon].weapon_type in ["Sword", "Katana"], "Dual sword defaults must contain two swords")
			assert(career.default_sets[0].weapon == "iron_longsword" and career.default_sets[1].weapon == "azure_katana")
			assert(career.default_sets[0].skills != career.default_sets[1].skills)
	for item in db.equipment.values():
		for id in item.passives:
			assert(db.passives.has(id))
	for item in db.weapons.values():
		assert(not item.has("equip_slot"), "Weapon data must not reintroduce main/off hand slots")
		for id in item.special_effects:
			assert(db.passives.has(id))
	for shield in db.shields.values():
		assert(db.weapons.has(shield.id) and db.weapons[shield.id] == shield)
		assert(shield.weapon_type == "Shield" and shield.animation_family == "SHIELD")
		for field in ["physical_reduction", "elemental_reduction", "stamina_cost", "angle", "perfect_window", "move_multiplier", "compatible_families"]:
			assert(shield.has(field), "Shield missing " + field)
		for field in ["physical_reduction", "elemental_reduction", "move_multiplier"]:
			assert(shield[field] >= 0.0 and shield[field] <= 1.0, "Invalid shield ratio: " + field)
		assert(shield.stamina_cost >= 0 and shield.angle > 0 and shield.angle <= 360 and shield.perfect_window > 0)
		assert(not shield.compatible_families.is_empty())
		for family in shield.compatible_families:
			assert(db.get_combo_count(family) > 0, "Unknown compatible weapon family")
	var original_angle: float = db.weapons.wooden_shield.angle
	db.weapons.wooden_shield.angle = 121.0
	assert(db.shields.wooden_shield.angle == 121.0, "Compatibility view must read the same canonical weapon definition")
	db.weapons.wooden_shield.angle = original_angle
	for reaction in db.reactions.values():
		assert(reaction.get("is_reaction", false) and not reaction.get("is_skill", true))
		assert(not db.skills.has(reaction.id) and not db.actions.has(reaction.id), "Reactions must not occupy skill or weapon-action catalogs")
		assert(reaction.costs.is_empty() and reaction.cooldown == 0)
		assert(reaction.startup >= 0 and reaction.active > 0 and reaction.recovery > 0)
		if reaction.targeting == "SELF":
			assert(not reaction.has("formula") and reaction.has("guard_window"), "Non-damaging defense reaction must contain a guard window, not a damage formula")
		else:
			assert(not reaction.formula.is_empty() and reaction.startup > 0)
	assert(db.reactions.shield_raise.animation_family == "SHIELD")
	assert(db.get_action("SHIELD", "PRIMARY_TAP").is_empty(), "Shield uses its raise reaction rather than an attack combo")
	var defensive_actions: Array = db.actions.values() + db.skills.values() + db.reactions.values()
	for action in defensive_actions:
		if action.has("charge_guard_window"):
			var charge_window: Dictionary = action.charge_guard_window
			assert(charge_window.start_ratio >= 0 and charge_window.end_ratio > charge_window.start_ratio and charge_window.end_ratio <= 1)
			assert(action.has("charge_release_guard_window"), "Timed charge defense must declare its release handoff")
			assert(not str(action.get("description", "")).is_empty(), "Timed charge defense needs an explanation for the player")
		for window_key in ["guard_window", "counter_stance", "hyper_armor", "charge_release_guard_window"]:
			if not action.has(window_key):
				continue
			var window: Dictionary = action[window_key]
			assert(window.start >= 0 and window.end > window.start)
			assert(window.end <= action.startup + action.active + action.recovery, "Defense window exceeds its action")
			if window_key in ["guard_window", "charge_release_guard_window"]:
				assert(window.perfect_window > 0 and window.perfect_window <= window.end - window.start)
			if window_key == "counter_stance":
				assert(db.reactions.has(window.counter_action), "Counter stance reaction must exist")
				assert(not action.has("formula"), "Counter stance itself must not create a damage hit")
	for enemy in db.enemies.values():
		if enemy.has("shield"):
			assert(db.shields.has(enemy.shield), "Enemy shield must exist")
		if enemy.has("grab_action"):
			var grab: Dictionary = enemy.grab_action
			assert(grab.attack_kind == "GRAB" and not grab.blockable and not grab.parryable)
			assert(grab.grab_duration > 0 and enemy.grab_every > 0)
			assert(not grab.can_crit and not grab.knockdown and grab.effects.is_empty())
	var expected = {"warrior":[1070,60,3,99],"rogue":[840,60,3,70],"barbarian":[1236,80,4,131],"mage":[720,60,2,53]}
	# Fixed Lv10 targets from the non-linear resource design; HP/Poise keep their existing budgets.
	var expected_level_ten = {"warrior":[1520,180,10,99],"rogue":[1245,180,10,70],"barbarian":[1776,200,11,131],"mage":[1035,290,5,53]}
	for id in expected:
		var c = db.careers[id]
		var variables = PackedStringArray(["STR","DEX","CON","INT","PER","CHA","level"])
		for level in [1,2,3,9,10]:
			var input_values = []
			for stat in ["STR","DEX","CON","INT","PER","CHA"]:
				input_values.append(c.stats[stat])
			input_values.append(level)
			var results = []
			for resource in ["HP","Energy","Stamina","Poise"]:
				var expression = Expression.new()
				assert(expression.parse(c.formulas[resource],variables) == OK)
				var value = expression.execute(input_values)
				assert(not expression.has_execute_failed())
				results.append(value)
			if level == 1:
				for index in results.size():
					assert(is_equal_approx(float(results[index]), float(expected[id][index])), "%s %s" % [id, results])
			if level == 3:
				assert(results[1] == expected[id][1] + 20)
			if level == 10:
				for index in results.size():
					assert(is_equal_approx(float(results[index]), float(expected_level_ten[id][index])), "Lv10 formula must not be capped at Lv3: %s %s" % [id, results])
	for family in ["SINGLE_BLADE","SHORT_WEAPON","POLEARM","HEAVY_2H","BOW","CASTER"]:
		for semantic in ["PRIMARY_TAP","PRIMARY_CHARGE","SECONDARY_TAP","SECONDARY_CHARGE"]:
			var a = db.get_action(family,semantic)
			assert(not a.is_empty())
			assert(a.semantic == semantic)
			assert(a.animation_family == family)
			assert(a.cooldown == 0)
			assert(a.startup > 0 and a.active > 0 and a.recovery > 0)
			var untouched = db.get_action(family,semantic)
			a.formula.base = 9000
			assert(db.get_action(family,semantic).formula == untouched.formula)
	assert(db.get_combo_count("SINGLE_BLADE") == 3)
	assert(db.get_combo_count("SHORT_WEAPON") == 4)
	assert(db.get_combo_count("POLEARM") == 3)
	assert(db.get_combo_count("HEAVY_2H") == 3)
	assert(db.get_action("SINGLE_BLADE","PRIMARY_TAP",3).combo_index == 0)
	print("CATALOG VALIDATED: 14 careers / 32 skills / 36 actions / 11 weapons / 12 equipment / 4 enemies / 2 derived shields / 3 reactions; Dreamwalk level rule/manual preparation, A/B-only loadouts, recursive career inheritance, Lv10 dual swords, canonical shield view, charge windows, reaction isolation and Lv1-Lv10 formulas passed")
	quit(0)
