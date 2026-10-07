extends RefCounted
## Pure extension of existing acquisition catalogs. No runtime state is read or
## granted here; existing shop, quest and enemy transactions remain authoritative.
const MAX_QUANTITY := 1000000
const MAX_PRICE := 2147483647
const INVENTORY_CATALOGS := ["items", "weapons", "equipment"]
const ROUTES := ["shops", "quests", "enemy_drops"]

static func apply(plan: Dictionary, catalogs: Dictionary, worlds: Dictionary, pack_entries: Array) -> Dictionary:
	if not _keys(plan, ["format_version", "world_base_sha256", "shops", "quests", "enemy_drops"]) or not _integer(plan.get("format_version"), 1, 1):
		return _failure("获取途径字段或版本无效")
	var hashes: Variant = plan.world_base_sha256
	if not hashes is Dictionary or not _keys(hashes, ["shops", "quests"]): return _failure("获取途径世界目录指纹无效")
	for name in ["shops", "quests"]:
		if not _match(hashes[name], "^[a-f0-9]{64}$"): return _failure("获取途径世界目录指纹无效：" + name)
		if not worlds.get(name) is Dictionary: return _failure("缺少基础世界目录：" + name)
	for name in INVENTORY_CATALOGS + ["enemies", "progression"]:
		if not catalogs.get(name) is Dictionary: return _failure("缺少基础内容目录：" + name)
	if worlds.shops.is_empty() or worlds.shops.size() > 64 or worlds.quests.is_empty() or worlds.quests.size() > 128: return _failure("基础世界目录数量无效")
	if pack_entries.is_empty() or pack_entries.size() > 128: return _failure("获取途径所属内容包数量无效")
	var packs: Dictionary = {}
	for entry in pack_entries:
		if not entry is Dictionary or not _match(entry.get("pack_id"), "^[a-z][a-z0-9_]{1,47}$") or packs.has(entry.pack_id): return _failure("获取途径所属内容包无效或重复")
		packs[entry.pack_id] = true
	for route: String in ROUTES:
		var maximum := 64 if route == "shops" else (128 if route == "quests" else 16384)
		if not plan[route] is Dictionary or plan[route].size() > maximum: return _failure("获取途径目录数量无效：" + route)
	if plan.shops.is_empty() and plan.quests.is_empty() and plan.enemy_drops.is_empty(): return _failure("获取途径扩展不能为空")
	var next_catalogs := catalogs.duplicate(true)
	var next_worlds := worlds.duplicate(true)
	for route: String in ROUTES:
		for target in plan[route]:
			var additions: Variant = plan[route][target]
			if not _target_id(target, route) or not additions is Dictionary or additions.is_empty() or additions.size() > (128 if route == "shops" else 32): return _failure("获取途径目标或条目数量无效：" + str(target))
			var destination: Dictionary
			match route:
				"shops":
					if not next_worlds.shops.get(target) is Dictionary or not next_worlds.shops[target].get("goods") is Dictionary: return _failure("未知商店获取目标：" + target)
					destination = next_worlds.shops[target].goods
				"quests":
					if not next_worlds.quests.get(target) is Dictionary or not next_worlds.quests[target].get("rewards") is Dictionary: return _failure("未知任务获取目标：" + target)
					var rewards: Dictionary = next_worlds.quests[target].rewards
					if not rewards.get("items", {}) is Dictionary: return _failure("任务物品奖励结构无效：" + target)
					if not rewards.has("items"): rewards.items = {}
					destination = rewards.items
				"enemy_drops":
					if not next_catalogs.enemies.get(target) is Dictionary or not next_catalogs.progression.get(target) is Dictionary or next_catalogs.progression[target].get("id") != target: return _failure("未知敌人奖励目标：" + target)
					var reward: Dictionary = next_catalogs.progression[target]
					if not reward.get("drops", {}) is Dictionary: return _failure("敌人物品奖励结构无效：" + target)
					if not reward.has("drops"): reward.drops = {}
					destination = reward.drops
			for item in additions:
				var item_error := _addition_item_error(item, catalogs, packs)
				if not item_error.is_empty(): return _failure(item_error)
				if destination.has(item): return _failure("获取途径不能覆盖已有条目：" + target + "/" + item)
				if route == "shops":
					var goods_error := _goods_error(additions[item])
					if not goods_error.is_empty(): return _failure(target + "/" + item + "：" + goods_error)
					destination[item] = additions[item].duplicate(true)
				else:
					if not _integer(additions[item], 1, MAX_QUANTITY): return _failure("获取物品数量无效：" + item)
					destination[item] = int(additions[item])
			if destination.size() > (128 if route == "shops" else 32): return _failure("合并后获取途径条目超限：" + target)
	# Check the complete resulting market, including routes contributed by other
	# packs. A sell offer must not exceed any buy offer for the same item.
	var cheapest: Dictionary = {}
	var highest: Dictionary = {}
	for shop in next_worlds.shops.values():
		if not shop is Dictionary or not shop.get("goods") is Dictionary or shop.goods.is_empty() or shop.goods.size() > 128: return _failure("合并后商店商品目录无效")
		for item in shop.goods:
			var goods_error := _goods_error(shop.goods[item])
			if not goods_error.is_empty(): return _failure(str(item) + "：" + goods_error)
			var goods: Dictionary = shop.goods[item]
			if goods.has("buy_price"): cheapest[item] = mini(int(cheapest.get(item, MAX_PRICE)), int(goods.buy_price))
			if goods.has("sell_price"): highest[item] = maxi(int(highest.get(item, 0)), int(goods.sell_price))
	for item in highest:
		if cheapest.has(item) and highest[item] > cheapest[item]: return _failure("跨商店收购价高于售价：" + str(item))
	for quest in next_worlds.quests.values():
		if not quest is Dictionary or not quest.get("rewards") is Dictionary or not quest.rewards.get("items", {}) is Dictionary or quest.rewards.get("items", {}).size() > 32: return _failure("合并后任务奖励目录无效")
	return {"ok": true, "error": "", "catalogs": next_catalogs, "world_catalogs": next_worlds}

static func _addition_item_error(item: Variant, catalogs: Dictionary, packs: Dictionary) -> String:
	if not item is String or item.length() > 96 or not _match(item, "^[a-z][a-z0-9_]{1,47}:[a-z][a-z0-9_]{0,95}$") or not packs.has(item.get_slice(":", 0)):
		return "获取物品必须属于已加载内容包且 ID 不超过 96 字符：" + str(item)
	var matches := 0
	for name in INVENTORY_CATALOGS:
		if catalogs[name].has(item):
			if not catalogs[name][item] is Dictionary or catalogs[name][item].get("id") != item: return "获取物品定义无效：" + item
			matches += 1
	return "" if matches == 1 else "获取物品必须在物品、武器、护具目录中唯一存在：" + item

static func _goods_error(goods: Variant) -> String:
	if not goods is Dictionary or not _keys(goods, ["stock"], ["buy_price", "sell_price"]) or not _integer(goods.get("stock"), 0, MAX_QUANTITY): return "商品字段或库存无效"
	if not goods.has("buy_price") and not goods.has("sell_price"): return "商品至少需要一个交易方向"
	for field in ["buy_price", "sell_price"]:
		if goods.has(field) and not _integer(goods[field], 1, MAX_PRICE): return "商品价格必须是正整数"
	if not goods.has("buy_price") and goods.stock != 0: return "只收购的商品不能有货架库存"
	if goods.has("buy_price") and goods.has("sell_price") and goods.sell_price > goods.buy_price: return "收购价不能高于售价"
	return ""

static func _keys(value: Dictionary, required: Array, optional: Array = []) -> bool:
	for key in required:
		if not value.has(key): return false
	for key in value:
		if key not in required and key not in optional: return false
	return true

static func _target_id(value: Variant, route: String) -> bool:
	if not value is String or value.length() > 96: return false
	# QuestService and WorldState accept '/' in quest IDs; shop IDs do not.
	if route == "quests": return _match(value, "^[A-Za-z0-9_.:/-]+$")
	if route == "enemy_drops": return _match(value, "^[A-Za-z][A-Za-z0-9_]*(?::[a-z][a-z0-9_]*)?$")
	return _match(value, "^[A-Za-z0-9_.:-]+$")

static func _match(value: Variant, pattern: String) -> bool:
	if not value is String: return false
	var expression := RegEx.new()
	return expression.compile(pattern) == OK and expression.search(value) != null

static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and value >= minimum and value <= maximum

static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "error": reason, "catalogs": {}, "world_catalogs": {}}
