extends Node
class_name RPGInventory

const InteractionReadiness = preload("res://rpg/interaction_readiness.gd")

signal changed
signal item_used(id: String)

var actor: Node
var database: RefCounted
## Counts include equipped copies. Equipping never consumes ownership.
var stacks: Dictionary = {}
var quickslots: Array[String] = ["", "", "", ""]
var cooldowns: Dictionary = {}
var last_error := ""

func setup(owner_actor: Node, data: RefCounted) -> void:
	actor = owner_actor
	database = data

func definition(id: String) -> Dictionary:
	var value: Dictionary = {}
	var category := ""
	if database.items.has(id):
		value = database.items[id]
		category = str(value.get("category", "consumable"))
	elif database.weapons.has(id):
		value = database.weapons[id]
		category = "weapon"
	elif database.equipment.has(id):
		value = database.equipment[id]
		category = "equipment"
	var result := value.duplicate(true)
	if not result.is_empty():
		result["category"] = category
	return result

func item_ids() -> Array[String]:
	var result: Array[String] = []
	for id in stacks:
		if count(id) > 0:
			result.append(id)
	result.sort()
	return result

func count(id: String) -> int:
	return int(stacks.get(id, 0))

func equipped_count(id: String) -> int:
	var result := 0
	for group in actor.loadout.sets:
		if group.get("weapon", "") == id:
			result += 1
	for equipped in actor.loadout.equipment.values():
		if equipped == id:
			result += 1
	return result

func add_item(id: String, amount := 1) -> bool:
	if amount <= 0 or definition(id).is_empty():
		last_error = "物品或数量无效"
		return false
	stacks[id] = count(id) + amount
	last_error = ""
	changed.emit()
	return true

func can_discard(id: String) -> String:
	var data: Dictionary=definition(id)
	if data.get("category","") in ["quest","quest_item"] or not data.get("discardable",true): return "这件物品需要妥善保管"
	if count(id)<=equipped_count(id): return "没有可丢弃的未装备物品"
	return ""

func discard_item(id: String) -> bool:
	last_error=can_discard(id)
	if not last_error.is_empty(): return false
	return remove_item(id,1)

func remove_item(id: String, amount := 1) -> bool:
	if amount <= 0 or count(id) - amount < equipped_count(id):
		last_error = "数量不足，或物品正在装备"
		return false
	stacks[id] = count(id) - amount
	if int(stacks[id]) == 0:
		stacks.erase(id)
	last_error = ""
	changed.emit()
	return true

func assign_quick_slot(index: int, id: String) -> bool:
	if index < 0 or index >= 4:
		last_error = "快捷栏无效"
		return false
	if not id.is_empty() and (not database.items.has(id) or definition(id).get("category") != "consumable" or count(id) <= 0):
		last_error = "只能配置已持有的消耗品"
		return false
	quickslots[index] = id
	last_error = ""
	changed.emit()
	return true

func can_use(id: String) -> String:
	if not database.items.has(id) or definition(id).get("category") != "consumable":
		return "此物品不能使用"
	if count(id) <= 0:
		return "物品数量不足"
	var item: Dictionary = database.items[id]
	# Action items still need permission to enter the actual combat runner. Only
	# immediate supplies use menu readiness while the world's input is paused.
	var ready: bool = actor.combat.can_start() if item.get("effect", "") == "action" else InteractionReadiness.can_manage(actor)
	if actor.resources.current("HP") <= 0.0 or not ready:
		return "当前状态不能使用物品"
	if float(cooldowns.get(id, 0.0)) > 0.0:
		return "物品冷却中"
	match str(item.get("effect", "")):
		"resource":
			var resource: String = item.get("resource", "HP")
			if actor.resources.max_value(resource) <= 0.0:
				return "当前职业没有此资源"
			if actor.resources.current(resource) >= actor.resources.max_value(resource):
				return "资源已满"
		"level":
			return actor.progression.can_level_up()
		"action":
			return actor.combat.action_failure(item.get("action", {}))
		_:
			return "未知物品效果"
	return ""

func use_item(id: String) -> bool:
	last_error = can_use(id)
	if not last_error.is_empty():
		return false
	var item: Dictionary = database.items[id]
	match str(item.get("effect", "")):
		"resource":
			var resource: String = item.get("resource", "HP")
			var amount: float = float(item.get("amount", 0)) + actor.resources.max_value(resource) * float(item.get("fraction", 0))
			actor.resources.change(resource, amount)
		"level":
			if not actor.progression.level_up():
				last_error = actor.progression.last_error
				return false
		"action":
			if not actor.combat.use_action(item.get("action", {})):
				last_error = actor.combat.last_condition_failed
				return false
	# All validation and effect execution succeeded before consuming the stack.
	stacks[id] = count(id) - 1
	if int(stacks[id]) <= 0:
		stacks.erase(id)
	var cooldown := maxf(0.0, float(item.get("cooldown", 0)))
	if cooldown > 0.0:
		cooldowns[id] = cooldown
	changed.emit()
	item_used.emit(id)
	return true

func use_quick_slot(index: int) -> bool:
	if index < 0 or index >= 4:
		last_error = "快捷栏无效"
		return false
	return use_item(quickslots[index])

func tick(delta: float) -> void:
	var expired := false
	for id in cooldowns.keys():
		cooldowns[id] = maxf(0.0, float(cooldowns[id]) - maxf(0.0, delta))
		if float(cooldowns[id]) <= 0.0:
			cooldowns.erase(id)
			expired = true
	if expired:
		changed.emit()

func export_state() -> Dictionary:
	return {"stacks": stacks.duplicate(true), "quickslots": quickslots.duplicate(), "cooldowns": cooldowns.duplicate(true)}

func import_state(state: Dictionary) -> void:
	stacks.clear()
	for id in state.get("stacks", {}):
		if not definition(id).is_empty() and int(state.stacks[id]) > 0:
			stacks[id] = int(state.stacks[id])
	quickslots = ["", "", "", ""]
	var saved: Array = state.get("quickslots", [])
	for index in range(mini(4, saved.size())):
		if database.items.has(str(saved[index])) and definition(str(saved[index])).get("category") == "consumable":
			quickslots[index] = str(saved[index])
	cooldowns.clear()
	for id in state.get("cooldowns", {}):
		if database.items.has(id) and float(state.cooldowns[id]) > 0.0:
			cooldowns[id] = float(state.cooldowns[id])
	last_error = ""
	changed.emit()
