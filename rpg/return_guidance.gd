extends RefCounted
## Read-only advice: opening the memo never changes an adventure or its tracking.
const KEYS = preload("res://scripts/frontend/journal_bindings.gd")
const DEATH_NOTICE := "即将返回记录点 · 等级与物品保留"

static func describe(actor: Node) -> Dictionary:
	var inventory: Node = actor.inventory
	var supply := "当前没有生命补给。可过水庭北桥，到风铃村找补给商人诺安购买；药水需要铜币，商人的库存有限。"
	var short := "已满血重生 · 缺药可用记录石恢复"
	for id in inventory.item_ids():
		if _healing_item(inventory, id):
			supply = "持有%s ×%d。打开背包的「补给」，选中药水后点「放入快捷槽」，再选择一个槽位；受伤时也可在背包点「使用」。" % [inventory.definition(id).name, inventory.count(id)]
			short = "已满血重生 · 药水可在背包配置快捷槽"
			break
	for index in range(mini(inventory.quickslots.size(), KEYS.QUICK_ACTIONS.size())):
		var id: String = inventory.quickslots[index]
		if not _healing_item(inventory, id): continue
		var key: String = KEYS.action_label(KEYS.QUICK_ACTIONS[index], "快捷 %d" % (index + 1))
		supply = "下次受伤时，按 %s 使用快捷槽 %d 的%s（剩余 %d）。生命已满或药水冷却时不会消耗；也可打开背包的「补给」调整快捷槽。" % [key, index + 1, inventory.definition(id).name, inventory.count(id)]
		short = "已满血重生 · 受伤按 %s 用药" % key
		break
	return {
		"respawn_notice": short + " · 详见日志备忘",
		"sections": [
			{"title": "重新出发", "body": "倒下后会返回最近的记录点，并恢复全部状态。等级、经验、物品和任务进度都会保留，不必额外休憩才能再出发。"},
			{"title": "随身补给", "body": supply},
			{"title": "补给与记录", "body": "诺安也收购闲置武器与护具，可换铜币购买药水；已装备的物品不能出售。之后受伤或耗尽体力、能量时，可回水庭，在苔光记录石旁按 %s 选择「休憩 · 记录」，免费恢复状态并设置重生点。这里不会补发药水；缺铜币或商人售罄时，仍可使用记录石。" % KEYS.action_label(&"interact", "交互键")},
		],
	}

static func _healing_item(inventory: Node, id: String) -> bool:
	if id.is_empty() or inventory.count(id) <= 0: return false
	var item: Dictionary = inventory.definition(id)
	return item.get("category", "") == "consumable" and item.get("effect", "") == "resource" and item.get("resource", "HP") == "HP" and (float(item.get("amount", 0)) > 0 or float(item.get("fraction", 0)) > 0)
