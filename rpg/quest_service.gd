extends RefCounted
## Game-owned quest rules. Dialogue and UI only invoke this public API.
## All durable progress belongs to the supplied adventure's WorldState.

signal changed

const DEFAULT_PATH := "res://data/world/quests.json"
const MAX_QUANTITY := 1000000
const MAX_TOTAL := 2147483647
const MAX_QUESTS := 128
const MAX_OBJECTIVES := 16
const TRACKED_QUEST_FLAG := "journal.tracked_quest"
const WorldState = preload("res://rpg/world_state.gd")
const MutationGuard = preload("res://rpg/mutation_guard.gd")

var last_error := ""
var errors: PackedStringArray = []
var _world: RefCounted
var _actor: Node
var _definitions: Dictionary = {}
var _busy := false

## Empty definitions loads the bundled catalog. A failed setup keeps the previous
## working binding intact; it never partially imports a catalog or changes state.
func setup(state: RefCounted, actor: Node, definitions: Dictionary = {}) -> bool:
	if _busy or MutationGuard.busy(_world) or MutationGuard.busy(state):
		return _setup_error("任务更新中")
	errors.clear()
	if not state is WorldState or not is_instance_valid(actor):
		return _setup_error("任务系统缺少世界状态或角色")
	for component in ["inventory", "progression", "loadout"]:
		if not is_instance_valid(actor.get(component)):
			return _setup_error("角色缺少组件：" + component)
	var incoming := definitions.duplicate(true)
	if incoming.is_empty():
		incoming = actor.inventory.database.world_catalog("quests")
	var reason := _validate_definitions(incoming, actor.inventory.database)
	if not reason.is_empty():
		return _setup_error(reason)
	reason = _validate_records(state.export_state(), incoming)
	if not reason.is_empty():
		return _setup_error(reason)
	_disconnect()
	_world = state
	_actor = actor
	_definitions = incoming
	_world.flag_changed.connect(_on_flag_changed)
	_world.object_changed.connect(_on_object_changed)
	_world.event_recorded.connect(_on_event_recorded)
	_actor.inventory.changed.connect(_on_changed)
	_actor.progression.changed.connect(_on_changed)
	_actor.loadout.changed.connect(_on_changed)
	last_error = ""
	return true

func definition(id: String) -> Dictionary:
	return _definitions.get(id, {}).duplicate(true)

## Repository restore keeps queries usable, but blocks mutations until all final
## refresh observers have returned. A reward transaction cannot be interrupted.
func begin_restore() -> bool:
	if _busy:
		last_error = "任务更新中"
		return false
	_busy = true
	return true

func end_restore() -> void:
	changed.emit()
	_busy = false
	last_error = ""

func dispose() -> void:
	if _busy or MutationGuard.busy(_world):
		return
	_disconnect()
	_world = null
	_actor = null
	_definitions.clear()

## Call before restoring actor data. Validates a detached snapshot without changing
## this service, the player, or live world; unknown quest IDs need an explicit migration.
func validate_state(world_snapshot: Dictionary) -> String:
	if _definitions.is_empty():
		return "任务目录尚未配置"
	return _validate_records(world_snapshot, _definitions)

## ready is derived live; inventory/flag objectives may become incomplete again.
func status(id: String) -> String:
	if not _definitions.has(id) or not _usable():
		return "unknown"
	var record: Dictionary = _world.get_object("quest." + id)
	if not _record_error(record, _definitions[id], _world).is_empty():
		return "invalid"
	if record.is_empty():
		return "available" if _prerequisite_error(_definitions[id]).is_empty() else "locked"
	if record.status == "rewarded":
		return "rewarded"
	for objective in objective_progress(id):
		if not objective.complete:
			return "active"
	return "ready"

func entries(include_locked := true) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in _definitions:
		var current := status(id)
		if not include_locked and current == "locked":
			continue
		var entry: Dictionary = definition(id)
		entry["status"] = current
		entry["objectives"] = objective_progress(id)
		result.append(entry)
	return result

func objective_progress(id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _definitions.has(id) or not _usable():
		return result
	var record: Dictionary = _world.get_object("quest." + id)
	if not _record_error(record, _definitions[id], _world).is_empty():
		return result
	var reserved: Dictionary = {}
	for objective in _definitions[id].objectives:
		var progress := 0
		if record.get("status", "") == "rewarded":
			progress = int(objective.target)
		elif not record.is_empty():
			match objective.type:
				"event":
					progress = maxi(0, _world.get_event_count(objective.event, objective.get("subject", "")) - int(record.get("baselines", {}).get(objective.id, 0)))
				"inventory":
					progress = _actor.inventory.count(objective.item)
					if objective.get("consume", false):
						progress = maxi(0, progress - _actor.inventory.equipped_count(objective.item) - int(reserved.get(objective.item, 0)))
						reserved[objective.item] = int(reserved.get(objective.item, 0)) + mini(progress, int(objective.target))
				"flag":
					progress = 1 if _world.get_flag(objective.flag) == objective.value else 0
		result.append({"id": objective.id, "label": objective.label, "current": mini(progress, int(objective.target)),
			"target": int(objective.target), "complete": progress >= int(objective.target)})
	return result

func can_accept(id: String) -> String:
	if _busy or MutationGuard.busy(_world):
		return "任务更新中"
	match status(id):
		"unknown": return "任务不存在或角色不可用"
		"invalid": return "任务存档格式无效"
		"locked": return _prerequisite_error(_definitions[id])
		"available": return ""
		_: return "已接受此任务"

func accept(id: String) -> bool:
	last_error = can_accept(id)
	if not last_error.is_empty():
		return false
	var baselines: Dictionary = {}
	for objective in _definitions[id].objectives:
		if objective.type == "event":
			baselines[objective.id] = 0 if objective.get("retroactive", false) else _world.get_event_count(objective.event, objective.get("subject", ""))
	var candidate: Dictionary = _world.export_state()
	candidate.objects["quest." + id] = {"status": "active", "baselines": baselines}
	var tracked: Variant = _world.get_flag(TRACKED_QUEST_FLAG, "")
	var track_accepted: bool = not (tracked is String and status(tracked) in ["active", "ready"])
	if track_accepted: candidate.flags[TRACKED_QUEST_FLAG] = id
	if not MutationGuard.acquire(_world, "quest.accept"):
		last_error = "冒险状态更新中"
		return false
	_busy = true
	# Publish only after the accepted record and any new tracking selection
	# have committed together; observers must never save half of this operation.
	var accepted: bool = _world.import_state(candidate)
	last_error = "" if accepted else "无法保存任务：" + _world.last_error
	if accepted:
		_world.object_changed.emit("quest." + id)
		if track_accepted: _world.flag_changed.emit(TRACKED_QUEST_FLAG, id)
		changed.emit()
	_busy = false
	MutationGuard.release(_world, "quest.accept")
	return accepted

func can_claim(id: String) -> String:
	return str(_claim_plan(id).get("error", ""))

## The synchronous commit has no signal/callback before all durable values have
## changed. Observers may save or refresh from any emitted signal and see the full
## reward transaction. Reentrant quest operations are rejected until it finishes.
func claim(id: String) -> bool:
	var plan := _claim_plan(id)
	last_error = plan.get("error", "")
	if not last_error.is_empty():
		return false
	if not MutationGuard.acquire(_world, "quest.claim"):
		last_error = "冒险状态更新中"
		return false
	_busy = true
	if not _world.import_state(plan.world):
		_busy = false
		MutationGuard.release(_world, "quest.claim")
		last_error = "无法保存任务：" + _world.last_error
		return false
	var previous_level: int = _actor.loadout.level
	_actor.inventory.stacks = plan.stacks
	_actor.progression.experience = int(plan.experience)
	_actor.loadout.level = int(plan.level)
	_actor.inventory.last_error = ""
	_actor.progression.last_error = ""
	# Match RPGProgression's XP rules, including clearing overflow at the cap.
	# Rebuild only after committing every value, so resource signals are safe too.
	if int(plan.level) != previous_level:
		_actor.loadout._rebuild(false)
		for reached in range(previous_level + 1, int(plan.level) + 1):
			_actor.progression.leveled_up.emit(reached)
	_actor.inventory.changed.emit()
	_actor.progression.changed.emit()
	_world.object_changed.emit("quest." + id)
	last_error = ""
	changed.emit()
	_busy = false
	MutationGuard.release(_world, "quest.claim")
	return true

func _claim_plan(id: String) -> Dictionary:
	if _busy or MutationGuard.busy(_world):
		return {"error": "任务更新中"}
	var current := status(id)
	if current != "ready":
		return {"error": "奖励已经领取" if current == "rewarded" else "任务目标尚未完成"}
	var quest: Dictionary = _definitions[id]
	var stacks: Dictionary = _actor.inventory.stacks.duplicate(true)
	var consumed: Dictionary = {}
	for objective in quest.objectives:
		if objective.type == "inventory" and objective.get("consume", false):
			consumed[objective.item] = int(consumed.get(objective.item, 0)) + int(objective.target)
	for item in consumed:
		if _actor.inventory.count(item) - _actor.inventory.equipped_count(item) < int(consumed[item]):
			return {"error": "交付物品不足，已装备的物品不能交付"}
		stacks[item] = int(stacks.get(item, 0)) - int(consumed[item])
		if int(stacks[item]) == 0:
			stacks.erase(item)
	for item in quest.rewards.get("items", {}):
		var amount: int = int(quest.rewards.items[item])
		if _actor.inventory.definition(item).is_empty() or int(stacks.get(item, 0)) > MAX_QUANTITY - amount:
			return {"error": "奖励物品无效或数量已达上限"}
		stacks[item] = int(stacks.get(item, 0)) + amount
	var xp: int = int(quest.rewards.get("experience", 0))
	var level: int = _actor.loadout.level
	var experience: int = _actor.progression.experience
	var ceiling: int = _actor.progression.max_level()
	if xp > 0 and level <= 0:
		return {"error": "请先选择基础职业，再领取任务经验"}
	if xp > 0 and level < ceiling:
		if experience > MAX_TOTAL - xp:
			return {"error": "经验值已达上限"}
		experience += xp
		while level < ceiling:
			var threshold: Variant = _actor.progression.database.progression.get("rules", {}).get("xp_to_next", {}).get(str(level), 100)
			if not _integer(threshold, 1, MAX_TOTAL):
				return {"error": "升级经验配置无效"}
			if experience < int(threshold):
				break
			experience -= int(threshold)
			level += 1
		if level >= ceiling:
			experience = 0
	var candidate: Dictionary = _world.export_state()
	candidate.objects["quest." + id].status = "rewarded"
	var reason: String = _world.validate_state(candidate)
	if not reason.is_empty():
		return {"error": "无法保存任务：" + reason}
	return {"world": candidate, "stacks": stacks, "experience": experience, "level": level}

func _prerequisite_error(quest: Dictionary) -> String:
	var prerequisites: Dictionary = quest.get("prerequisites", {})
	for previous in prerequisites.get("quests", []):
		if _world.get_object("quest." + previous).get("status", "") != "rewarded":
			return "请先完成并领取「%s」的奖励" % _definitions[previous].title
	for flag in prerequisites.get("flags", {}):
		if _world.get_flag(flag) != prerequisites.flags[flag]:
			return "尚未满足剧情条件"
	return ""

## Detached save validation: no actors, signals, grants or global Database.
static func validate_snapshot(world_snapshot: Dictionary, database: RefCounted) -> String:
	if not is_instance_valid(database): return "任务内容目录尚未就绪"
	var catalog: Dictionary = database.world_catalog("quests")
	var reason := _validate_definitions(catalog, database)
	return reason if not reason.is_empty() else _validate_records(world_snapshot, catalog)

static func _validate_definitions(catalog: Dictionary, database: RefCounted) -> String:
	if catalog.is_empty() or catalog.size() > MAX_QUESTS:
		return "任务目录为空或数量超限"
	for id in catalog:
		if not _valid_id(id, 96) or not catalog[id] is Dictionary:
			return "任务 ID 或结构无效"
		var quest: Dictionary = catalog[id]
		if not _keys(quest, ["id", "title", "description", "objectives", "rewards"], ["prerequisites"]):
			return id + "：任务字段缺失或未知"
		if quest.id != id or not _text(quest.title, 80) or not _text(quest.description, 2000):
			return id + "：名称、描述或 ID 无效"
		if not quest.objectives is Array or quest.objectives.is_empty() or quest.objectives.size() > MAX_OBJECTIVES:
			return id + "：目标列表无效"
		var objective_ids: Dictionary = {}
		for objective in quest.objectives:
			if not objective is Dictionary or not _keys(objective, ["id", "type", "label", "target"], ["event", "subject", "retroactive", "item", "consume", "flag", "value"]):
				return id + "：目标字段缺失或未知"
			if not _valid_id(objective.id, 96) or objective_ids.has(objective.id) or not _text(objective.label, 160) or not _integer(objective.target, 1, MAX_QUANTITY):
				return id + "：目标 ID、文本或数量无效"
			objective_ids[objective.id] = true
			match objective.type:
				"event":
					if not _keys(objective, ["id", "type", "label", "target", "event"], ["subject", "retroactive"]) or objective.event != "enemy_defeated":
						return id + "：不支持的事件类型"
					if not objective.get("subject", "") is String or (objective.get("subject", "") != "" and not database.enemies.has(objective.subject)) or not objective.get("retroactive", false) is bool:
						return id + "：敌人引用或追溯设置无效"
				"inventory":
					if not _keys(objective, ["id", "type", "label", "target", "item"], ["consume"]) or not _item_exists(database, objective.item) or not objective.get("consume", false) is bool:
						return id + "：物品目标无效"
				"flag":
					if not _keys(objective, ["id", "type", "label", "target", "flag", "value"], []) or not _valid_id(objective.flag, 128) or not _scalar(objective.value) or int(objective.target) != 1:
						return id + "：剧情标记目标无效"
				_: return id + "：未知目标类型"
		if not quest.rewards is Dictionary or not _keys(quest.rewards, [], ["items", "experience"]):
			return id + "：奖励字段无效"
		if not _integer(quest.rewards.get("experience", 0), 0, MAX_QUANTITY) or not quest.rewards.get("items", {}) is Dictionary or quest.rewards.get("items", {}).size() > 32:
			return id + "：奖励数量无效"
		for item in quest.rewards.get("items", {}):
			if not _item_exists(database, item) or not _integer(quest.rewards.items[item], 1, MAX_QUANTITY):
				return id + "：奖励物品引用或数量无效"
		var prereq: Variant = quest.get("prerequisites", {})
		if not prereq is Dictionary or not _keys(prereq, [], ["quests", "flags"]) or not prereq.get("quests", []) is Array or not prereq.get("flags", {}) is Dictionary:
			return id + "：前置条件结构无效"
		if prereq.get("quests", []).size() > MAX_QUESTS or prereq.get("flags", {}).size() > 32:
			return id + "：前置条件超限"
		for previous in prereq.get("quests", []):
			if not previous is String or not catalog.has(previous) or previous == id:
				return id + "：前置任务引用无效"
		for flag in prereq.get("flags", {}):
			if not _valid_id(flag, 128) or not _scalar(prereq.flags[flag]):
				return id + "：前置标记无效"
	var visited: Dictionary = {}
	for id in catalog:
		if _cycle(id, catalog, {}, visited):
			return id + "：前置任务存在循环"
	return ""

static func _record_error(record: Dictionary, quest: Dictionary, state: RefCounted) -> String:
	if record.is_empty():
		return ""
	if not _keys(record, ["status", "baselines"], []) or record.status not in ["active", "rewarded"] or not record.baselines is Dictionary:
		return "任务存档格式无效"
	var expected: Dictionary = {}
	for objective in quest.objectives:
		if objective.type == "event":
			expected[objective.id] = true
			if not _integer(record.baselines.get(objective.id, -1), 0, state.get_event_count(objective.event, objective.get("subject", ""))):
				return "任务事件起点无效"
			# Patrol was originally non-retroactive. Preserve the accepted baseline
			# of those existing adventures; only new acceptance starts at zero.
			var legacy_patrol: bool = quest.id == "village_patrol" and objective.id == "clear_soldiers" and objective.event == "enemy_defeated" and objective.get("subject", "") == "soldier"
			if objective.get("retroactive", false) and int(record.baselines[objective.id]) != 0 and not legacy_patrol:
				return "追溯目标的起点必须为零"
			if record.status == "rewarded" and state.get_event_count(objective.event, objective.get("subject", "")) - int(record.baselines[objective.id]) < int(objective.target):
				return "已领奖任务缺少完成事件"
	for id in record.baselines:
		if not expected.has(id):
			return "未知任务目标起点"
	return ""

static func _validate_records(snapshot: Dictionary, catalog: Dictionary) -> String:
	var candidate := WorldState.new()
	if not candidate.import_state(snapshot):
		return candidate.last_error
	for key in snapshot.objects:
		if key.begins_with("quest."):
			var id: String = key.trim_prefix("quest.")
			if not catalog.has(id):
				return "存档包含未知任务：" + id
			var record: Dictionary = candidate.get_object(key)
			if record.is_empty():
				return id + "：任务存档不能为空"
			var reason := _record_error(record, catalog[id], candidate)
			if not reason.is_empty():
				return id + "：" + reason
			for previous in catalog[id].get("prerequisites", {}).get("quests", []):
				if candidate.get_object("quest." + previous).get("status", "") != "rewarded":
					return id + "：任务存档缺少前置任务奖励记录"
	return ""

static func _cycle(id: String, catalog: Dictionary, visiting: Dictionary, visited: Dictionary) -> bool:
	if visiting.has(id):
		return true
	if visited.has(id):
		return false
	visiting[id] = true
	for previous in catalog[id].get("prerequisites", {}).get("quests", []):
		if _cycle(previous, catalog, visiting, visited):
			return true
	visiting.erase(id)
	visited[id] = true
	return false

static func _item_exists(database: RefCounted, id: Variant) -> bool:
	if not id is String: return false
	for catalog: Dictionary in [database.items, database.weapons, database.equipment]:
		if catalog.has(id): return catalog[id] is Dictionary and not catalog[id].is_empty()
	return false

static func _keys(value: Dictionary, required: Array, optional: Array) -> bool:
	for key in required:
		if not value.has(key): return false
	for key in value:
		if key not in required and key not in optional: return false
	return true

static func _valid_id(value: Variant, length: int) -> bool:
	if not value is String or value.is_empty() or value.length() > length:
		return false
	for index in range(value.length()):
		var code: int = value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code in [45, 46, 47, 58, 95]):
			return false
	return true

static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and value >= minimum and value <= maximum

static func _text(value: Variant, limit: int) -> bool:
	return value is String and not value.strip_edges().is_empty() and value.length() <= limit

static func _scalar(value: Variant) -> bool:
	return value is bool or (value is String and value.length() <= 256) or _integer(value, -MAX_TOTAL, MAX_TOTAL)

func _usable() -> bool:
	return is_instance_valid(_world) and is_instance_valid(_actor) and is_instance_valid(_actor.inventory) and is_instance_valid(_actor.progression) and is_instance_valid(_actor.loadout)

func _setup_error(reason: String) -> bool:
	last_error = reason
	errors.append(reason)
	return false

func _disconnect() -> void:
	if is_instance_valid(_world):
		if _world.flag_changed.is_connected(_on_flag_changed):
			_world.flag_changed.disconnect(_on_flag_changed)
		if _world.object_changed.is_connected(_on_object_changed):
			_world.object_changed.disconnect(_on_object_changed)
		if _world.event_recorded.is_connected(_on_event_recorded):
			_world.event_recorded.disconnect(_on_event_recorded)
	if is_instance_valid(_actor):
		for component in [_actor.inventory, _actor.progression, _actor.loadout]:
			if is_instance_valid(component) and component.changed.is_connected(_on_changed):
				component.changed.disconnect(_on_changed)

func _on_changed() -> void:
	if not _busy:
		changed.emit()

func _on_flag_changed(_id: String, _value: Variant) -> void:
	_on_changed()

func _on_object_changed(_id: String) -> void:
	_on_changed()

func _on_event_recorded(_event: Dictionary) -> void:
	_on_changed()
