extends RefCounted
## Identity values for this game's setting. IDs are stable save keys;
## labels may change independently. Race currently grants no implicit modifiers.
const DEFAULT_ID := "human"
const IDS := ["human", "elf", "orc", "dwarf", "dragonborn", "dead_apostle", "angel", "demon", "devil", "elemental", "construct", "giant"]
const NAMES := {
	"human": "人类",
	"elf": "精灵",
	"orc": "兽人",
	"dwarf": "矮人",
	"dragonborn": "龙裔",
	"dead_apostle": "死徒",
	"angel": "天使",
	"demon": "恶魔",
	"devil": "魔鬼",
	"elemental": "元素生命",
	"construct": "构装体",
	"giant": "巨人",
}

static func is_valid(value: Variant) -> bool:
	return value is String and NAMES.has(value)

static func display_name(id: String) -> String:
	return str(NAMES.get(id, "未知种族"))

static func options() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in IDS:
		result.append({"id": id, "name": display_name(id)})
	return result
