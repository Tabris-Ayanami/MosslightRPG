extends RefCounted
## Read-only chapter policy over existing quest facts. No new reward ledger,
## enemy life state, save mutation, scripts, or arbitrary expressions.
const PATH := "res://data/world/chapters.json"
const STATUSES := ["active", "ready", "rewarded"]
var last_error := ""
var _quests: RefCounted
var _definition: Dictionary = {}

func setup(quests: RefCounted, encounters: RefCounted, database: RefCounted, authored: Dictionary = {}) -> bool:
	var incoming: Dictionary = authored.duplicate(true)
	if incoming.is_empty():
		var parser := JSON.new()
		if parser.parse(FileAccess.get_file_as_string(PATH)) != OK or not parser.data is Dictionary:
			last_error = "章节目录不是有效 JSON 对象"
			return false
		incoming = parser.data
	last_error = _validate(incoming, quests, encounters, database)
	if not last_error.is_empty(): return false
	_quests = quests
	_definition = incoming.duplicate(true)
	return true

func definition() -> Dictionary: return _definition.duplicate(true)
func title() -> String: return "第一章 · " + str(_definition.get("title", ""))
func is_complete() -> bool:
	return _quests != null and _quests.status(str(_definition.get("completion_quest", ""))) == "rewarded"

func objective_complete(quest: String, id: String) -> bool:
	if _quests == null: return false
	for objective: Dictionary in _quests.objective_progress(quest):
		if objective.id == id: return objective.complete
	return false

func phase() -> String:
	if _quests == null: return "unavailable"
	if is_complete(): return "complete"
	var patrol: String = _quests.status("village_patrol")
	if patrol == "available": return "patrol_available"
	if patrol == "active": return "patrol_active"
	if patrol == "ready": return "patrol_report"
	var forest: String = _quests.status("forest_investigation")
	if forest == "available": return "investigation_available"
	if forest == "ready": return "final_report"
	if forest == "active":
		return "final_challenge" if objective_complete("forest_investigation", "break_guard") else "investigation_active"
	return "unavailable"

func encounter_enabled(id: String) -> bool:
	if _quests == null or not _definition.get("encounters", {}).has(id): return false
	var rule: Dictionary = _definition.encounters[id]
	if not rule.has("quest"): return true
	var quest: String = rule.quest
	if _quests.status(quest) not in rule.statuses: return false
	for objective: String in rule.get("complete_objectives", []):
		if not objective_complete(quest, objective): return false
	for objective: String in rule.get("incomplete_objectives", []):
		if objective_complete(quest, objective): return false
	return true

func encounter_profile(id: String) -> Dictionary:
	return _definition.get("encounters", {}).get(id, {}).get("profile", {}).duplicate(true)

func _validate(data: Dictionary, quests: RefCounted, encounters: RefCounted, database: RefCounted) -> String:
	if quests == null or encounters == null or database == null: return "章节依赖尚未就绪"
	if not _keys(data, ["version", "id", "title", "completion_quest", "encounters"]): return "章节字段无效"
	if data.version != 1 or not data.id is String or data.id != "chapter01" or not data.title is String or data.title.is_empty() or data.title.length() > 80: return "章节身份无效"
	if not data.completion_quest is String or quests.definition(data.completion_quest).is_empty(): return "章节完成任务不存在"
	if not data.encounters is Dictionary or data.encounters.size() != encounters.entries().size(): return "章节必须明确配置每个正式遭遇"
	for id in data.encounters:
		if not id is String or encounters.definition(id).is_empty(): return "章节引用未知遭遇"
		var rule: Variant = data.encounters[id]
		if not rule is Dictionary or not _keys(rule, [], ["quest", "statuses", "complete_objectives", "incomplete_objectives", "profile"]): return "遭遇章节条件字段无效"
		if rule.has("quest"):
			if not rule.quest is String or quests.definition(rule.quest).is_empty() or not rule.get("statuses") is Array or rule.statuses.is_empty(): return "遭遇任务条件无效"
			var seen: Dictionary = {}
			for status in rule.statuses:
				if status not in STATUSES or seen.has(status): return "遭遇任务状态无效"
				seen[status] = true
			var known: Dictionary = {}
			for objective: Dictionary in quests.definition(rule.quest).objectives: known[objective.id] = true
			var selected: Dictionary = {}
			for field: String in ["complete_objectives", "incomplete_objectives"]:
				if not rule.get(field, []) is Array: return "遭遇目标条件必须是列表"
				for objective in rule.get(field, []):
					if not objective is String or not known.has(objective) or selected.has(objective): return "遭遇目标未知、重复或互相矛盾"
					selected[objective] = true
		elif rule.has("statuses") or rule.has("complete_objectives") or rule.has("incomplete_objectives"):
			return "遭遇目标条件缺少任务"
		var profile: Variant = rule.get("profile", {})
		if not profile is Dictionary or not _keys(profile, [], ["level"]): return "章节敌人覆盖字段无效"
		if profile.has("level"):
			var value: Variant = profile.level
			if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floorf(float(value)) or value < 1 or value > int(database.progression.rules.max_level): return "章节敌人等级无效"
	return ""

func _keys(data: Dictionary, required: Array, optional: Array = []) -> bool:
	for key in required:
		if not data.has(key): return false
	for key in data:
		if key not in required and key not in optional: return false
	return true
