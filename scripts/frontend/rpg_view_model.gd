extends RefCounted
## Formatting only: ownership, costs and progression are enforced by RPG components.
const FIXTURES = preload("res://scripts/frontend/prototype_content.gd")
const RACES = preload("res://rpg/race_catalog.gd")
const TRAITS = preload("res://scripts/frontend/trait_notes.gd")
const SLOT_NAMES := {"head":"头部", "torso":"上衣", "legs":"腿部", "feet":"鞋履", "belt":"腰带", "ring1":"戒指一", "ring2":"戒指二", "neck":"项链"}
const STAT_NAMES := {"STR":"力量", "DEX":"敏捷", "CON":"体质", "INT":"智力", "PER":"感知", "CHA":"魅力", "Armor":"护甲"}
const RESOURCE_NAMES := {"HP":"生命", "Stamina":"体力", "Energy":"能量"}

static func number(value: float) -> String: return String.num(value,2)

static func icon(definition: Dictionary) -> String:
	if definition.is_empty(): return ""
	if definition.has("icon"): return str(definition.icon)
	var type: String = definition.get("weapon_type", "")
	var weapon_icons := {"Sword":"sword", "Katana":"katana", "Dagger":"dagger", "Axe":"axe", "GreatAxe":"axe", "Greatsword":"greatsword", "Spear":"spear"}
	if weapon_icons.has(type): return weapon_icons[type]
	if type in ["Bow", "Crossbow"]: return "bow"
	if type in ["Staff", "Wand"]: return "staff"
	if type == "Orb": return "orb"
	if type == "Shield": return "shield"
	if type == "Unarmed": return "fist"
	var slot: String = definition.get("slot", "")
	if slot in ["ring", "ring1", "ring2", "neck"]: return "ring"
	if slot == "feet": return "boot"
	if not slot.is_empty(): return "coat"
	if definition.get("category", "") == "consumable": return "apple" if str(definition.get("id", "")).contains("candy") else "potion"
	return "wind"

static func costs(values: Dictionary) -> String:
	var parts: PackedStringArray = []
	for id in values:
		if float(values[id]) > 0:
			parts.append("%s %s" % [number(float(values[id])), RESOURCE_NAMES.get(id, id)])
	return " / ".join(parts) if not parts.is_empty() else "无消耗"

static func modifiers(values: Dictionary) -> String:
	var parts: PackedStringArray = []
	for id in values:
		parts.append("%s %s%s" % [STAT_NAMES.get(id, id), "+" if float(values[id])>=0 else "", number(float(values[id]))])
	return " · ".join(parts) if not parts.is_empty() else "无属性加成"

static func description(definition: Dictionary) -> String:
	var supplied: String = definition.get("description", definition.get("note", ""))
	if not supplied.is_empty():
		var wrapped: PackedStringArray=[]
		for line in supplied.split("\n"):
			while line.length()>24:
				wrapped.append(line.left(24))
				line=line.substr(24)
			wrapped.append(line)
		return "\n".join(wrapped)
	var targeting: String = {"CIRCLE":"攻击周围目标", "CONE":"攻击前方范围", "LINE":"攻击前方直线", "DIRECTION":"向前方发出攻击", "TARGET":"攻击选中目标", "SELF":"作用于自身", "POINT":"作用于指定位置"}.get(definition.get("targeting", ""), "")
	var parts: PackedStringArray = []
	if not targeting.is_empty(): parts.append(targeting)
	if definition.has("formula"):
		var formula: Dictionary = definition.formula
		var terms: PackedStringArray = []
		for stat in formula:
			if float(formula[stat]) <= 0: continue
			terms.append("%s%s" % [number(float(formula[stat])), {"weapon":"武器", "base":"基础"}.get(stat, STAT_NAMES.get(stat, stat))])
		if not terms.is_empty(): parts.append("伤害 " + " + ".join(terms))
	if parts.is_empty() and definition.has("modifiers"): parts.append(modifiers(definition.modifiers))
	return "\n".join(parts) if not parts.is_empty() else "效果依角色当前条件生效。"

static func build(actor: Node, display_name: String) -> Dictionary:
	var db: RefCounted = actor.loadout.database
	var race_id: String = actor.race_id
	var state := {"name":display_name, "race_id":race_id, "race":RACES.display_name(race_id), "level":int(actor.loadout.level), "career":"平民", "experience":int(actor.progression.experience),
		"next_level":int(actor.progression.to_next_level()), "max_level":int(actor.progression.max_level()), "resources":{}, "stats":{}, "items":[], "equipment":[], "skills":[], "careers":actor.progression.career_options()}
	if not actor.loadout.career_ids.is_empty():
		state.career = db.careers.get(actor.loadout.career_ids.back(), {}).get("name", "旅人")
	for id in RESOURCE_NAMES:
		state.resources[id] = {"current":actor.resources.current(id), "max":actor.resources.max_value(id), "unlimited":actor.resources.unlimited.get(id, false)}
	for id in STAT_NAMES: state.stats[id] = actor.stats.get_final_stat(id)
	for id in actor.inventory.item_ids():
		var definition: Dictionary = actor.inventory.definition(id)
		var category: String = definition.get("category", "")
		var stat := modifiers(definition.get("modifiers", {})) if category == "equipment" else ""
		if category == "weapon": stat = "武器强度 %s" % number(float(definition.get("weapon_scaling", 0)))
		state.items.append({"id":id, "name":definition.get("name", id), "kind":icon(definition), "type":{"weapon":"武器", "equipment":"护具", "consumable":"补给", "material":"素材"}.get(category, "物品"),
			"texture":db.get_content_icon({"weapon":"weapons", "equipment":"equipment"}.get(category, "items"), id),
			"category":category, "color":Color(definition.get("color", "#99cdb3")), "count":str(actor.inventory.count(id)), "note":description(definition), "stat":stat, "slot":definition.get("slot", "")})
	var host: Node = actor.arena.host
	if is_instance_valid(host) and host.get("economy") != null:
		state.items.append({"id":"coin", "name":"铜币", "kind":"coin", "type":"其他", "texture":db.get_content_icon("items", "coin"), "category":"currency", "color":Color("ca965d"), "count":str(host.economy.balance()), "note":"村镇通用的钱币。\n可用于购买物品、租住旅馆房间。", "stat":"与商店和旅馆共用的钱袋", "slot":""})
	for index in range(2):
		var weapon: Dictionary = actor.loadout.weapon_at(index)
		state.equipment.append({"id":weapon.get("id", ""), "name":weapon.get("name", "空武器槽"), "kind":icon(weapon), "slot":"武器 " + ["A", "B"][index], "key":str(index), "weapon":true,
			"texture":db.get_content_icon("weapons", str(weapon.get("id", ""))),
			"note":"选择行囊中已经持有的武器。", "stat":"武器强度 %s" % number(float(weapon.get("weapon_scaling", 0)))})
	for slot in actor.loadout.SLOTS:
		var id: String = actor.loadout.equipment.get(slot, "")
		var definition: Dictionary = db.equipment.get(id, {})
		state.equipment.append({"id":id, "name":definition.get("name", "空置"), "kind":icon(definition), "slot":SLOT_NAMES.get(slot, slot), "key":slot, "weapon":false,
			"texture":db.get_content_icon("equipment", id),
			"note":"选择行囊中已经持有的装备。", "stat":modifiers(definition.get("modifiers", {}))})
	for id in actor.loadout.available_skills:
		var skill: Dictionary = db.skills.get(id, {})
		var index: int = state.skills.size()
		var skill_type: String = ("戏法" if int(skill.spell_rank) == 0 else "%d 环法术" % int(skill.spell_rank)) if skill.has("spell_rank") else "主动招式"
		state.skills.append({"id":id, "name":skill.get("name", id), "kind":"sword" if skill.get("presentation_type", "") == "WEAPON_ACTION" else "crystal", "type":skill_type, "note":description(skill),
			"texture":db.get_content_icon("skills", id),
			"cost":costs(skill.get("costs", {})), "cooldown":"%s 秒" % number(float(skill.get("cooldown", 0))), "passive":false, "parent":-1, "pos":FIXTURES.SKILLS[index % 12].pos,
			"learned":id in actor.loadout.learned_skills, "reason":actor.progression.can_learn(id)})
	for id in actor.loadout.passive_ids:
		var passive: Dictionary = db.passives.get(id, {})
		var index: int = state.skills.size()
		var notes: Dictionary = TRAITS.notes(passive, db)
		var interval: float = float(passive.get("cooldown", 0))
		state.skills.append({"id":id, "name":passive.get("name", id), "kind":"leaf", "type":"职业特性 · 自动生效", "note":description({"description":notes.condition + "\n" + notes.effects}), "cost":"无需施放", "cooldown":"%s 秒" % number(interval) if interval > 0 else "无触发冷却",
			"texture":db.get_content_icon("passives", id),
			"passive":true, "parent":-1, "pos":FIXTURES.SKILLS[index % 12].pos, "learned":true, "reason":"职业特性自动生效"})
	state["traits"]=TRAITS.entries(actor)
	return state
