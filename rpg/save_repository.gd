extends RefCounted
## JSON-only save repository. Never loads executable Godot resources from disk.
const Database = preload("res://combat/combat_database.gd")
const ContentRelease = preload("res://rpg/content_release.gd")
const ContentBundle = preload("res://rpg/content_bundle.gd")
const WorldState = preload("res://rpg/world_state.gd")
const Races = preload("res://rpg/race_catalog.gd")
const MutationGuard = preload("res://rpg/mutation_guard.gd")
const EconomyService = preload("res://rpg/economy_service.gd")
const QuestService = preload("res://rpg/quest_service.gd")
const WorldObjects = preload("res://rpg/world_objects.gd")
const WorldInteractions = preload("res://rpg/world_interactions.gd")
const EncounterService = preload("res://rpg/encounter_service.gd")
const SLOT_COUNT := 20
const VERSION := 5
const MAX_BYTES := 2097152
const EQUIPMENT_SLOTS := ["head", "torso", "legs", "feet", "belt", "ring1", "ring2", "neck"]
const RESOURCES := ["HP", "Stamina", "Energy"]
const INITIAL_POSITION := [1.6, 2.35, 114.8]
var directory: String
var database: RefCounted
var last_error := ""
## Shared by repository instances so an observer cannot bypass the restore lock
## by constructing a second repository for the same live adventure.
static var _restoring_games: Dictionary = {}

func _init(path := "user://adventures", context: RefCounted = null) -> void:
	database = context if context != null else Database.new()
	# Even a caller forgetting the preview launcher must not put generated IDs
	# into a normal adventure slot. Explicit test/preview repositories stay local.
	var candidate := ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	var formal := ProjectSettings.globalize_path("user://adventures").simplify_path().trim_suffix("/")
	if OS.has_feature("windows"):
		candidate = candidate.to_lower()
		formal = formal.to_lower()
	if candidate == formal:
		if ContentRelease.is_active():
			path = ContentRelease.save_directory()
		elif database.is_active():
			path = "user://content-previews/" + str(database.identity().bundle_sha256) + "/adventures"
	directory = ProjectSettings.globalize_path(path).simplify_path()

func list_slots() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(SLOT_COUNT):
		result.append(slot(index))
	return result

func slot(index: int) -> Dictionary:
	var entry := {"slot": index, "occupied": false, "valid": false, "name": "", "location": "", "saved_at_local": "", "saved_at_unix": 0, "display_time": "", "level": 0, "error": ""}
	if index < 0 or index >= SLOT_COUNT:
		entry.error = "存档槽无效"
		return entry
	entry.occupied = _occupied(index)
	if not entry.occupied:
		return entry
	var result := load_slot(index)
	if not result.ok:
		entry.error = result.error
		return entry
	entry.merge(_metadata(result.snapshot), true)
	entry.valid = true
	return entry

func validate_name(value: String, excluding_slot := -1) -> String:
	var name := value.strip_edges()
	if name.is_empty():
		return "请输入冒险名字"
	if name.length() > 32:
		return "名字最多 32 个字符"
	if name in [".", ".."]:
		return "名字不能只使用句点"
	for index in range(name.length()):
		var code := name.unicode_at(index)
		if code < 32 or code == 127 or name[index] in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
			return "名字包含不允许的字符"
	for index in range(SLOT_COUNT):
		if index == excluding_slot or not _occupied(index):
			continue
		var existing := load_slot(index)
		if not existing.ok and FileAccess.file_exists(_path(index) + ".bak"):
			# A damaged primary must not allow a second adventure to take its
			# identity while its verified backup still records that name.
			existing = _read(_path(index) + ".bak")
		if existing.ok and existing.snapshot.name_key == name.to_lower():
			return "已有同名冒险，请使用不同名字"
	return ""

func validate_new_name(value: String) -> String:
	var reason := validate_name(value)
	if not reason.is_empty():
		return reason
	for index in range(SLOT_COUNT):
		if not _occupied(index):
			return ""
	return "20 个存档槽已满"

func create(value: String, preferred_slot := -1) -> Dictionary:
	var reason := validate_new_name(value)
	if not reason.is_empty():
		return _failure(reason)
	var index := -1
	if preferred_slot != -1:
		if preferred_slot < 0 or preferred_slot >= SLOT_COUNT or _occupied(preferred_slot):
			return _failure("所选存档槽不可用")
		index = preferred_slot
	for candidate in range(SLOT_COUNT):
		if index == -1 and not _occupied(candidate):
			index = candidate
			break
	var now := _clock()
	var snapshot := {"version": VERSION, "content_set": database.identity(), "slot": index, "name": value.strip_edges(), "name_key": value.strip_edges().to_lower(), "race_id": Races.DEFAULT_ID,
		"created_at_local": now.local, "created_at_unix": now.unix, "saved_at_local": now.local, "saved_at_unix": now.unix, "location": "风息原野",
		"inventory": {"stacks": {}, "quickslots": ["", "", "", ""], "cooldowns": {}},
		"progression": {"experience": 0, "starter_granted": false, "career_rewards": [], "claimed_rewards": {}, "enemy_kills": {}, "acquired_traits": {}},
		"loadout": {"level": 0, "career_ids": [], "equipment": {}, "sets": [{"weapon": "", "skills": ["", "", ""]}, {"weapon": "", "skills": ["", "", ""]}], "current_set": 0, "learned_skills": []},
		"attributes": {}, "resources": {"HP": 100.0, "Stamina": 3.0, "Energy": 0.0},
		"combat": {"cooldowns": {}, "stamina_clock": 0.0, "energy_clock": 0.0},
		"world_state": WorldState.new().export_state(),
		"world": {"position": INITIAL_POSITION.duplicate(), "checkpoint": INITIAL_POSITION.duplicate(), "encounter_origin": INITIAL_POSITION.duplicate(), "facing": [0.0, 0.0, -1.0]}}
	for equipment_slot in EQUIPMENT_SLOTS:
		snapshot.loadout.equipment[equipment_slot] = ""
	return _commit(snapshot, true)

## The migration service supplies an already converted target-content snapshot.
## Copying never grants starter/reward items or rewrites the source file.
func create_copy(snapshot: Dictionary, value: String, preferred_slot: int = -1) -> Dictionary:
	var reason := validate_snapshot(snapshot)
	if not reason.is_empty(): return _failure(reason)
	reason = validate_new_name(value)
	if not reason.is_empty(): return _failure(reason)
	if preferred_slot < -1 or preferred_slot >= SLOT_COUNT: return _failure("所选存档槽不可用")
	var index := preferred_slot
	if index == -1:
		for candidate in range(SLOT_COUNT):
			if not _occupied(candidate):
				index = candidate
				break
	if index < 0 or _occupied(index): return _failure("所选存档槽不可用")
	var copied := snapshot.duplicate(true)
	var now := _clock()
	copied.slot = index
	copied.name = value.strip_edges()
	copied.name_key = value.strip_edges().to_lower()
	copied.saved_at_local = now.local
	copied.saved_at_unix = now.unix
	return _commit(copied, true)

func save(index: int, value: String, actor: Node, game: Node, location := "") -> Dictionary:
	if _restore_in_progress(game):
		return _failure("冒险正在恢复，暂时不能保存")
	if index < 0 or index >= SLOT_COUNT:
		return _failure("存档槽无效")
	var previous := load_slot(index)
	if not previous.ok:
		return _failure("存档不存在或已损坏，不能覆盖：" + str(previous.error))
	if value.strip_edges().to_lower() != previous.snapshot.name_key:
		return _failure("冒险名字是唯一标识，不能覆盖其他冒险")
	var reason := validate_name(value, index)
	if not reason.is_empty():
		return _failure(reason)
	if not is_instance_valid(actor) or not is_instance_valid(game) or actor.inventory == null or actor.progression == null or actor.loadout.sandbox_mode:
		return _failure("只能保存正式冒险角色")
	var combat_runtime: Variant = game.get("combat_world")
	if is_instance_valid(combat_runtime) and combat_runtime.has_method("save_error"):
		var pending_error: String = combat_runtime.save_error()
		if not pending_error.is_empty():
			return _failure(pending_error)
	var persistent: Variant = game.get("world_state")
	if persistent == null or not persistent is WorldState:
		return _failure("冒险世界状态尚未就绪")
	var snapshot: Dictionary = previous.snapshot.duplicate(true)
	var form: Variant = actor.get("form")
	snapshot.race_id = form.canonical_race_id() if form != null else actor.get("race_id")
	snapshot.world_state = persistent.export_state()
	var quests: Variant = game.get("quests")
	if quests != null:
		var quest_error: String = quests.validate_state(snapshot.world_state)
		if not quest_error.is_empty():
			return _failure("任务状态无效：" + quest_error)
	var saved_position: Vector3 = actor.global_position
	var ladder: Variant = actor.get("ladder")
	if ladder != null and ladder.active:
		saved_position = ladder.stable_position()
	var now := _clock()
	snapshot.saved_at_local = now.local
	snapshot.saved_at_unix = now.unix
	snapshot.location = location if not location.is_empty() else _location_at(saved_position, game)
	snapshot.inventory = actor.inventory.export_state()
	snapshot.progression = actor.progression.export_state()
	snapshot.loadout = form.canonical_loadout() if form != null else actor.loadout.export_state()
	snapshot.attributes = form.canonical_attributes() if form != null else actor.stats.base.duplicate(true)
	snapshot.resources = form.canonical_resources() if form != null else {}
	if form == null:
		for resource in RESOURCES:
			snapshot.resources[resource] = actor.resources.current(resource)
	var cooldowns: Dictionary = {}
	for id in actor.combat.cooldowns:
		if float(actor.combat.cooldowns[id]) > 0.0:
			cooldowns[id] = float(actor.combat.cooldowns[id])
	snapshot.combat = {"cooldowns": cooldowns, "stamina_clock": float(actor.combat.stamina_clock), "energy_clock": float(actor.combat.energy_clock)}
	snapshot.world = {"position": _vector(saved_position), "facing": _vector(actor.facing), "checkpoint": _vector(game.checkpoint), "encounter_origin": _vector(game.encounter_origin)}
	if actor.resources.current("HP") <= 0.0 or actor.combat.state == "DEAD":
		snapshot.world.position = _vector(game.checkpoint)
		if location.is_empty():
			snapshot.location = _location_at(game.checkpoint, game)
		for resource in RESOURCES:
			snapshot.resources[resource] = form.canonical_max_resources()[resource] if form != null else actor.resources.max_value(resource)
		snapshot.combat = {"cooldowns": {}, "stamina_clock": 0.0, "energy_clock": 0.0}
	return _commit(snapshot)

func _item_action_exists(id: String) -> bool:
	for definition: Dictionary in database.items.values():
		if definition.get("effect", "") == "action" and str(definition.get("action", {}).get("id", "")) == id:
			return true
	return false

func load(index: int) -> Dictionary:
	return load_slot(index)

func load_slot(index: int) -> Dictionary:
	if index < 0 or index >= SLOT_COUNT:
		return _failure("存档槽无效")
	var path := _path(index)
	# A crash between the two rename operations leaves a verified old backup.
	if not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".bak"):
		path += ".bak"
	if not FileAccess.file_exists(path):
		return _failure("存档不存在")
	var result := _read(path)
	if not result.ok:
		return result
	if int(result.snapshot.slot) != index:
		return _failure("存档槽与文件不一致")
	return _success(result.snapshot)

func restore(snapshot: Dictionary, actor: Node, game: Node) -> Dictionary:
	if _restore_in_progress(game):
		return _failure("冒险正在恢复，不能重复读档")
	var migrated := migrate_snapshot(snapshot)
	if not migrated.ok:
		return migrated
	snapshot = migrated.snapshot
	if not is_instance_valid(actor) or not is_instance_valid(game) or actor.inventory == null or actor.progression == null or actor.loadout.sandbox_mode:
		return _failure("目标不是正式冒险角色")
	var persistent: Variant = game.get("world_state")
	if persistent == null or not persistent is WorldState:
		return _failure("目标冒险世界状态尚未就绪")
	if MutationGuard.busy(persistent):
		return _failure("冒险状态更新中，暂时不能读档")
	var quests: Variant = game.get("quests")
	if quests != null:
		var quest_error: String = quests.validate_state(snapshot.world_state)
		if not quest_error.is_empty():
			return _failure("任务状态无效：" + quest_error)
		if not quests.begin_restore():
			return _failure("任务更新中，暂时不能读档")
	# No callbacks occur between the preflight and this acquisition. This guard
	# covers all adventure services through their final refresh notifications.
	MutationGuard.acquire(persistent, "repository.restore")
	var game_id: int = game.get_instance_id()
	_restoring_games[game_id] = true
	var blocked := _block_restore_signals(actor, persistent, quests)
	if game.has_method("close_world_modal"):
		game.close_world_modal()
	# Validate completely before resetting or mutating the destination character.
	var combat_world: Variant = game.get("combat_world")
	if is_instance_valid(combat_world):
		var control: Variant = combat_world.get("control")
		if control != null:
			control.cancel_all()
	var form: Variant = actor.get("form")
	var restored_form: bool = form != null and form.active
	if form != null:
		form.clear_for_load()
	var ladder: Variant = actor.get("ladder")
	if ladder != null:
		ladder.cleanup()
	var surface: Variant = actor.get("surface_traversal")
	if surface != null:
		surface.clear()
	if is_instance_valid(combat_world) and combat_world.has_method("clear_attacks"):
		combat_world.clear_attacks()
	actor.combat.reset()
	# input_cancelled is intentionally silent inside the transaction.
	actor.combat.clear_input_intent()
	actor.stats.modifiers.clear()
	actor.inventory.import_state(snapshot.inventory)
	actor.progression.import_state(snapshot.progression)
	actor.loadout.import_state(snapshot.loadout)
	actor.stats.set_base(snapshot.attributes)
	actor.loadout.refresh_resources(false)
	var revive := float(snapshot.resources.HP) <= 0.0
	actor.global_position = _to_vector(snapshot.world.checkpoint if revive else snapshot.world.position)
	actor.velocity = Vector3.ZERO
	actor.facing = _to_vector(snapshot.world.facing).normalized()
	actor.spawn_point = _to_vector(snapshot.world.checkpoint)
	game.checkpoint = _to_vector(snapshot.world.checkpoint)
	game.encounter_origin = _to_vector(snapshot.world.encounter_origin)
	if game.has_method("_camera_lead"):
		game.smooth_target = actor.global_position + game._camera_lead()
	actor.combat.cooldowns = {} if revive else snapshot.combat.cooldowns.duplicate(true)
	actor.combat.stamina_clock = 0.0 if revive else float(snapshot.combat.stamina_clock)
	actor.combat.energy_clock = 0.0 if revive else float(snapshot.combat.get("energy_clock", 0.0))
	for resource in RESOURCES:
		var restored: float = actor.resources.max_value(resource) if revive else float(snapshot.resources[resource])
		actor.resources.change(resource, restored - actor.resources.current(resource))
	actor.display_name = snapshot.name
	actor.race_id = snapshot.race_id
	persistent.import_state(snapshot.world_state)
	if is_instance_valid(game.get("rest_service")): game.rest_service.refresh()
	if is_instance_valid(combat_world) and combat_world.has_method("restore_encounters"):
		combat_world.restore_encounters()
	for object: Object in blocked:
		if is_instance_valid(object):
			object.set_block_signals(blocked[object])
	# All durable state is committed before the first observer can run. Keep both
	# guards held during final notifications, including callbacks via another repo.
	actor.stats.changed.emit()
	for resource in RESOURCES:
		actor.resources.resource_changed.emit(resource, actor.resources.current(resource), actor.resources.max_value(resource))
	actor.inventory.changed.emit()
	actor.loadout.changed.emit()
	actor.progression.changed.emit()
	if restored_form:
		form.changed.emit()
	if quests != null:
		quests.end_restore()
	if game.has_method("refresh_world_objects"):
		game.refresh_world_objects()
	MutationGuard.release(persistent, "repository.restore")
	_restoring_games.erase(game_id)
	return _success(snapshot)

func _restore_in_progress(game: Node) -> bool:
	return is_instance_valid(game) and _restoring_games.has(game.get_instance_id())

func _block_restore_signals(actor: Node, persistent: Object, quests: Object) -> Dictionary:
	var previous: Dictionary = {}
	var objects: Array[Object] = [actor, persistent]
	var form: Variant = actor.get("form")
	if form != null:
		objects.append(form)
	for child in actor.find_children("*", "", true, false):
		objects.append(child)
	if quests != null:
		objects.append(quests)
	for object in objects:
		previous[object] = object.is_blocking_signals()
		object.set_block_signals(true)
	return previous

## A migration is pure: disk and live actors stay untouched until a later save/restore.
func migrate_snapshot(source: Dictionary) -> Dictionary:
	if not source.has("version") or not _integer(source.version, 1, VERSION):
		return _failure("不支持的存档版本")
	var snapshot := source.duplicate(true)
	if int(snapshot.version) == 1:
		if not _keys(snapshot, ["version", "slot", "name", "name_key", "created_at_local", "created_at_unix", "saved_at_local", "saved_at_unix", "location", "inventory", "progression", "loadout", "attributes", "resources", "combat", "world"]):
			return _failure("旧存档结构不完整或包含未知字段")
		snapshot.version = 2
		snapshot.world_state = WorldState.new().export_state()
	if int(snapshot.version) == 2:
		if not _keys(snapshot, ["version", "slot", "name", "name_key", "created_at_local", "created_at_unix", "saved_at_local", "saved_at_unix", "location", "inventory", "progression", "loadout", "attributes", "resources", "combat", "world", "world_state"]):
			return _failure("旧存档结构不完整或包含未知字段")
		snapshot.version = 3
		snapshot.race_id = Races.DEFAULT_ID
	if int(snapshot.version) == 3:
		if not snapshot.get("resources") is Dictionary or not _keys(snapshot.resources, ["HP", "Stamina", "Qi", "SpellSlot"]):
			return _failure("旧存档资源字段无效")
		for resource in ["Qi", "SpellSlot"]:
			if not _number(snapshot.resources[resource], 0, 1000000):
				return _failure("旧存档资源数值无效：" + resource)
		snapshot.resources = CombatResources.migrated_values(snapshot.resources)
		snapshot.version = 4
	if int(snapshot.version) == 4:
		if not _keys(snapshot, ["version", "slot", "name", "name_key", "created_at_local", "created_at_unix", "saved_at_local", "saved_at_unix", "location", "inventory", "progression", "loadout", "attributes", "resources", "combat", "world", "world_state", "race_id"]):
			return _failure("旧存档结构不完整或包含未知字段")
		# A legacy save belongs to built-in content. Loading it while an external
		# pack is selected cannot silently adopt that pack's changed definitions.
		snapshot.content_set = {}
		snapshot.version = 5
	var upgrade_error := _upgrade_builtin_shop_price(snapshot)
	if not upgrade_error.is_empty():
		return _failure(upgrade_error)
	var reason := validate_snapshot(snapshot)
	return _failure(reason) if not reason.is_empty() else _success(snapshot)

## Only the known built-in price correction can advance an existing shop record
## implicitly. External content still requires the explicit copy-migration flow.
## This operates on migrate_snapshot's private copy; reads never rewrite files.
func _upgrade_builtin_shop_price(snapshot: Dictionary) -> String:
	if not snapshot.get("content_set") is Dictionary or not snapshot.content_set.is_empty() or not database.identity().is_empty():
		return ""
	if not snapshot.get("world_state") is Dictionary or not snapshot.world_state.get("objects") is Dictionary:
		return ""
	var record: Variant = snapshot.world_state.objects.get("economy.shop.village_supply")
	if not record is Dictionary or not _integer(record.get("catalog_version"), 1, 1):
		return ""
	var target: Dictionary = database.world_catalog("shops")
	var target_shop: Variant = target.get("village_supply")
	# A detached historical context must keep its own v1 records unchanged.
	if not target_shop is Dictionary or not _integer(target_shop.get("catalog_version"), 2, 2):
		return ""
	var historical := ContentBundle.source_world_data("shops", ContentBundle.LEGACY_SHOPS_V1_SHA)
	if not historical.ok:
		return "内置商店升级失败：" + str(historical.error)
	var previous: Dictionary = historical.data
	var expected := previous.duplicate(true)
	expected.village_supply.catalog_version = 2
	expected.village_supply.goods.spell_potion.buy_price = 15
	expected.village_supply.goods.spell_potion.sell_price = 4
	if JSON.parse_string(JSON.stringify(target)) != JSON.parse_string(JSON.stringify(expected)):
		return "内置商店目录不是受支持的价格升级，请显式迁移冒险副本"
	var reason := EconomyService._validate_definitions(previous, database)
	if reason.is_empty():
		reason = EconomyService._validate_records(snapshot.world_state, previous)
	if not reason.is_empty():
		return "旧经济状态无效：" + reason
	# No wallet, remaining stock, purchase history, inventory or rewards change.
	record.catalog_version = 2
	return ""

func validate_snapshot(snapshot: Dictionary) -> String:
	if not _keys(snapshot, ["version", "content_set", "slot", "name", "name_key", "created_at_local", "created_at_unix", "saved_at_local", "saved_at_unix", "location", "inventory", "progression", "loadout", "attributes", "resources", "combat", "world", "world_state", "race_id"]):
		return "存档结构不完整或包含未知字段"
	if not _integer(snapshot.version, VERSION, VERSION) or not _integer(snapshot.slot, 0, SLOT_COUNT - 1):
		return "不支持的存档版本或槽位"
	# JSON round-trips numeric versions as floats. Compare normalized JSON data,
	# not text spelling (1 vs 1.0) or Dictionary insertion order.
	if not snapshot.content_set is Dictionary or JSON.parse_string(JSON.stringify(snapshot.content_set)) != JSON.parse_string(JSON.stringify(database.identity())):
		return "存档需要的内容包版本与当前内容集不一致，请使用原内容包启动"
	if not Races.is_valid(snapshot.race_id):
		return "种族身份无效"
	if not snapshot.world_state is Dictionary:
		return "世界状态类型无效"
	var world_error: String = WorldState.new().validate_state(snapshot.world_state)
	if not world_error.is_empty():
		return "世界状态无效：" + world_error
	var economy_error: String = EconomyService.validate_snapshot(snapshot.world_state, database)
	if not economy_error.is_empty():
		return "经济状态无效：" + economy_error
	var quest_error: String = QuestService.validate_snapshot(snapshot.world_state, database)
	if not quest_error.is_empty():
		return "任务状态无效：" + quest_error
	var context_error: String = WorldInteractions.validate_snapshot(snapshot.world_state)
	if not context_error.is_empty(): return "交互状态无效：" + context_error
	var rest_error: String = preload("res://rpg/rest_service.gd").validate_snapshot(snapshot.world_state)
	if not rest_error.is_empty(): return rest_error
	var objects_error: String = WorldObjects.validate_snapshot(snapshot.world_state, database)
	if not objects_error.is_empty():
		return "世界物体状态无效：" + objects_error
	var encounter_error: String = EncounterService.validate_snapshot(snapshot.world_state, database)
	if not encounter_error.is_empty():
		return "遭遇状态无效：" + encounter_error
	if not snapshot.name is String or not snapshot.name_key is String or snapshot.name != snapshot.name.strip_edges() or snapshot.name_key != snapshot.name.to_lower():
		return "存档名字无效"
	var name_check := _plain_name(snapshot.name)
	if not name_check.is_empty():
		return name_check
	for key in ["created_at_local", "saved_at_local"]:
		if not snapshot[key] is String or not _iso_time(snapshot[key]):
			return "存档现实时间无效"
	for key in ["created_at_unix", "saved_at_unix"]:
		if not _number(snapshot[key], 0, 7258118400.0):
			return "存档时间戳无效"
	if not snapshot.location is String or snapshot.location not in ["风息原野", "风铃村", "低语森林", "风铃旅馆"]:
		return "存档地点无效"
	for key in ["inventory", "progression", "loadout", "attributes", "resources", "combat", "world"]:
		if not snapshot[key] is Dictionary:
			return "存档字段类型无效：" + key
	var inv: Dictionary = snapshot.inventory
	if not _keys(inv, ["stacks", "quickslots", "cooldowns"]) or not inv.stacks is Dictionary or not inv.quickslots is Array or not inv.cooldowns is Dictionary or inv.quickslots.size() != 4:
		return "背包结构无效"
	for id in inv.stacks:
		if not _item_exists(id) or not _integer(inv.stacks[id], 1, 1000000):
			return "背包物品或数量无效"
	for id in inv.quickslots:
		if not id is String or (not id.is_empty() and (not database.items.has(id) or database.items[id].get("category", "consumable") != "consumable")):
			return "快捷物品无效"
	for id in inv.cooldowns:
		if not database.items.has(id) or not _number(inv.cooldowns[id], 0, float(database.items[id].get("cooldown", 0)) + .001):
			return "物品冷却无效"
	var kit: Dictionary = snapshot.loadout
	if not _keys(kit, ["level", "career_ids", "equipment", "sets", "current_set", "learned_skills"]):
		return "配装结构无效"
	if not _integer(kit.level, 0, int(database.progression.rules.max_level)) or not _integer(kit.current_set, 0, 1) or not kit.career_ids is Array or not kit.equipment is Dictionary or not kit.sets is Array or not kit.learned_skills is Array:
		return "等级或配装类型无效"
	var level := int(kit.level)
	if (level == 0 and not kit.career_ids.is_empty()) or kit.career_ids.size() > database.careers.size() or kit.sets.size() != 2 or not _keys(kit.equipment, EQUIPMENT_SLOTS):
		return "职业链或装备槽无效"
	var seen: Array = []
	var available: Array = []
	var pair := ""
	var proficiencies: Array = []
	for id in kit.career_ids:
		if not id is String or not database.careers.has(id) or id in seen:
			return "职业ID无效"
		var career: Dictionary = database.careers[id]
		if int(career.get("required_level", 1)) > level:
			return "职业等级条件不满足"
		if seen.is_empty():
			if int(career.get("required_level", 1)) != 1:
				return "缺少基础职业"
		elif id not in database.careers[seen.back()].get("next_careers", []):
			return "职业进阶链无效"
		seen.append(id)
		proficiencies.append_array(career.get("proficiencies", []))
		if career.has("loadout_rule"):
			pair = career.loadout_rule
		for skill in career.get("skills", []):
			if int(database.skills[skill].get("min_level", 1)) <= level and skill not in available:
				available.append(skill)
	var expected_base: Dictionary = database.careers[seen[0]].get("stats", {}) if not seen.is_empty() else {}
	if snapshot.attributes.size() != expected_base.size():
		return "基础属性字段无效"
	for stat in expected_base:
		if not snapshot.attributes.has(stat) or not _number(snapshot.attributes[stat], float(expected_base[stat]), float(expected_base[stat])):
			return "基础属性与职业不一致"
	var learned: Array = []
	for id in kit.learned_skills:
		if not id is String or id not in available or id in learned:
			return "已学技能无效"
		learned.append(id)
	var used: Dictionary = {}
	var totals := expected_base.duplicate(true)
	for equipment_slot in EQUIPMENT_SLOTS:
		var id: Variant = kit.equipment[equipment_slot]
		if not id is String:
			return "护具ID类型无效"
		if id.is_empty():
			continue
		if not database.equipment.has(id):
			return "护具不存在"
		var item: Dictionary = database.equipment[id]
		if item.slot != equipment_slot and not (item.slot == "ring" and equipment_slot in ["ring1", "ring2"]):
			return "护具槽位不匹配"
		used[id] = int(used.get(id, 0)) + 1
		for stat in item.get("modifiers", {}):
			totals[stat] = float(totals.get(stat, 0)) + float(item.modifiers[stat])
	for index in range(2):
		var group: Variant = kit.sets[index]
		if not group is Dictionary or not _keys(group, ["weapon", "skills"]) or not group.weapon is String or not group.skills is Array or group.skills.size() != 3:
			return "武器与技能组无效"
		if not group.weapon.is_empty():
			if not database.weapons.has(group.weapon):
				return "武器不存在"
			var weapon: Dictionary = database.weapons[group.weapon]
			if weapon.animation_family not in proficiencies and weapon.weapon_type not in proficiencies:
				return "职业没有所存武器的熟练度"
			if pair == "sword_shield_pair" and ((index == 0 and weapon.weapon_type not in ["Sword", "Katana"]) or (index == 1 and weapon.weapon_type != "Shield")):
				return "士兵必须使用A剑B盾"
			if pair == "dual_sword_pair" and weapon.weapon_type not in ["Sword", "Katana"]:
				return "二刀流必须使用两把剑"
			used[group.weapon] = int(used.get(group.weapon, 0)) + 1
		for id in group.skills:
			if not id is String or (not id.is_empty() and id not in learned):
				return "备战技能尚未学会"
	for id in used:
		if int(inv.stacks.get(id, 0)) < int(used[id]):
			return "装备数量超过实际持有数量"
	var growth: Dictionary = snapshot.progression
	if not _keys(growth, ["experience", "starter_granted", "career_rewards", "claimed_rewards", "enemy_kills", "acquired_traits"]):
		return "成长结构无效"
	if not growth.starter_granted is bool or growth.starter_granted != (level > 0) or not growth.career_rewards is Array or not growth.claimed_rewards is Dictionary or not growth.enemy_kills is Dictionary or not growth.acquired_traits is Dictionary:
		return "成长记录类型无效"
	var xp_limit := int(database.progression.rules.xp_to_next.get(str(level), 1)) - 1 if level > 0 and level < int(database.progression.rules.max_level) else 0
	if not _integer(growth.experience, 0, xp_limit):
		return "当前级经验无效"
	var rewards: Array = []
	for id in growth.career_rewards:
		# Receipts survive a respec and can belong to a previously chosen path.
		if not id is String or not database.careers.has(id) or id in rewards:
			return "职业奖励记录无效"
		var required := int(database.careers[id].get("required_level", 1))
		if required <= 1 or required > level:
			return "职业奖励记录无效"
		rewards.append(id)
	if growth.claimed_rewards.size() > 100000:
		return "奖励记录过大"
	for id in growth.claimed_rewards:
		if not id is String or id.is_empty() or id.length() > 128 or growth.claimed_rewards[id] != true:
			return "击杀奖励记录无效"
	for id in growth.enemy_kills:
		if not database.enemies.has(id) or not _integer(growth.enemy_kills[id], 0, 1000000):
			return "敌人掉落轮换记录无效"
	for id in growth.acquired_traits:
		var acquired: Variant = growth.acquired_traits[id]
		if not database.passives.has(id) or not acquired is Dictionary or not _keys(acquired, ["source", "kind"]):
			return "获得特性记录无效"
		if not acquired.source is String or acquired.source.strip_edges().is_empty() or acquired.source.length() > 256 or not acquired.kind is String or acquired.kind.length() > 32:
			return "特性来源无效"
	if not _keys(snapshot.resources, RESOURCES):
		return "资源字段无效"
	var formulas: Dictionary = database.careers[seen[0]].formulas if not seen.is_empty() else {"HP": 100, "Stamina": 3, "Energy": 0}
	for resource in RESOURCES:
		var maximum := _formula(formulas.get(resource, 0), totals, level)
		if not _number(snapshot.resources[resource], 0, maxf(0, maximum) + .001):
			return "资源超过职业与装备计算上限：" + resource
	var combat: Dictionary = snapshot.combat
	var valid_fields := _keys(combat, ["cooldowns", "stamina_clock"]) or _keys(combat, ["cooldowns", "stamina_clock", "energy_clock"])
	if not valid_fields or not combat.cooldowns is Dictionary or not _number(combat.stamina_clock, 0, 86400) or not _number(combat.get("energy_clock", 0.0), 0, 2.0):
		return "战斗恢复状态无效"
	for id in combat.cooldowns:
		if not database.skills.has(id) and not database.actions.has(id) and not database.reactions.has(id) and not _item_action_exists(str(id)):
			return "动作冷却ID无效"
		if not _number(combat.cooldowns[id], 0, 3600):
			return "动作冷却无效"
	if not _keys(snapshot.world, ["position", "checkpoint", "encounter_origin", "facing"]):
		return "位置结构无效"
	for key in snapshot.world:
		if not _valid_vector(snapshot.world[key]):
			return "位置坐标无效"
	var facing := _to_vector(snapshot.world.facing)
	if absf(facing.y) > .001 or facing.length_squared() < .01 or facing.length_squared() > 1.01:
		return "角色朝向无效"
	return ""

func _commit(snapshot: Dictionary, create_only := false) -> Dictionary:
	var reason := validate_snapshot(snapshot)
	if not reason.is_empty():
		return _failure(reason)
	var made := DirAccess.make_dir_recursive_absolute(directory)
	if made != OK:
		return _failure("无法创建存档目录：" + error_string(made))
	var lock := _acquire_write_lock()
	if not lock.ok: return _failure(lock.error)
	var result := _commit_new_locked(snapshot) if create_only else _commit_locked(snapshot)
	_release_write_lock(lock)
	return result

func _acquire_write_lock() -> Dictionary:
	var path := directory.path_join(".write-lock")
	var made := DirAccess.make_dir_absolute(path)
	if made != OK:
		var reason := "存档目录正在写入；若上次写入异常中断，请检查 .write-lock 后恢复" if _path_occupied(path) else "无法创建存档写入锁：" + error_string(made)
		return {"ok": false, "error": reason, "path": "", "token": ""}
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	var marker := path.path_join("owner")
	var file := FileAccess.open(marker, FileAccess.WRITE)
	if file == null:
		DirAccess.remove_absolute(path)
		return {"ok": false, "error": "无法创建存档写入锁", "path": "", "token": ""}
	file.store_string(token)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return {"ok": false, "error": "存档写入锁记录失败，请检查 .write-lock 后恢复", "path": "", "token": ""}
	return {"ok": true, "error": "", "path": path, "token": token}

func _release_write_lock(lock: Dictionary) -> void:
	var marker: String = str(lock.path).path_join("owner")
	if FileAccess.get_file_as_string(marker) != lock.token: return
	if DirAccess.remove_absolute(marker) == OK: DirAccess.remove_absolute(lock.path)

## All repository writers honor the directory lock. A copy may publish only to
## an empty slot and never rotates/replaces any existing primary or backup.
func _commit_new_locked(snapshot: Dictionary) -> Dictionary:
	var index := int(snapshot.slot)
	if _occupied(index): return _failure("所选存档槽已被占用，未覆盖任何文件")
	var reason := validate_name(snapshot.name)
	if not reason.is_empty(): return _failure(reason)
	var path := _path(index)
	var temp := path + ".copy-" + Crypto.new().generate_random_bytes(16).hex_encode() + ".tmp"
	if FileAccess.file_exists(temp) or DirAccess.dir_exists_absolute(temp): return _failure("存档临时路径已被占用")
	var payload := JSON.stringify(snapshot)
	var envelope := JSON.stringify({"format": "mosslight_adventure", "version": VERSION, "payload_json": payload, "sha256": payload.sha256_text()})
	var expected := _bytes_sha256(envelope.to_utf8_buffer())
	var error := _write_copy_file(temp, envelope)
	if not error.is_empty():
		_discard_copy_temp(temp, expected)
		return _failure(error)
	var verified := read_verified_file(temp)
	if not verified.ok or verified.file_sha256 != expected:
		_discard_copy_temp(temp, expected)
		return _failure("临时副本验证失败，原存档未改动")
	# Recheck after the full write/readback. This also detects unrelated tools
	# writing an occupied slot without honoring our repository lock.
	if _occupied(index) or not validate_name(snapshot.name).is_empty():
		_discard_copy_temp(temp, expected)
		return _failure("目标槽或名字在写入期间已被占用，未覆盖任何文件")
	if DirAccess.rename_absolute(temp, path) != OK:
		_discard_copy_temp(temp, expected)
		return _failure("无法发布冒险副本，原存档未改动")
	return _success(snapshot)

func _write_copy_file(path: String, envelope: String) -> String:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return "无法写入存档临时副本"
	file.store_string(envelope)
	file.flush()
	var error := file.get_error()
	file.close()
	return "" if error == OK else "存档临时副本写入失败"

func _discard_copy_temp(path: String, expected: String) -> void:
	# A failed write may leave different bytes. Never remove a file unless its
	# exact contents prove it is the temporary payload owned by this operation.
	if FileAccess.file_exists(path) and FileAccess.get_sha256(path) == expected:
		DirAccess.remove_absolute(path)

func _commit_locked(snapshot: Dictionary) -> Dictionary:
	var path := _path(int(snapshot.slot))
	var temp := path + ".tmp"
	var backup := path + ".bak"
	if FileAccess.file_exists(path):
		var old := _read(path)
		if not old.ok:
			return _failure("现有存档已损坏，保留原文件并拒绝覆盖")
		if old.snapshot.name_key != snapshot.name_key:
			return _failure("不能覆盖其他名字的冒险")
	var payload := JSON.stringify(snapshot)
	var envelope := JSON.stringify({"format": "mosslight_adventure", "version": VERSION, "payload_json": payload, "sha256": payload.sha256_text()})
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return _failure("无法写入存档临时文件")
	file.store_string(envelope)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK or not _read(temp).ok:
		return _failure("临时存档验证失败，原存档已保留")
	var rotated := false
	if FileAccess.file_exists(path):
		if FileAccess.file_exists(backup) and DirAccess.remove_absolute(backup) != OK:
			return _failure("无法更新备份，原存档已保留")
		if DirAccess.rename_absolute(path, backup) != OK:
			return _failure("无法备份原存档")
		rotated = true
	if DirAccess.rename_absolute(temp, path) != OK:
		if rotated:
			DirAccess.rename_absolute(backup, path)
		return _failure("无法发布新存档，原存档已保留")
	return _success(snapshot)

func _read(path: String) -> Dictionary:
	return read_verified_file(path)

## Read the exact selected file, including a deliberately selected backup. No
## fallback, repair, directory creation or content activation occurs here.
func read_verified_file(path: String) -> Dictionary:
	if not path.is_absolute_path(): return _failure("存档来源必须是明确的绝对路径")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("无法读取存档")
	if file.get_length() > MAX_BYTES:
		file.close()
		return _failure("存档文件过大")
	var length := file.get_length()
	var bytes := file.get_buffer(length)
	file.close()
	if bytes.size() != length: return _failure("存档读取期间发生变化")
	var file_sha256 := _bytes_sha256(bytes)
	var raw := bytes.get_string_from_utf8()
	if raw.to_utf8_buffer() != bytes: return _failure("存档不是完整 UTF-8 文本")
	var parser := JSON.new()
	if parser.parse(raw) != OK or not parser.data is Dictionary:
		return _failure("存档JSON已损坏")
	var envelope: Dictionary = parser.data
	if not _keys(envelope, ["format", "version", "payload_json", "sha256"]) or envelope.format != "mosslight_adventure" or not _integer(envelope.version, 1, VERSION):
		return _failure("存档格式或版本不受支持")
	if not envelope.payload_json is String or not envelope.sha256 is String or envelope.payload_json.sha256_text() != envelope.sha256:
		return _failure("存档完整性校验失败")
	if parser.parse(envelope.payload_json) != OK or not parser.data is Dictionary:
		return _failure("存档内容已损坏")
	var snapshot: Dictionary = parser.data
	if not snapshot.has("version") or snapshot.version != envelope.version:
		return _failure("存档封装与内容版本不一致")
	var result := migrate_snapshot(snapshot)
	if not result.ok: return result
	if FileAccess.get_sha256(path) != file_sha256: return _failure("存档读取期间发生变化，请重新选择")
	result.file_sha256 = file_sha256
	return result

func _bytes_sha256(bytes: PackedByteArray) -> String:
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(bytes)
	return digest.finish().hex_encode()

func _metadata(snapshot: Dictionary) -> Dictionary:
	return {"slot": int(snapshot.slot), "name": snapshot.name, "location": snapshot.location, "saved_at_local": snapshot.saved_at_local, "saved_at_unix": snapshot.saved_at_unix, "display_time": str(snapshot.saved_at_local).left(16).replace("T", " "), "level": int(snapshot.loadout.level)}

func _success(snapshot: Dictionary) -> Dictionary:
	last_error = ""
	return {"ok": true, "error": "", "slot": int(snapshot.slot), "snapshot": snapshot.duplicate(true), "metadata": _metadata(snapshot)}

func _failure(message: String) -> Dictionary:
	last_error = message
	return {"ok": false, "error": message, "slot": -1, "snapshot": {}, "metadata": {}}

func _path(index: int) -> String:
	return directory.path_join("slot_%02d.json" % (index + 1))

func _occupied(index: int) -> bool:
	return _path_occupied(_path(index)) or _path_occupied(_path(index) + ".bak") or _path_occupied(_path(index) + ".tmp")

func _path_occupied(path: String) -> bool:
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path): return true
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())

func _clock() -> Dictionary:
	var bias := int(Time.get_time_zone_from_system().bias)
	var zone := ("+" if bias >= 0 else "-") + "%02d:%02d" % [absi(bias) / 60, absi(bias) % 60]
	return {"local": Time.get_datetime_string_from_system(false, false) + zone, "unix": Time.get_unix_time_from_system()}

func _location(actor: Node, game: Node) -> String:
	return _location_at(actor.global_position, game)

func _location_at(position: Vector3, game: Node) -> String:
	if position.distance_to(preload("res://rpg/inn_room.gd").ROOM)<12.0: return "风铃旅馆"
	var point: Vector3 = game.reference_map.to_local(position) if is_instance_valid(game.get("reference_map")) else position - Vector3(0, 0, 110)
	return "风铃村" if point.z < -29 else ("低语森林" if point.x > 23 else "风息原野")

func _plain_name(value: String) -> String:
	if value.is_empty() or value.length() > 32 or value in [".", ".."]:
		return "存档名字无效"
	for index in range(value.length()):
		if value.unicode_at(index) < 32 or value.unicode_at(index) == 127 or value[index] in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
			return "存档名字含非法字符"
	return ""

func _keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true

func _number(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= minimum and float(value) <= maximum

func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return _number(value, minimum, maximum) and float(value) == floor(float(value))

func _item_exists(id: Variant) -> bool:
	return id is String and (database.items.has(id) or database.weapons.has(id) or database.equipment.has(id))

func _valid_vector(value: Variant) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for component in value:
		if not _number(component, -10000, 10000):
			return false
	return true

func _vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _to_vector(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _formula(value: Variant, stats: Dictionary, level: int) -> float:
	if value is int or value is float:
		return float(value)
	var expression := Expression.new()
	if expression.parse(str(value), PackedStringArray(["STR", "DEX", "CON", "INT", "PER", "CHA", "level"])) != OK:
		return 0
	var inputs: Array = []
	for stat in CombatStats.IDS:
		inputs.append(float(stats.get(stat, 0)))
	inputs.append(level)
	var result: Variant = expression.execute(inputs, null, false)
	return 0.0 if expression.has_execute_failed() else float(result)

func _iso_time(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}[+-]\\d{2}:\\d{2}$")
	return regex.search(value) != null
