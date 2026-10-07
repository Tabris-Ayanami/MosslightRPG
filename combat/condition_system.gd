extends RefCounted
class_name CombatConditions
## Conditions are shared by equipment, actions, passives and status effects.
## Every check reads a snapshot; evaluating a condition never mutates an actor.

const ELEMENTS := ["FIRE", "ICE", "LIGHTNING", "EARTH", "WIND"]
const LABELS := {
	"weapon_family": "武器动画家族", "weapon_type": "武器类型",
	"stat": "属性", "attribute": "属性", "self_hp": "自身生命比例",
	"target_hp": "目标生命比例", "behind": "位于目标背后", "behind_target": "位于目标背后",
	"combat_state": "战斗状态", "self_status": "自身状态", "target_status": "目标状态",
	"career": "职业", "resource": "资源", "proficiency": "武器熟练",
	"first_hit": "本场战斗首次伤害", "first_damage": "本场战斗首次伤害",
	"distance": "目标距离", "elemental": "元素伤害", "level": "等级",
	"presentation_type": "技能表现类型", "spell": "法术", "critical": "暴击",
	"crit": "暴击", "area": "范围技能", "event": "触发事件", "damage_type": "伤害类型",
	"race": "种族", "race_id": "种族", "faction": "阵营", "faction_id": "阵营",
	"definition_id": "单位定义", "target_race": "目标种族", "target_race_id": "目标种族",
	"target_faction": "目标阵营", "target_faction_id": "目标阵营",
	"target_level_at_most_self": "目标等级不高于自身"
}

static func check_all(conditions: Array, context: Dictionary) -> String:
	for entry in conditions:
		if not entry is Dictionary:
			return "条件数据无效"
		if not check(entry, context):
			return failure_reason(entry)
	return ""

static func check(condition: Dictionary, context: Dictionary) -> bool:
	var kind := str(condition.get("type", "")).to_lower()
	var expected: Variant = condition.get("value", true)
	var op := str(condition.get("op", "in" if expected is Array else "=="))
	match kind:
		"target_level_at_most_self":
			return bool(context.get("has_target", context.has("target_level"))) and context.has("level") and context.has("target_level") and float(context.target_level) <= float(context.level)
		"race", "race_id", "faction", "faction_id", "definition_id", "target_race", "target_race_id", "target_faction", "target_faction_id":
			if kind.begins_with("target_") and context.has("has_target") and not bool(context.has_target):
				return false
			var key: String = {"race": "race_id", "faction": "faction_id", "target_race_id": "target_race", "target_faction_id": "target_faction"}.get(kind, kind)
			return (context.has(key) or context.has(kind)) and _compare(context.get(key, context.get(kind)), expected, op)
		"weapon_family", "weapon_type", "presentation_type", "event", "damage_type":
			return context.has(kind) and _compare(context[kind], expected, op)
		"attribute", "stat":
			var stat := str(condition.get("stat", ""))
			var stats: Dictionary = context.get("stats", context)
			return stats.has(stat) and _compare(stats[stat], expected, str(condition.get("op", ">=")))
		"self_hp", "target_hp":
			if kind == "target_hp" and context.has("has_target") and not bool(context.has_target):
				return false
			var key := "hp_ratio" if kind == "self_hp" else "target_hp_ratio"
			return context.has(key) and _compare(context[key], expected, op)
		"behind", "behind_target":
			return _compare(bool(context.get("behind", false)), expected, op)
		"combat_state":
			if expected is bool:
				return context.has("in_combat") and _compare(context.in_combat, expected, op)
			if str(expected).to_upper() in ["IN_COMBAT", "OUT_OF_COMBAT"]:
				return context.has("in_combat") and _compare(bool(context.in_combat), str(expected).to_upper() == "IN_COMBAT", op)
			return context.has("state") and _compare(context.state, expected, op)
		"self_status", "target_status":
			var key := "statuses" if kind == "self_status" else "target_statuses"
			var statuses: Array = context.get(key, [])
			var status: Variant = condition.get("status", expected)
			if condition.has("status") and expected is bool:
				return _compare(statuses.has(status), expected, op)
			return _compare(statuses, status, op)
		"career":
			return _compare(context.get("careers", []), expected, op)
		"resource":
			var resource := str(condition.get("resource", ""))
			var resources: Dictionary = context.get("resources", {})
			return resources.has(resource) and _compare(resources[resource], expected, str(condition.get("op", ">=")))
		"proficiency":
			return _compare(context.get("proficiencies", []), expected, op)
		"first_hit", "first_damage":
			return _compare(bool(context.get("first_hit", context.get("first_damage", false))), expected, op)
		"distance", "level":
			return context.has(kind) and _compare(context[kind], expected, str(condition.get("op", ">=")))
		"elemental":
			return _compare(str(context.get("damage_type", "")).to_upper() in ELEMENTS, expected, op)
		"spell":
			return _compare(bool(context.get("spell", context.get("presentation_type", "") == "CASTER_ACTION")), expected, op)
		"critical", "crit":
			return _compare(bool(context.get("crit", context.get("critical", false))), expected, op)
		"area":
			return _compare(bool(context.get("area", false)), expected, op)
	return false

static func failure_reason(condition: Dictionary) -> String:
	var kind := str(condition.get("type", "")).to_lower()
	if kind == "weapon_family":
		var names := {"UNARMED":"徒手", "SINGLE_BLADE":"单手刀剑", "TWO_HANDED":"双手大剑", "HEAVY_2H":"巨斧等重武器", "POLEARM":"长枪", "BOW":"弓", "CROSSBOW":"弩", "STAFF_OR_ORB":"法杖或法球", "CASTER":"施法武器"}
		var values: Array = condition.value if condition.get("value") is Array else [condition.get("value", "")]
		var labels: PackedStringArray = []
		for value in values: labels.append(names.get(str(value), "对应武器"))
		return "请切换至%s再施放" % " / ".join(labels)
	if not LABELS.has(kind):
		return "未知条件：%s" % (kind if not kind.is_empty() else "未指定类型")
	var expected: Variant = condition.get("value", true)
	var detail := str(condition.get("stat", condition.get("resource", condition.get("status", ""))))
	var op := str(condition.get("op", "需要"))
	if kind in ["self_hp", "target_hp"] and (expected is float or expected is int):
		expected = str(snappedf(float(expected) * 100.0, 0.01)) + "%"
	return "%s%s %s %s" % [LABELS[kind], "（%s）" % detail if not detail.is_empty() else "", op, str(expected)]

static func _compare(actual: Variant, expected: Variant, op: String) -> bool:
	match op:
		"in", "not_in":
			if not expected is Array:
				return false
			var found := false
			if actual is Array:
				for item in actual:
					if expected.has(item):
						found = true
			else:
				found = expected.has(actual)
			return found if op == "in" else not found
		"==", "=", "eq", "!=", "ne", "contains":
			var equal: bool = actual.has(expected) if actual is Array else actual == expected
			return not equal if op in ["!=", "ne"] else equal
		">", ">=", "<", "<=":
			if not (actual is float or actual is int) or not (expected is float or expected is int):
				return false
			match op:
				">": return float(actual) > float(expected)
				">=": return float(actual) >= float(expected)
				"<": return float(actual) < float(expected)
				"<=": return float(actual) <= float(expected)
	return false
