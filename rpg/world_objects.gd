extends RefCounted
## One adventure owns its authored props. Persist facts, never scene node paths.
const WorldState = preload("res://rpg/world_state.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const Readiness = preload("res://rpg/interaction_readiness.gd")
const Prop = preload("res://scripts/interactable.gd")
const PATH := "res://data/world/objects.json"
const MAX_QUANTITY := 1000000
const OWNER := "world_objects"
var last_error := ""
var _game: Node
var _actor: Node
var _world: RefCounted
var _definitions: Dictionary = {}
var _nodes: Array[Node3D] = []

func setup(game: Node) -> bool:
	if _world != null and Guard.busy(_world): return _fail("世界物体正在更新")
	if not is_instance_valid(game) or not game.get("world_state") is WorldState or not is_instance_valid(game.get("player")):
		return _fail("世界物体缺少冒险或角色")
	if Guard.busy(game.world_state): return _fail("冒险正在更新，请稍后配置世界物体")
	var actor: Node = game.player
	if not is_instance_valid(actor.get("inventory")): return _fail("角色背包尚未就绪")
	var catalog := _read_catalog()
	var reason := _validate_catalog(catalog, actor.inventory.database)
	if reason.is_empty(): reason = _validate_records(game.world_state.export_state(), catalog.objects)
	if not reason.is_empty(): return _fail(reason)
	dispose()
	_game = game
	_actor = actor
	_world = game.world_state
	_definitions = catalog.objects.duplicate(true)
	_world.object_changed.connect(_object_changed)
	last_error = ""
	return true

func populate() -> Array[Node3D]:
	if not _usable(): return []
	if Guard.busy(_world):
		_fail("冒险正在更新，请稍后创建世界物体")
		return []
	# Repeated integration calls cannot duplicate collisions or rewards.
	if not _nodes.is_empty(): return _nodes.duplicate()
	for id: String in _definitions:
		var prop := Prop.new()
		prop.name = id.trim_prefix("prop.")
		prop.configure(self, _definitions[id])
		_game.world.add_child(prop)
		prop.global_position = _position(_definitions[id].position)
		prop.rotation.y = float(_definitions[id].rotation_y)
		_nodes.append(prop)
	refresh()
	return _nodes.duplicate()

func refresh() -> void:
	if not _usable(): return
	for prop in _nodes:
		if is_instance_valid(prop): prop.apply_persistent_state(_world.get_object(prop.persistent_id))

func validate_state(snapshot: Dictionary) -> String:
	if _definitions.is_empty(): return "世界物体目录尚未配置"
	return _validate_records(snapshot, _definitions)

static func validate_snapshot(world_snapshot: Dictionary, database: RefCounted) -> String:
	var catalog := _read_catalog()
	var reason := _validate_catalog(catalog, database)
	return reason if not reason.is_empty() else _validate_records(world_snapshot, catalog.objects)

func dispose() -> void:
	if _world != null and Guard.busy(_world):
		_fail("冒险正在更新，暂不能释放世界物体")
		return
	if _world != null and _world.object_changed.is_connected(_object_changed): _world.object_changed.disconnect(_object_changed)
	for prop in _nodes:
		if is_instance_valid(prop):
			prop.unbind()
			prop.queue_free()
	_nodes.clear()
	_definitions.clear()
	_world = null
	_actor = null
	_game = null

func interact(prop: Node3D) -> bool:
	last_error = _interaction_error(prop)
	if not last_error.is_empty(): return false
	var id: String = prop.persistent_id
	var data: Dictionary = _definitions[id]
	var record: Dictionary = _world.get_object(id)
	if data.kind == "chest" and record.get("opened", false): return _fail("箱中已空 · 物品已收入背包")
	var candidate: Dictionary = _world.export_state()
	var field := "opened" if data.kind == "chest" else "activated"
	candidate.objects[id] = {"version": 1, "kind": data.kind, field: true}
	var reason: String = _world.validate_state(candidate)
	if not reason.is_empty(): return _fail("无法记录物体状态：" + reason)
	# Prepare every change before acquiring/committing; the plan emits no signals.
	var stacks: Dictionary = _actor.inventory.stacks.duplicate(true)
	if data.kind == "chest":
		for item: String in data.items:
			var quantity: int = int(data.items[item])
			var owned: Variant = stacks.get(item, 0)
			if _actor.inventory.definition(item).is_empty() or not _integer(owned, 0, MAX_QUANTITY - quantity):
				return _fail("奖励物品无效或数量已达上限")
			stacks[item] = int(owned) + quantity
	if not Guard.acquire(_world, OWNER): return _fail("冒险正在更新，请稍后交互")
	if not _world.import_state(candidate):
		Guard.release(_world, OWNER)
		return _fail("无法记录物体状态：" + _world.last_error)
	if data.kind == "chest":
		_actor.inventory.stacks = stacks
		_actor.inventory.last_error = ""
	else:
		# Combat.reset restores resources and clears action/status state. Block its
		# callbacks until checkpoint and persistent activation are also committed.
		var blocked := _block_actor_signals()
		_game.checkpoint = _position(data.checkpoint)
		_actor.spawn_point = _game.checkpoint
		_actor.combat.reset()
		# reset's input_cancelled signal is blocked along with other callbacks.
		_actor.combat.clear_input_intent()
		_actor.velocity = Vector3.ZERO
		for object: Object in blocked:
			if is_instance_valid(object): object.set_block_signals(blocked[object])
	prop.apply_persistent_state(candidate.objects[id], true)
	# The shared guard remains held through every observer and presentation call.
	# A save observer sees the entire reward/checkpoint, never an intermediate state.
	if data.kind == "chest":
		_actor.inventory.changed.emit()
	else:
		for resource: String in ["HP", "Stamina", "Energy"]:
			_actor.resources.resource_changed.emit(resource, _actor.resources.current(resource), _actor.resources.max_value(resource))
	_world.object_changed.emit(id)
	_present(prop, data)
	Guard.release(_world, OWNER)
	last_error = ""
	return true

func _interaction_error(prop: Node3D) -> String:
	if not _usable(): return "冒险尚未就绪"
	if Guard.busy(_world): return "冒险正在更新，请稍后交互"
	if not is_instance_valid(prop) or prop not in _nodes or not _definitions.has(prop.persistent_id): return "世界物体未注册"
	if not prop.is_inside_tree() or not _actor.is_inside_tree(): return "世界物体尚未就绪"
	if _game.get("paused") == true or _game.get_tree().paused: return "请先关闭当前界面"
	var controlled: Node = _game.controlled_actor() if _game.has_method("controlled_actor") else _actor
	if not Readiness.can_manage(controlled) or (controlled.has_method("is_human_controlled") and not controlled.is_human_controlled()): return "当前无法交互"
	if prop.get_world_3d() != controlled.get_world_3d() or prop.global_position.distance_to(controlled.global_position) >= 2.15: return "请靠近再交互"
	if _definitions[prop.persistent_id].kind == "shrine" and controlled != _actor: return "请先返回自己的身体，再使用记录石"
	var form: Variant = _actor.get("form")
	if _definitions[prop.persistent_id].kind == "shrine" and form != null and form.active: return "请先恢复原形，再使用记录石"
	return validate_state(_world.export_state())

func _block_actor_signals() -> Dictionary:
	var blocked: Dictionary = {}
	var objects: Array[Node] = [_actor]
	objects.append_array(_actor.find_children("*", "", true, false))
	for object: Node in objects:
		blocked[object] = object.is_blocking_signals()
		object.set_block_signals(true)
	return blocked

func _object_changed(id: String) -> void:
	for prop in _nodes:
		if is_instance_valid(prop) and prop.persistent_id == id: prop.apply_persistent_state(_world.get_object(id), true)

func _position(value: Array) -> Vector3:
	var local := Vector3(value[0], value[1], value[2])
	if is_instance_valid(_game.get("reference_map")): return _game.reference_map.to_global(local)
	return _game.GARDEN_ORIGIN + local

func _usable() -> bool:
	return is_instance_valid(_game) and is_instance_valid(_actor) and _world != null and not _definitions.is_empty()

func _present(prop: Node3D, data: Dictionary) -> void:
	if data.kind == "chest":
		var rewards: Array[String] = []
		for id: String in data.items: rewards.append("%s ×%d" % [_actor.inventory.definition(id).get("name", id), data.items[id]])
		_game.notify("获得" + " · ".join(rewards), Color("e6ca84"))
		_game.burst(prop.global_position + Vector3.UP, Color("efd495"), 18, 1.4)
		_game.sound.play_tone("chest")
	else:
		_game.notify("苔光回应了你 · 状态恢复，重生点已记录", Color("b4e4b3"))
		_game.ring_fx(prop.global_position + Vector3.UP * .1, 2.0, Color("a1e2bd"), .6)
		_game.sound.play_tone("heal")

func _fail(reason: String) -> bool:
	last_error = reason
	return false

static func _read_catalog() -> Dictionary:
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(PATH)) != OK or not parser.data is Dictionary: return {}
	return parser.data

static func _validate_catalog(catalog: Dictionary, database: RefCounted) -> String:
	if not _keys(catalog, ["version", "objects"]) or not _integer(catalog.version, 1, 1) or not catalog.objects is Dictionary or catalog.objects.is_empty() or catalog.objects.size() > 128:
		return "世界物体目录格式无效"
	if database == null: return "物品目录尚未就绪"
	for id in catalog.objects:
		if not id is String or not id.begins_with("prop.") or not WorldState.new()._valid_id(id): return "物体 ID 无效"
		var data: Variant = catalog.objects[id]
		if not data is Dictionary or data.get("id") != id or data.get("kind") not in ["chest", "shrine"]: return "物体定义无效：" + id
		var keys: Array = ["id", "kind", "name", "position", "rotation_y", "items" if data.kind == "chest" else "checkpoint"]
		if not _keys(data, keys) or not data.name is String or data.name.is_empty() or data.name.length() > 64 or not _vector(data.position) or not _number(data.rotation_y, -TAU, TAU): return "物体定义字段无效：" + id
		if data.kind == "shrine":
			if not _vector(data.checkpoint): return "记录点坐标无效：" + id
		else:
			if not data.items is Dictionary or data.items.is_empty() or data.items.size() > 16: return "宝箱奖励无效：" + id
			for item in data.items:
				if not item is String or not _integer(data.items[item], 1, MAX_QUANTITY): return "宝箱奖励数量无效：" + id
				if not database.items.has(item) and not database.weapons.has(item) and not database.equipment.has(item): return "宝箱奖励物品不存在：" + item
	return ""

static func _validate_records(snapshot: Dictionary, definitions: Dictionary) -> String:
	var reason: String = WorldState.new().validate_state(snapshot)
	if not reason.is_empty(): return reason
	for id: String in snapshot.objects:
		if not id.begins_with("prop."): continue
		if not definitions.has(id): return "未知世界物体：" + id
		var data: Dictionary = snapshot.objects[id]
		var kind: String = definitions[id].kind
		var field := "opened" if kind == "chest" else "activated"
		if not _keys(data, ["version", "kind", field]) or not _integer(data.version, 1, 1) or data.kind != kind or not data[field] is bool: return "世界物体状态无效：" + id
	return ""

static func _keys(data: Dictionary, keys: Array) -> bool:
	if data.size() != keys.size(): return false
	for key in keys:
		if not data.has(key): return false
	return true

static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return _number(value, minimum, maximum) and float(value) == floorf(float(value))

static func _number(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= minimum and value <= maximum

static func _vector(value: Variant) -> bool:
	if not value is Array or value.size() != 3: return false
	for part in value:
		if not _number(part, -10000, 10000): return false
	return true
