extends RefCounted
## Explicit copy between verified content contexts: additions and versioned shop
## repricing only. Planning never
## restores an actor, activates old content, awards loot, or writes either save.
const Repository = preload("res://rpg/save_repository.gd")
const Source = preload("res://rpg/save_source_context.gd")
const Bundle = preload("res://rpg/content_bundle.gd")
const Release = preload("res://rpg/content_release.gd")
const Economy = preload("res://rpg/economy_service.gd")
var _repository: RefCounted
var _plan: Dictionary = {}

func _init(repository: RefCounted) -> void:
	_repository = repository

func preflight(source_save_path: String, source_release_directory: String) -> Dictionary:
	_plan.clear()
	if source_save_path.is_empty() or not source_save_path.is_absolute_path():
		return _failure("请选择旧冒险的完整存档路径")
	var source := Source.open_release(source_release_directory)
	if not source.ok: return _failure(source.error)
	var reader := Repository.new(OS.get_temp_dir().path_join("mosslight-read-only-validation"), source.context)
	var read: Dictionary = reader.read_verified_file(source_save_path)
	if not read.ok: return _failure("旧冒险无法按所选版本读取：" + str(read.error))
	var result := build_plan(read.snapshot, source.context, _repository.database)
	if not result.ok: return result
	_plan = {"source_save": source_save_path, "source_release": source_release_directory,
		"source_hash": read.file_sha256, "source_fingerprints": source.fingerprints.duplicate(true),
		"source_identity": source.context.identity(), "target": _context_data(_repository.database),
		"directory": _repository.directory, "snapshot": result.snapshot.duplicate(true)}
	return {"ok": true, "error": "", "metadata": read.metadata.duplicate(true),
		"changes": result.changes.duplicate(), "source_label": source.source_label,
		"target_label": _target_label()}

func commit(name: String, slot: int) -> Dictionary:
	if _plan.is_empty(): return _failure("请先完成迁移预检")
	# Consume the preview on every attempt. Repeated Enter cannot create a second
	# adventure; an interrupted/failed attempt needs a fresh review.
	var plan := _plan.duplicate(true)
	_plan.clear()
	if _repository.directory != plan.directory or not _same(_context_data(_repository.database), plan.target):
		return _failure("当前版本或目标位置已经改变，请重新预检")
	var source := Source.open_release(plan.source_release)
	if not source.ok: return _failure("旧版本文件发生变化，请重新预检：" + str(source.error))
	if not _same(source.fingerprints, plan.source_fingerprints) or not _same(source.context.identity(), plan.source_identity):
		return _failure("旧版本文件发生变化，请重新预检")
	var reader := Repository.new(OS.get_temp_dir().path_join("mosslight-read-only-validation"), source.context)
	var read: Dictionary = reader.read_verified_file(plan.source_save)
	if not read.ok or read.get("file_sha256", "") != plan.source_hash:
		return _failure("旧冒险已被修改或无法读取，请重新预检")
	var checked := build_plan(read.snapshot, source.context, _repository.database)
	if not checked.ok or not _same(checked.get("snapshot", {}), plan.snapshot):
		return _failure("迁移结果已经改变，请重新预检")
	return _repository.create_copy(checked.snapshot, name, slot)

## Strict semantic subset: existing definitions stay identical, except appended
## career branches/learnable skills, shop goods, quest rewards and fixed drops,
## plus shop prices with an explicit catalog-version increase.
## Both ends validate against their own context before publication is possible.
static func build_plan(snapshot: Dictionary, source: RefCounted, target: RefCounted) -> Dictionary:
	var validator := Repository.new(OS.get_temp_dir().path_join("mosslight-read-only-validation"), source)
	var reason: String = validator.validate_snapshot(snapshot)
	if not reason.is_empty(): return _failure("旧冒险校验失败：" + reason)
	var changes: Array[String] = []
	var additions := 0
	for catalog: String in Bundle.CATALOGS:
		var before: Dictionary = source.get(catalog)
		var after: Dictionary = target.get(catalog)
		for id: String in before:
			if not after.has(id): return _failure("新版本缺少原有内容，暂不能自动迁移：" + catalog + "/" + id)
			var old: Dictionary = before[id].duplicate(true)
			var next: Dictionary = after[id].duplicate(true)
			if catalog == "careers":
				# These lists expose choices; they do not select a career, learn a
				# skill or equip it. Passive/default-loadout grants remain exact.
				for field: String in ["next_careers", "skills"]:
					var choices: Array = old.get(field, [])
					var new_choices: Array = next.get(field, [])
					if new_choices.size() < choices.size() or not _same(new_choices.slice(0, choices.size()), choices):
						return _failure("原职业进阶或技能顺序发生变化，暂不能自动迁移：" + id)
					var available: Dictionary = after if field == "next_careers" else target.skills
					for choice in new_choices:
						if not available.has(choice): return _failure("新职业或技能选项不存在：" + str(choice))
					old.erase(field)
					next.erase(field)
			elif catalog == "progression" and old.has("drops"):
				var drops: Dictionary = old.drops
				var new_drops: Dictionary = next.get("drops", {})
				if not _unchanged_subset(drops, new_drops): return _failure("原敌人掉落发生变化，暂不能自动迁移：" + id)
				if not _same(drops, new_drops):
					var pending := _pending_encounter(snapshot.world_state, id)
					if not pending.is_empty():
						return _failure("「%s」还有未领取战利品；新版改变了它的掉落，请先在旧版本腾出背包并领取，再保存迁移" % str(source.enemies.get(id, {}).get("name", id)))
					changes.append("%s：后续击败可获得新增掉落；已结算的战利品保持原样。" % str(target.enemies.get(id, {}).get("name", id)))
				old.erase("drops")
				next.erase("drops")
			if not _same(old, next): return _failure("原有数值或规则发生变化，暂不能自动迁移：" + catalog + "/" + id)
		additions += after.size() - before.size()
	if additions > 0: changes.append("新增 %d 项可用内容；不会自动发放物品、职业或技能。" % additions)
	var candidate := snapshot.duplicate(true)
	var old_shops: Dictionary = source.world_catalog("shops")
	var new_shops: Dictionary = target.world_catalog("shops")
	var shop_error: String = Economy._validate_definitions(new_shops, target)
	if not shop_error.is_empty(): return _failure("新版本商店目录无效：" + shop_error)
	for id: String in old_shops:
		if not new_shops.has(id): return _failure("新版本移除了原商店：" + id)
		var old: Dictionary = old_shops[id].duplicate(true)
		var next: Dictionary = new_shops[id].duplicate(true)
		var goods: Dictionary = old.goods
		var new_goods: Dictionary = next.goods
		var old_version := int(old.catalog_version)
		var new_version := int(next.catalog_version)
		if new_version < old_version: return _failure("不能降低商店目录版本：" + str(old.name))
		for item: String in goods:
			if not new_goods.has(item): return _failure("新版本移除了原商品：" + item)
			var old_good: Dictionary = goods[item].duplicate(true)
			var next_good: Dictionary = new_goods[item].duplicate(true)
			for field: String in ["buy_price", "sell_price"]:
				if old_good.has(field) != next_good.has(field): return _failure("原商品交易方向改变，暂不能自动迁移：" + item)
				if old_good.has(field):
					if not _same(old_good[field], next_good[field]):
						if new_version <= old_version: return _failure("商品改价必须提升商店目录版本：" + str(old.name))
						var definition: Dictionary = target.items.get(item, target.weapons.get(item, target.equipment.get(item, {})))
						changes.append("%s · %s：%s %d → %d 铜币。" % [str(old.name), str(definition.get("name", item)), "买入价" if field == "buy_price" else "卖出价", int(old_good[field]), int(next_good[field])])
					old_good.erase(field)
					next_good.erase(field)
			if not _same(old_good, next_good): return _failure("原商品初始库存或规则改变，暂不能自动迁移：" + item)
		old.erase("goods")
		next.erase("goods")
		old.erase("catalog_version")
		next.erase("catalog_version")
		if not _same(old, next): return _failure("原商店规则改变，暂不能自动迁移：" + id)
		var key: String = Economy.SHOP_PREFIX + id
		if candidate.world_state.objects.has(key):
			candidate.world_state.objects[key].catalog_version = new_version
		if new_version > old_version:
			changes.append("%s：商店目录 %d → %d；余额、已有物品和剩余库存不变，不补退旧交易差价。" % [str(old_shops[id].name), old_version, new_version])
		var extra := new_goods.size() - goods.size()
		if extra > 0:
			for item: String in new_goods:
				if not goods.has(item) and candidate.world_state.objects.has(key):
					candidate.world_state.objects[key].stock[item] = new_goods[item].stock
			changes.append("%s：增加 %d 种商品或收购项，已购商品的剩余库存不变。" % [str(old_shops[id].name), extra])
	if new_shops.size() > old_shops.size(): changes.append("新增 %d 家商店，原商店库存保持原样。" % (new_shops.size() - old_shops.size()))
	var old_quests: Dictionary = source.world_catalog("quests")
	var new_quests: Dictionary = target.world_catalog("quests")
	for id: String in old_quests:
		if not new_quests.has(id): return _failure("新版本移除了原任务：" + id)
		var old: Dictionary = old_quests[id].duplicate(true)
		var next: Dictionary = new_quests[id].duplicate(true)
		var rewards: Dictionary = old.rewards.get("items", {})
		var new_rewards: Dictionary = next.get("rewards", {}).get("items", {})
		if not _unchanged_subset(rewards, new_rewards): return _failure("原任务奖励改变，暂不能自动迁移：" + str(old.title))
		if not _same(rewards, new_rewards):
			var rewarded: bool = snapshot.world_state.objects.get("quest." + id, {}).get("status", "") == "rewarded"
			changes.append("%s：%s" % [str(old.title), "原奖励已经领取，新增奖励不会补发。" if rewarded else "领取时将按新版给予新增奖励；当前任务进度不变。"])
		old.rewards.erase("items")
		next.rewards.erase("items")
		if not _same(old, next): return _failure("原任务目标、前置或经验规则改变，暂不能自动迁移：" + id)
	if new_quests.size() > old_quests.size(): changes.append("新增 %d 项任务，原任务进度保持原样。" % (new_quests.size() - old_quests.size()))
	candidate.content_set = target.identity()
	var target_validator := Repository.new(OS.get_temp_dir().path_join("mosslight-read-only-validation"), target)
	reason = target_validator.validate_snapshot(candidate)
	if not reason.is_empty(): return _failure("新版本不能完整保留这份冒险：" + reason)
	changes.push_front("保留等级、经验、职业、背包装备、技能、当前生命与体力、能量、冷却和全部已记录进度。")
	changes.append("只在空槽创建新副本。旧冒险和备份保留，可用原版本继续；新副本进度不会写回旧档。")
	return {"ok": true, "error": "", "snapshot": candidate, "changes": changes}

static func _pending_encounter(world: Dictionary, enemy: String) -> String:
	var catalog: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/encounters.json"))
	if not catalog is Dictionary: return "unknown"
	for id: String in catalog.get("encounters", {}):
		if catalog.encounters[id].enemy_id == enemy and world.objects.get(id, {}).get("phase", "") == "pending": return id
	return ""

static func _context_data(context: RefCounted) -> Dictionary:
	var result := {"identity": context.identity(), "catalogs": {}, "worlds": {}}
	for catalog: String in Bundle.CATALOGS: result.catalogs[catalog] = context.get(catalog).duplicate(true)
	for catalog: String in Bundle.WORLD_CATALOGS: result.worlds[catalog] = context.world_catalog(catalog)
	return result

static func _unchanged_subset(before: Dictionary, after: Dictionary) -> bool:
	for key in before:
		if not after.has(key) or not _same(before[key], after[key]): return false
	return true

static func _same(a: Variant, b: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(a)) == JSON.parse_string(JSON.stringify(b))

func _target_label() -> String:
	var release := Release.metadata()
	var result: String = str(release.release_id) + " " + str(release.version) if not release.is_empty() else "当前开发版本"
	for pack: Dictionary in _repository.database.identity().get("packs", []): result += " · " + str(pack.pack_id) + " " + str(pack.version)
	return result

static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "error": reason, "snapshot": {}, "metadata": {}}
