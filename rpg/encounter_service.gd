extends RefCounted
## Pure plans for authored encounter slots. The runtime owns actors, active-play
## timing, spawn safety and the shared mutation guard; this service never commits.
const WorldState = preload("res://rpg/world_state.gd")
const PATH := "res://data/world/encounters.json"
const PREFIX := "encounter."
const VERSION := 1
const MAX_GENERATION := 2147483647
const MAX_ENCOUNTERS := 128
const MAX_RESPAWN_SECONDS := 86400.0

var last_error := ""
var _world: RefCounted
var _definitions: Dictionary = {}

func setup(world: RefCounted, database: RefCounted, definitions: Dictionary = {}) -> bool:
	if not world is WorldState: return _fail("遭遇缺少冒险世界状态")
	var catalog: Dictionary = _read_catalog() if definitions.is_empty() else {"version": VERSION, "encounters": definitions}
	var reason := _validate_catalog(catalog, database)
	if reason.is_empty(): reason = _validate_records(world.export_state(), catalog.encounters)
	if not reason.is_empty(): return _fail(reason)
	_world = world
	_definitions = catalog.encounters.duplicate(true)
	last_error = ""
	return true

func definition(id: String) -> Dictionary:
	if not _definitions.has(id):
		_fail("遭遇不存在：" + id)
		return {}
	last_error = ""
	return _definitions[id].duplicate(true)

func entries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _usable(): return result
	var snapshot: Dictionary = _world.export_state()
	var reason := validate_state(snapshot)
	if not reason.is_empty():
		_fail(reason)
		return result
	var ids := _definitions.keys()
	ids.sort()
	for id: String in ids:
		var entry: Dictionary = _definitions[id].duplicate(true)
		entry.record = _record(id, snapshot)
		result.append(entry)
	last_error = ""
	return result

## Missing records in old saves mean the original living generation. Reading a
## default does not materialize records or emit a spawn/reward event.
func record(id: String, snapshot: Dictionary = {}) -> Dictionary:
	if not _usable() or not _definitions.has(id):
		_fail("遭遇不存在或尚未配置：" + id)
		return {}
	var source: Dictionary = _world.export_state() if snapshot.is_empty() else snapshot
	var reason := validate_state(source)
	if not reason.is_empty():
		_fail(reason)
		return {}
	last_error = ""
	return _record(id, source)

func validate_state(snapshot: Dictionary) -> String:
	if _definitions.is_empty(): return "遭遇目录尚未配置"
	return _validate_records(snapshot, _definitions)

static func validate_snapshot(world_snapshot: Dictionary, database: RefCounted) -> String:
	var catalog := _read_catalog()
	var reason := _validate_catalog(catalog, database)
	return reason if not reason.is_empty() else _validate_records(world_snapshot, catalog.encounters)

## The caller can add reward/event changes to the same candidate before or after
## this plan. Every output is detached; neither input nor the live state changes.
func plan_defeat(id: String, generation: int, candidate_world: Dictionary) -> Dictionary:
	if not _usable() or not _definitions.has(id): return _failure("遭遇不存在或尚未配置：" + id)
	var reason := validate_state(candidate_world)
	if not reason.is_empty(): return _failure(reason)
	var current := _record(id, candidate_world)
	if generation != current.generation or current.phase not in ["alive", "pending"]: return _failure("遭遇生命已结束或代次已改变")
	var seconds: float = float(_definitions[id].respawn_seconds)
	var candidate := candidate_world.duplicate(true)
	candidate.objects[id] = {"version": VERSION, "generation": generation,
		"phase": "cooldown" if seconds > 0.0 else "cleared", "remaining": seconds}
	reason = validate_state(candidate)
	if not reason.is_empty(): return _failure(reason)
	last_error = ""
	return {"ok": true, "error": "", "world": candidate}

## Capacity failures defer the complete reward/event transaction. A pending life
## stays defeated across reloads, never respawns, and can be settled exactly once.
func plan_pending(id: String, generation: int, candidate_world: Dictionary) -> Dictionary:
	if not _usable() or not _definitions.has(id): return _failure("遭遇不存在或尚未配置：" + id)
	var reason := validate_state(candidate_world)
	if not reason.is_empty(): return _failure(reason)
	var current := _record(id, candidate_world)
	if generation != current.generation or current.phase != "alive": return _failure("遭遇生命已结束或代次已改变")
	var candidate := candidate_world.duplicate(true)
	candidate.objects[id] = {"version": VERSION, "generation": generation, "phase": "pending", "remaining": 0.0}
	reason = validate_state(candidate)
	if not reason.is_empty(): return _failure(reason)
	last_error = ""
	return {"ok": true, "error": "", "world": candidate}

## Compatibility query for old callers. Elapsed time never revives enemies.
func plan_tick(delta: float, safe_to_spawn: Array[String]) -> Dictionary:
	if not _usable(): return _failure("遭遇尚未配置")
	if not is_finite(delta) or delta < 0.0: return _failure("遭遇计时必须是有限的非负时间")
	for id: String in safe_to_spawn:
		if not _definitions.has(id): return _failure("刷新安全名单包含未知遭遇：" + id)
	var candidate: Dictionary = _world.export_state()
	var reason := validate_state(candidate)
	if not reason.is_empty(): return _failure(reason)
	var spawn_ids: Array[String] = []
	last_error = ""
	return {"ok": true, "error": "", "world": candidate, "spawn_ids": spawn_ids}

func plan_short_rest(candidate_world: Dictionary) -> Dictionary:
	if not _usable(): return _failure("遭遇尚未配置")
	var reason := validate_state(candidate_world)
	if not reason.is_empty(): return _failure(reason)
	var candidate := candidate_world.duplicate(true)
	var spawn_ids: Array[String] = []
	for id: String in _definitions:
		var current := _record(id,candidate)
		if current.phase != "cooldown": continue
		if current.generation >= MAX_GENERATION: return _failure("遭遇生命代次已达上限")
		current.generation += 1
		current.phase = "alive"
		current.remaining = 0.0
		candidate.objects[id] = current
		spawn_ids.append(id)
	return {"ok":true,"error":"","world":candidate,"spawn_ids":spawn_ids}

func _record(id: String, snapshot: Dictionary) -> Dictionary:
	var current: Dictionary = snapshot.objects.get(id, {"version": VERSION, "generation": 1, "phase": "alive", "remaining": 0.0}).duplicate(true)
	current.version = int(current.version)
	current.generation = int(current.generation)
	current.remaining = float(current.remaining)
	return current

func _usable() -> bool:
	if _world == null or _definitions.is_empty(): return _fail("遭遇尚未配置")
	return true

func _fail(reason: String) -> bool:
	last_error = reason
	return false

func _failure(reason: String) -> Dictionary:
	last_error = reason
	return {"ok": false, "error": reason, "world": {}, "spawn_ids": []}

static func _read_catalog() -> Dictionary:
	if not FileAccess.file_exists(PATH): return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(PATH)) != OK or not parser.data is Dictionary: return {}
	return parser.data

static func _validate_catalog(catalog: Dictionary, database: RefCounted) -> String:
	if not _keys(catalog, ["version", "encounters"]) or not _integer(catalog.version, VERSION, VERSION): return "遭遇目录版本或字段无效"
	if not catalog.encounters is Dictionary or catalog.encounters.is_empty() or catalog.encounters.size() > MAX_ENCOUNTERS: return "遭遇目录数量无效"
	if database == null or not database.get("enemies") is Dictionary: return "敌人目录尚未就绪"
	for id in catalog.encounters:
		if not id is String or not id.begins_with(PREFIX) or id.length() <= PREFIX.length() or not WorldState.new()._valid_id(id): return "遭遇 ID 无效"
		var data: Variant = catalog.encounters[id]
		if not data is Dictionary or not _keys(data, ["id", "enemy_id", "position", "respawn_seconds", "safe_distance"], ["arrival_points"]): return "遭遇定义字段无效：" + id
		if data.id != id or not data.enemy_id is String or not database.enemies.has(data.enemy_id): return "遭遇身份或敌人模板无效：" + id
		if not _vector(data.position) or not _number(data.respawn_seconds, 0.0, MAX_RESPAWN_SECONDS) or not _number(data.safe_distance, 0.0, 1000.0): return "遭遇位置、冷却或安全距离无效：" + id
		var arrivals: Variant = data.get("arrival_points", [])
		if not arrivals is Array or arrivals.size() > 8: return "遭遇入场点必须是最多八个位置：" + id
		var seen: Array[Vector3] = [Vector3(data.position[0], data.position[1], data.position[2])]
		for point in arrivals:
			if not _vector(point): return "遭遇入场点无效或重复：" + id
			var position := Vector3(point[0], point[1], point[2])
			if position in seen: return "遭遇入场点无效或重复：" + id
			seen.append(position)
	return ""

static func _validate_records(snapshot: Dictionary, definitions: Dictionary) -> String:
	var reason: String = WorldState.new().validate_state(snapshot)
	if not reason.is_empty(): return reason
	for id: String in snapshot.objects:
		if not id.begins_with(PREFIX): continue
		if not definitions.has(id): return "未知遭遇记录：" + id
		var current: Dictionary = snapshot.objects[id]
		if not _keys(current, ["version", "generation", "phase", "remaining"]) or not _integer(current.version, VERSION, VERSION) or not _integer(current.generation, 1, MAX_GENERATION): return "遭遇记录版本、字段或代次无效：" + id
		var seconds: float = float(definitions[id].respawn_seconds)
		if current.phase not in ["alive", "pending", "cooldown", "cleared"] or not _number(current.remaining, 0.0, seconds): return "遭遇状态或剩余时间无效：" + id
		if current.phase in ["alive", "pending", "cleared"] and current.remaining != 0: return "非冷却遭遇不能包含剩余时间：" + id
		if (current.phase == "cooldown" and seconds <= 0.0) or (current.phase == "cleared" and seconds > 0.0): return "遭遇记录与重生策略不匹配：" + id
	return ""

static func _keys(data: Dictionary, keys: Array, optional: Array = []) -> bool:
	for key in keys:
		if not data.has(key): return false
	for key in data:
		if key not in keys and key not in optional: return false
	return true

static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return _number(value, minimum, maximum) and float(value) == floorf(float(value))

static func _number(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= minimum and value <= maximum

static func _vector(value: Variant) -> bool:
	if not value is Array or value.size() != 3: return false
	for part in value:
		if not _number(part, -10000.0, 10000.0): return false
	return true
