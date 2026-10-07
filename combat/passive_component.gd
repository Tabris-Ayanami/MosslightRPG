extends Node

var actor: Node
var internal_cooldowns: Dictionary = {}
var counters: Dictionary = {}
var element_history: Array[String] = []

func tick(delta: float) -> void:
	for id in internal_cooldowns:
		internal_cooldowns[id] = maxf(0.0, float(internal_cooldowns[id]) - delta)

func definitions(weapon_override: Variant = null) -> Array:
	var result: Array = []
	for id in actor.loadout.passive_ids:
		var passive: Dictionary = actor.arena.database.passives.get(id, {})
		if not passive.is_empty():
			result.append(passive)
	if is_instance_valid(actor.progression):
		for id in actor.progression.acquired_traits:
			var passive: Dictionary=actor.arena.database.passives.get(id,{})
			if not passive.is_empty() and passive not in result: result.append(passive)
	var weapons: Array = [actor.loadout.combat_weapon()] if weapon_override == null else [weapon_override]
	if weapon_override == null and actor.loadout.uses_paired_weapons():
		weapons = [actor.loadout.weapon_at(0), actor.loadout.weapon_at(1)]
	for weapon in weapons:
		for effect in weapon.get("special_effects", []):
			var passive: Dictionary = actor.arena.database.passives.get(effect, {}) if effect is String else effect
			# A shared defensive/stat effect applies once while both weapons are
			# held. Hit packets explicitly select the blade that made that hit.
			if not passive.is_empty() and passive not in result:
				result.append(passive)
	return result

func modifiers(event: String, context: Dictionary, weapon_override: Variant = null) -> Dictionary:
	return _modifiers(event, context, definitions(weapon_override))

func actor_modifiers(event: String, target: Node = null, action: Dictionary = {}, weapon_override: Variant = null) -> Dictionary:
	# Most units have no passive for a given event. Do not build a full combat
	# context for them, or for unconditional effects that never read that context.
	var applicable: Array = []
	var conditional := false
	for passive in definitions(weapon_override):
		if passive.get("event", "damage_before") != event or float(internal_cooldowns.get(passive.get("id", ""), 0.0)) > 0.0: continue
		var has_modifier := false
		var has_condition: bool = not passive.get("conditions", []).is_empty()
		for effect in passive.get("effects", []):
			if effect.get("type", "") in ["modifier", "forced_crit"]:
				has_modifier = true
				has_condition = has_condition or not effect.get("conditions", []).is_empty()
		if has_modifier:
			applicable.append(passive)
			conditional = conditional or has_condition
	if applicable.is_empty(): return {}
	return _modifiers(event, actor.combat.context(target, action) if conditional else {}, applicable)

func _modifiers(event: String, context: Dictionary, applicable: Array) -> Dictionary:
	context = context.duplicate()
	context["event"] = event
	var result: Dictionary = {}
	for passive in applicable:
		if passive.get("event", "damage_before") != event or float(internal_cooldowns.get(passive.get("id", ""), 0.0)) > 0.0:
			continue
		if not CombatConditions.check_all(passive.get("conditions", []), context).is_empty():
			continue
		for effect in passive.get("effects", []):
			if not CombatConditions.check_all(effect.get("conditions", []), context).is_empty():
				continue
			var type: String = effect.get("type", "")
			if type == "modifier":
				var stat: String = effect.get("stat", "")
				if stat == "damage_multiplier":
					stat = "damage_bonus"
				result[stat] = float(result.get(stat, 0.0)) + float(effect.get("value", 0.0))
			elif type == "forced_crit":
				result["forced_crit"] = true
	return result

func trigger(event: String, context: Dictionary, weapon_override: Variant = null) -> void:
	context = context.duplicate()
	context["event"] = event
	for passive in definitions(weapon_override):
		var id: String = passive.get("id", "")
		if passive.get("event", "damage_before") != event or float(internal_cooldowns.get(id, 0.0)) > 0.0:
			continue
		if not CombatConditions.check_all(passive.get("conditions", []), context).is_empty():
			continue
		var applied := false
		for effect in passive.get("effects", []):
			if not CombatConditions.check_all(effect.get("conditions", []), context).is_empty():
				continue
			if effect.get("type", "") not in ["modifier", "forced_crit", "hit_sequence", "element_sequence"]:
				actor.combat.apply_effect(effect, actor)
				applied = true
		if applied:
			internal_cooldowns[id] = float(passive.get("cooldown", 0.0))

func prepare_action(action: Dictionary, weapon_override: Variant = null) -> float:
	var bonus := 0.0
	for passive in definitions(weapon_override):
		for effect in passive.get("effects", []):
			var id: String = passive.get("id", "")
			if effect.get("type", "") == "hit_sequence" and int(counters.get(id, 0)) >= int(effect.get("count", 3)):
				if action.get("presentation_type", "") == effect.get("presentation_type", "WEAPON_ACTION") and (not effect.get("skill_only", true) or action.get("is_skill", false)):
					bonus += float(effect.get("multiplier", 0.2))
					counters[id] = 0
			if effect.get("type", "") == "element_sequence" and action.get("presentation_type", "") == "CASTER_ACTION":
				var element: String = action.get("damage_type", "PHYSICAL")
				if element != "PHYSICAL":
					if element in element_history:
						element_history.clear()
					element_history.append(element)
					if element_history.size() >= int(effect.get("count", 3)):
						bonus += float(effect.get("multiplier", 0.25))
						element_history.clear()
	return bonus

func record_hit(weapon_override: Variant = null) -> void:
	for passive in definitions(weapon_override):
		for effect in passive.get("effects", []):
			if effect.get("type", "") == "hit_sequence":
				var id: String = passive.get("id", "")
				counters[id] = mini(int(effect.get("count", 3)), int(counters.get(id, 0)) + 1)

func reset_combat() -> void:
	counters.clear()
	element_history.clear()
