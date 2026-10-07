extends RefCounted
## Pure unit templates. Controllers, ownership and scene nodes are attached by
## CombatActor; every returned nested value is independent of the source catalog.
const Races = preload("res://rpg/race_catalog.gd")

static func for_player() -> Dictionary:
	return {
		"id": "hero", "name": "桐人", "race_id": Races.DEFAULT_ID, "faction_id": "heroes", "level": 0,
		"stats": {}, "resource_profile": {}, "innate_actions": {}, "innate_skills": [],
		"movement": {"speed": 5.2},
		"body": {"radius": .27, "height": 1.3, "scale": Vector3.ONE},
		"visual": {"kind": "kirito", "color": "#FFFFFF", "scale": 1.0, "animation_family": "UNARMED"},
		"ai": {"aggro_range": 9.0, "attack_cooldown": 2.5, "grab_every": 0},
		"combat": {"damage": 65.0, "poise_damage": 35.0, "range": 2.1, "resistances": {},
			"immune_to_launch": false, "immune_to_knockdown": false, "is_boss": false, "shield_id": ""},
	}

static func for_enemy(database: RefCounted, id: String) -> Dictionary:
	if not database.enemies.has(id): return {}
	var data: Dictionary = database.enemies[id]
	var stats: Dictionary = data.get("stats", {}).duplicate(true)
	for attribute in ["STR", "DEX", "CON", "INT", "PER", "CHA"]:
		if not stats.has(attribute): stats[attribute] = 0.0
	if not stats.has("Armor"): stats.Armor = data.get("armor", data.get("Armor", 0.0))
	var primary: Dictionary = data.get("action", {}).duplicate(true)
	var actions := _innate_actions(data)
	var primary_entry: Variant = actions.get("PRIMARY_TAP", primary)
	if primary_entry is Array:
		primary = primary_entry[0] if not primary_entry.is_empty() else {}
	elif primary_entry is Dictionary:
		primary = primary_entry
	var launch_immune: bool = data.get("immune_to_launch", false)
	var boss: bool = data.get("is_boss", launch_immune)
	var result := {
		"id": str(data.get("id", id)), "name": str(data.get("name", id)),
		"level": int(data.get("level", 1)),
		"race_id": str(data.get("race_id", Races.DEFAULT_ID)),
		"faction_id": str(data.get("faction_id", "hostiles")),
		"stats": stats,
		"resource_profile": {"HP": float(data.get("hp", data.get("HP", data.get("max_hp", 1200)))),
			"Stamina": float(data.get("stamina", data.get("Stamina", 3))),
			"Energy": float(data.get("Energy", maxf(float(data.get("Qi", 0)), float(data.get("SpellSlot", 0))) * CombatResources.LEGACY_ENERGY_SCALE)),
			"Poise": float(data.get("poise", data.get("Poise", data.get("max_poise", 80))))},
		"innate_actions": actions, "innate_skills": _innate_skills(database, data),
		"movement": {"speed": float(data.get("move_speed", 2.3))},
		"body": {"radius": .35, "height": 1.5, "scale": Vector3(1.5, 1.3, 1.5) if boss else Vector3.ONE},
		"visual": {"kind": "procedural", "color": str(data.get("color", "#A87F69")),
			"scale": 1.5 if boss else 1.0, "animation_family": str(primary.get("animation_family", "SINGLE_BLADE"))},
		"ai": {"aggro_range": float(data.get("aggro_range", 9.0)),
			"attack_cooldown": float(data.get("attack_cooldown", 2.5)), "grab_every": int(data.get("grab_every", 0))},
		"combat": {"damage": float(data.get("damage", 75)), "poise_damage": float(data.get("poise_damage", 40)),
			"range": float(data.get("range", 2.0)), "resistances": data.get("resistance", data.get("resistances", {})).duplicate(true),
			"immune_to_launch": launch_immune, "immune_to_knockdown": bool(data.get("immune_to_knockdown", false)),
			"is_boss": boss, "shield_id": str(data.get("shield", ""))},
	}
	return result

static func _innate_actions(data: Dictionary) -> Dictionary:
	var actions := {}
	for semantic in data.get("innate_actions", {}):
		var entry: Variant = data.innate_actions[semantic]
		if entry is Dictionary and not entry.is_empty():
			actions[semantic] = entry.duplicate(true)
		elif entry is Array:
			var sequence: Array[Dictionary] = []
			for action in entry:
				if action is Dictionary and not action.is_empty(): sequence.append(action.duplicate(true))
			if not sequence.is_empty(): actions[semantic] = sequence
	var primary: Dictionary = data.get("action", {}).duplicate(true)
	if not actions.has("PRIMARY_TAP") and not primary.is_empty(): actions.PRIMARY_TAP = primary
	# Grab is a QER ability. A mouse attack can have its own explicit definition,
	# but never silently inherits a special skill from the legacy grab field.
	var secondary: Dictionary = data.get("secondary_action", primary).duplicate(true)
	if not actions.has("SECONDARY_TAP") and not secondary.is_empty(): actions.SECONDARY_TAP = secondary
	return actions

static func _innate_skills(database: RefCounted, data: Dictionary) -> Array[Dictionary]:
	var skills: Array[Dictionary] = []
	var seen: Dictionary = {}
	var grab: Dictionary = data.get("grab_action", {}).duplicate(true)
	var grab_id := str(grab.get("id", ""))
	for entry in data.get("innate_skills", []):
		var skill: Dictionary = entry.duplicate(true) if entry is Dictionary else database.skills.get(str(entry), {}).duplicate(true)
		var id := str(skill.get("id", ""))
		if id.is_empty() or seen.has(id): continue
		skill["is_skill"] = true
		if id == grab_id and not skill.has("ai_attack_every"):
			skill["ai_attack_every"] = maxi(0, int(data.get("grab_every", 0)))
		skills.append(skill)
		seen[id] = true
	# Legacy special attacks are exposed through QER. AI cadence is independent
	# of a human pressing the shortcut, and never aliases a mouse attack.
	if not grab_id.is_empty() and not seen.has(grab_id):
		grab["is_skill"] = true
		grab["ai_attack_every"] = maxi(0, int(data.get("grab_every", 0)))
		skills.append(grab)
	return skills
