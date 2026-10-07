extends Node

signal changed

const InteractionReadiness = preload("res://rpg/interaction_readiness.gd")

const SLOTS := ["head", "torso", "legs", "feet", "belt", "ring1", "ring2", "neck"]
const UNARMED := {"id":"", "name":"徒手拳击", "weapon_type":"Unarmed", "animation_family":"UNARMED", "weapon_scaling":0, "unarmed":true, "conditions":[], "special_effects":[]}
var actor: Node
var database: RefCounted
var level := 0
var career_ids: Array[String] = []
var equipment: Dictionary = {}
var sets: Array[Dictionary] = [{"weapon": "", "skills": ["", "", ""]}, {"weapon": "", "skills": ["", "", ""]}]
var current_set := 0
var unlocked_skills: Array[String] = []
var passive_ids: Array[String] = []
var proficiencies: Array = []
var resource_rules: Dictionary = {}
var last_error := ""
var sandbox_mode := true
var inventory: Node
var progression: Node
var available_skills: Array[String] = []
var learned_skills: Array[String] = []

func setup(owner_actor: Node, data: RefCounted) -> void:
	actor = owner_actor
	database = data
	for slot in SLOTS:
		equipment[slot] = ""

func configure_progression(items: Node, growth: Node) -> void:
	inventory = items
	progression = growth
	sandbox_mode = false

func apply_progression_career(id: String, first: bool) -> void:
	var career: Dictionary = database.careers[id]
	var initial := level == 0
	if first:
		career_ids.assign([id])
		level = maxi(1, level)
		actor.stats.set_base(career.get("stats", {}))
		sets.assign(career.get("default_sets", sets).duplicate(true))
		current_set = 0
	else:
		career_ids.append(id)
		if career.get("loadout_rule", "") in ["sword_shield_pair", "dual_sword_pair"]:
			var presets: Array = career.get("default_sets", [])
			if presets.size() == 2:
				if weapon_at(0).get("weapon_type", "") not in ["Sword", "Katana"]:
					sets[0]["weapon"] = presets[0].get("weapon", "")
				sets[1]["weapon"] = presets[1].get("weapon", "")
	# Recommendations do not teach skills. Existing prepared, learned skills stay.
	_rebuild(first and initial)

func select_career(id: String) -> bool:
	if not sandbox_mode:
		var selected: bool = progression.choose_career(id)
		last_error = progression.last_error
		return selected
	if not database.careers.has(id):
		return false
	var career: Dictionary = database.careers[id]
	var required := int(career.get("required_level", 1))
	if required > 1:
		if level < required or career_ids.is_empty():
			last_error = "需要达到 Lv%d" % required
			return false
		var parent: Dictionary = database.careers[career_ids.back()]
		if id not in parent.get("next_careers", []):
			last_error = "当前职业无法进阶到此职业"
			return false
		career_ids.append(id)
		if career.get("loadout_rule", "") in ["sword_shield_pair", "dual_sword_pair"]:
			var presets: Array = career.get("default_sets", [])
			if presets.size() == 2:
				sets[1] = presets[1].duplicate(true)
		var preferred: String = career.get("preferred_skill", "")
		if not preferred.is_empty():
			sets[current_set].skills[2] = preferred
	else:
		career_ids.assign([id])
		level = 1
		equipment.clear()
		for slot in SLOTS:
			equipment[slot] = ""
		actor.stats.modifiers.clear()
		actor.stats.set_base(career.get("stats", {}))
		sets.assign(career.get("default_sets", sets).duplicate(true))
		current_set = 0
	_rebuild(true)
	actor.combat.reset()
	return true

func set_level(value: int) -> void:
	if not sandbox_mode:
		last_error = "正式角色通过经验或神奇糖果升级"
		return
	level = clampi(value, 0, int(database.progression.get("rules",{}).get("max_level",20)))
	if level == 0:
		career_ids.clear()
		sets = [{"weapon": "", "skills": ["", "", ""]}, {"weapon": "", "skills": ["", "", ""]}]
	elif career_ids.is_empty():
		last_error = "请先选择基础职业"
		level = 0
	while not career_ids.is_empty() and int(database.careers[career_ids.back()].get("required_level", 1)) > level:
		career_ids.pop_back()
	_rebuild(true)

func weapon() -> Dictionary:
	return weapon_at(current_set)

func weapon_at(index: int) -> Dictionary:
	if index < 0 or index >= sets.size():
		return {}
	if str(sets[index].get("weapon", "")).is_empty(): return UNARMED.duplicate(true)
	return database.weapons.get(sets[index].get("weapon", ""), {})

func paired_style() -> String:
	for index in range(career_ids.size() - 1, -1, -1):
		var rule: String = database.careers.get(career_ids[index], {}).get("loadout_rule", "")
		if rule in ["sword_shield_pair", "dual_sword_pair"]:
			return rule
	return ""

func uses_paired_weapons() -> bool:
	return not paired_style().is_empty()

func is_dual_wielding() -> bool:
	return paired_style() == "dual_sword_pair"

func combat_weapon() -> Dictionary:
	return weapon_at(0) if paired_style() == "sword_shield_pair" else weapon()

func shield() -> Dictionary:
	var data := weapon_at(1) if paired_style() == "sword_shield_pair" else weapon()
	return data if data.get("weapon_type", "") == "Shield" else {}

func can_equip_weapon(id: String) -> String:
	if id.is_empty():
		return ""
	if not database.weapons.has(id):
		return "武器不存在"
	if not sandbox_mode and inventory.count(id) <= 0:
		return "尚未持有此武器"
	var data: Dictionary = database.weapons[id]
	var context: Dictionary = actor.combat.context()
	context["proficiencies"] = proficiencies.duplicate()
	if data.get("weapon_type", "") in proficiencies or actor.combat.has_permission(data.get("weapon_type", "")):
		context.proficiencies.append(data.get("animation_family", ""))
	var proficiency_error := CombatConditions.check_all([{"type": "proficiency", "value": data.get("animation_family", "")}], context)
	if not proficiency_error.is_empty():
		return proficiency_error
	return CombatConditions.check_all(data.get("conditions", data.get("requirements", [])), context)

func can_equip_set_weapon(set_index: int, id: String) -> String:
	if set_index < 0 or set_index >= sets.size():
		return "战斗组无效"
	if id.is_empty():
		return ""
	if not sandbox_mode:
		var needed := 1
		for index in range(sets.size()):
			if index != set_index and sets[index].get("weapon", "") == id:
				needed += 1
		if inventory.count(id) < needed:
			return "持有数量不足，两组装备同型号需要两件"
	var type: String = database.weapons.get(id, {}).get("weapon_type", "")
	if paired_style() == "sword_shield_pair":
		if set_index == 1 and type != "Shield":
			return "士兵的 B 组必须装备盾牌"
		if set_index == 0 and type not in ["Sword", "Katana"]:
			return "士兵的 A 组必须装备剑"
	elif is_dual_wielding() and type not in ["Sword", "Katana"]:
		return "二刀流的两组都必须装备剑"
	return can_equip_weapon(id)

func equip_weapon(set_index: int, id: String) -> bool:
	if not InteractionReadiness.can_manage(actor):
		last_error = "动作结束后才能更换装备"
		return false
	last_error = can_equip_set_weapon(set_index, id)
	if not last_error.is_empty() or set_index < 0 or set_index > 1:
		return false
	sets[set_index]["weapon"] = id
	changed.emit()
	if not sandbox_mode:
		inventory.changed.emit()
	return true

func equip_item(slot: String, id: String) -> bool:
	last_error = can_equip_item(slot, id)
	if not last_error.is_empty():
		return false
	if id.is_empty():
		equipment[slot] = ""
		actor.stats.remove_modifier("equipment_" + slot)
		_rebuild(false)
		return true
	var item: Dictionary = database.equipment[id]
	equipment[slot] = id
	actor.stats.add_modifier("equipment_" + slot, item.get("modifiers", {}))
	_rebuild(false)
	return true

func can_equip_item(slot: String, id: String) -> String:
	if not InteractionReadiness.can_manage(actor):
		return "动作结束后才能更换装备"
	if slot not in SLOTS:
		return "装备槽无效"
	if id.is_empty():
		return ""
	if not database.equipment.has(id):
		return "装备不存在"
	if not sandbox_mode:
		var needed := 1
		for other in equipment:
			if other != slot and equipment[other] == id:
				needed += 1
		if inventory.count(id) < needed:
			return "尚未持有足够的此装备"
	var item: Dictionary = database.equipment[id]
	var item_slot: String = item.get("slot", "")
	if item_slot != slot and not (item_slot == "ring" and slot in ["ring1", "ring2"]):
		return "装备槽不匹配"
	var context: Dictionary = actor.combat.context()
	# An item's own stats cannot satisfy the requirement for its replacement.
	var stats: Dictionary = context["stats"].duplicate()
	var previous: Dictionary = actor.stats.modifiers.get("equipment_" + slot, {})
	for key in previous:
		stats[key] = float(stats.get(key, 0.0)) - float(previous[key])
	context["stats"] = stats
	var reason := CombatConditions.check_all(item.get("conditions", item.get("requirements", [])), context)
	if not reason.is_empty():
		return reason
	if sandbox_mode:
		for other in equipment:
			if other != slot and equipment[other] == id:
				return "同一件装备不能占用两个槽位"
	return ""

func assign_skill(set_index: int, slot: int, id: String) -> bool:
	if set_index < 0 or set_index > 1 or slot < 0 or slot > 2 or (not id.is_empty() and id not in unlocked_skills):
		last_error = "技能槽无效，或此技能尚未学习"
		return false
	if not sandbox_mode and not InteractionReadiness.can_manage(actor):
		last_error = "动作结束后才能配置技能"
		return false
	sets[set_index]["skills"][slot] = id
	last_error = ""
	changed.emit()
	return true

func evaluate_formula(formula: Variant) -> float:
	if formula is float or formula is int:
		return float(formula)
	var expression := Expression.new()
	var names := PackedStringArray(["STR", "DEX", "CON", "INT", "PER", "CHA", "level"])
	if expression.parse(str(formula), names) != OK:
		push_error("Invalid career formula: " + str(formula))
		return 0.0
	var values: Array = []
	for stat in CombatStats.IDS:
		values.append(actor.stats.get_final_stat(stat))
	values.append(level)
	var result: Variant = expression.execute(values, null, false)
	return 0.0 if expression.has_execute_failed() else float(result)

func _rebuild(fill: bool) -> void:
	_normalize_weapon_layout()
	unlocked_skills.clear()
	available_skills.clear()
	passive_ids.clear()
	proficiencies.clear()
	resource_rules.clear()
	for id in career_ids:
		var career: Dictionary = database.careers[id]
		resource_rules.merge(career.get("resource_rules", {}), true)
		for skill in career.get("skills", []):
			if skill not in available_skills and int(database.skills.get(skill, {}).get("min_level", 1)) <= level:
				available_skills.append(skill)
				if sandbox_mode or skill in learned_skills:
					unlocked_skills.append(skill)
		for passive in career.get("passives", []):
			if passive not in passive_ids and int(database.passives.get(passive, {}).get("min_level", 1)) <= level:
				passive_ids.append(passive)
		for proficiency in career.get("proficiencies", []):
			if proficiency not in proficiencies:
				proficiencies.append(proficiency)
	for id in equipment.values():
		for passive in database.equipment.get(id, {}).get("passives", []):
			if passive not in passive_ids:
				passive_ids.append(passive)
	for combat_set in sets:
		for i in range(3):
			if combat_set.skills[i] not in unlocked_skills:
				combat_set.skills[i] = ""
	refresh_resources(fill)
	for resource in ["Stamina", "Energy"]:
		actor.resources.unlimited[resource] = bool(resource_rules.get(resource, {}).get("unlimited", false))
	actor.resources.unlimited.erase("Qi")
	actor.resources.unlimited.erase("SpellSlot")
	changed.emit()

func _normalize_weapon_layout() -> void:
	for combat_set in sets:
		# Keep only the two group weapons and their own skill loadouts.
		for field in combat_set.keys():
			if field not in ["weapon", "skills"]:
				combat_set.erase(field)
	if not sandbox_mode:
		var used: Dictionary = {}
		for index in range(sets.size()):
			var id: String = sets[index].get("weapon", "")
			var type: String = database.weapons.get(id, {}).get("weapon_type", "")
			var valid_pair := true
			if paired_style() == "sword_shield_pair":
				valid_pair = type == "Shield" if index == 1 else type in ["Sword", "Katana"]
			elif is_dual_wielding():
				valid_pair = type in ["Sword", "Katana"]
			elif type == "Shield":
				valid_pair = false
			if not valid_pair or inventory.count(id) <= int(used.get(id, 0)):
				sets[index].weapon = ""
			else:
				used[id] = int(used.get(id, 0)) + 1
		return
	if uses_paired_weapons():
		if database.weapons.get(sets[0].weapon, {}).get("weapon_type", "") not in ["Sword", "Katana"]:
			sets[0].weapon = "iron_longsword"
		if paired_style() == "sword_shield_pair" and weapon_at(1).get("weapon_type", "") != "Shield":
			sets[1].weapon = "wooden_shield"
		elif is_dual_wielding() and weapon_at(1).get("weapon_type", "") not in ["Sword", "Katana"]:
			sets[1].weapon = "azure_katana"
	else:
		var defaults: Array = database.careers.get(career_ids[0], {}).get("default_sets", []) if not career_ids.is_empty() else []
		for index in range(sets.size()):
			if weapon_at(index).get("weapon_type", "") == "Shield":
				sets[index].weapon = defaults[index].weapon if defaults.size() > index else ""

func refresh_resources(fill := false) -> void:
	var formulas: Dictionary = database.careers[career_ids[0]].get("formulas", {}) if not career_ids.is_empty() else {"HP": 100, "Stamina": 3, "Poise": 50}
	# A unit's native resource profile overrides only the keys it defines.
	# Empty profiles retain career growth; native monsters keep their own pools
	# when the same loadout/progression components are attached or rebuilt.
	var profile: Variant = actor.get("resource_profile")
	formulas = formulas.duplicate(true)
	if not formulas.has("Energy"):
		formulas["Energy"] = _legacy_energy_maximum(formulas)
	if profile is Dictionary and not profile.is_empty():
		formulas.merge(profile, true)
		if not profile.has("Energy") and (profile.has("Qi") or profile.has("SpellSlot")):
			formulas["Energy"] = _legacy_energy_maximum(profile)
	for resource in ["HP", "Stamina", "Energy"]:
		actor.resources.configure(resource, maxf(0.0, evaluate_formula(formulas.get(resource, 0))), fill, resource == "Energy")
	actor.resources.pools.erase("Qi")
	actor.resources.pools.erase("SpellSlot")
	actor.combat.base_poise = maxf(1.0, evaluate_formula(formulas.get("Poise", 50)))
	actor.combat.current_poise = actor.combat.base_poise if fill else minf(actor.combat.current_poise, actor.combat.max_poise())

func _legacy_energy_maximum(formulas: Dictionary) -> float:
	return maxf(evaluate_formula(formulas.get("Qi", 0)), evaluate_formula(formulas.get("SpellSlot", 0))) * CombatResources.LEGACY_ENERGY_SCALE

func export_state() -> Dictionary:
	return {"level": level, "career_ids": career_ids.duplicate(), "equipment": equipment.duplicate(true), "sets": sets.duplicate(true), "current_set": current_set, "learned_skills": learned_skills.duplicate()}

func import_state(state: Dictionary) -> void:
	career_ids.clear()
	var level_cap := int(database.progression.get("rules", {}).get("max_level", 10))
	level = clampi(int(state.get("level", 0)), 0, level_cap)
	var native: Variant = actor.get("definition")
	for id in state.get("career_ids", []):
		if not database.careers.has(str(id)) or int(database.careers[str(id)].get("required_level", 1)) > level:
			break
		if career_ids.is_empty():
			if int(database.careers[str(id)].get("required_level", 1)) != 1:
				break
		elif str(id) not in database.careers[career_ids.back()].get("next_careers", []):
			break
		career_ids.append(str(id))
	if career_ids.is_empty():
		# Returning civilians retain earned levels. Fresh civilians still start
		# at zero; save validation also requires a matching starter receipt.
		if native is Dictionary and int(native.get("level", 0)) > 0:
			level = maxi(1, level)
		elif not is_instance_valid(progression) or not progression.starter_granted:
			level = 0
	for key in actor.stats.modifiers.keys():
		if str(key).begins_with("equipment_"):
			actor.stats.modifiers.erase(key)
	var native_stats: Dictionary = native.get("stats", {}) if native is Dictionary else {}
	actor.stats.set_base(database.careers.get(career_ids[0], {}).get("stats", {}) if not career_ids.is_empty() else native_stats)
	learned_skills.clear()
	for id in state.get("learned_skills", []):
		if database.skills.has(str(id)) and str(id) not in learned_skills:
			learned_skills.append(str(id))
	sets = [{"weapon": "", "skills": ["", "", ""]}, {"weapon": "", "skills": ["", "", ""]}]
	var saved_sets: Array = state.get("sets", [])
	for index in range(mini(2, saved_sets.size())):
		if not saved_sets[index] is Dictionary:
			continue
		sets[index].weapon = str(saved_sets[index].get("weapon", ""))
		var skills: Array = saved_sets[index].get("skills", [])
		for slot in range(mini(3, skills.size())):
			sets[index].skills[slot] = str(skills[slot])
	current_set = clampi(int(state.get("current_set", 0)), 0, 1)
	var used: Dictionary = {}
	for slot in SLOTS:
		var id: String = str(state.get("equipment", {}).get(slot, ""))
		var item: Dictionary = database.equipment.get(id, {})
		var slot_ok: bool = item.get("slot", "") == slot or (item.get("slot", "") == "ring" and slot in ["ring1", "ring2"])
		if not slot_ok or (not sandbox_mode and inventory.count(id) <= int(used.get(id, 0))):
			id = ""
		equipment[slot] = id
		if not id.is_empty():
			used[id] = int(used.get(id, 0)) + 1
			actor.stats.modifiers["equipment_" + slot] = item.get("modifiers", {}).duplicate(true)
	_rebuild(false)
	last_error = ""
