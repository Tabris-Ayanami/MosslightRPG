extends RefCounted
## Authoritative, synchronous trades against the canonical adventure inventory.
## UI/session distance checks belong to the game; prices and ownership never do.

signal changed

const WorldState = preload("res://rpg/world_state.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const Readiness = preload("res://rpg/interaction_readiness.gd")
const DEFAULT_PATH := "res://data/world/shops.json"
const WALLET := "economy.wallet"
const SHOP_PREFIX := "economy.shop."
const VERSION := 1
const MAX_BALANCE := 2147483647
const MAX_QUANTITY := 1000000
const MAX_SHOPS := 64
const MAX_GOODS := 128
const MAX_QUOTES := 64

var last_error := ""
var _world: RefCounted
var _actor: Node
var _definitions: Dictionary = {}
var _quotes: Dictionary = {}
var _busy := false

func setup(world: RefCounted, canonical_actor: Node, definitions: Dictionary = {}) -> bool:
	if _busy or (is_instance_valid(_world) and Guard.busy(_world)) or (is_instance_valid(world) and Guard.busy(world)):
		return _reject("冒险状态更新中，暂时不能切换商店")
	if not world is WorldState or not is_instance_valid(canonical_actor):
		return _reject("交易缺少世界状态或冒险角色")
	for component in ["inventory", "loadout", "resources", "combat"]:
		if not is_instance_valid(canonical_actor.get(component)):
			return _reject("交易角色缺少组件：" + component)
	if canonical_actor.loadout.sandbox_mode:
		return _reject("测试角色不能使用冒险商店")
	var incoming: Dictionary = definitions.duplicate(true) if not definitions.is_empty() else _default_definitions(canonical_actor.inventory.database)
	var reason := _validate_definitions(incoming, canonical_actor.inventory.database)
	if reason.is_empty(): reason = _validate_records(world.export_state(), incoming)
	if not reason.is_empty(): return _reject(reason)
	_disconnect()
	_world = world
	_actor = canonical_actor
	_definitions = incoming
	_actor.inventory.changed.connect(_on_changed)
	_actor.loadout.changed.connect(_on_changed)
	_world.object_changed.connect(_on_object_changed)
	_quotes.clear()
	last_error = ""
	return true

func definition(shop_id: String) -> Dictionary:
	return _definitions.get(shop_id, {}).duplicate(true)

func balance() -> int:
	if not _usable(): return 0
	var value: Variant = _world.get_object(WALLET).get("balance", 0)
	return int(value) if _integer(value, 0, MAX_BALANCE) else 0

func entries(shop_id: String, mode := "buy") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _usable() or not _definitions.has(shop_id) or mode not in ["buy", "sell"]: return result
	var snapshot: Dictionary = _world.export_state()
	if not _validate_records(snapshot, _definitions).is_empty(): return result
	var stock := _stock(shop_id, snapshot)
	for item: String in _definitions[shop_id].goods:
		var goods: Dictionary = _definitions[shop_id].goods[item]
		if not goods.has(mode + "_price"): continue
		var owned: int = _actor.inventory.count(item)
		if mode == "sell" and owned <= 0: continue
		var data: Dictionary = _actor.inventory.definition(item)
		var price: int = int(goods[mode + "_price"])
		var sellable: int = maxi(0, owned - _actor.inventory.equipped_count(item))
		var available: int = mini(int(stock[item]), MAX_QUANTITY - owned) if mode == "buy" else sellable
		var funds: int = balance() if mode == "buy" else MAX_BALANCE - balance()
		available = maxi(0, mini(available, int(funds / price)))
		var plan := _plan(shop_id, item, 1, mode)
		if not plan.ok: available = 0
		var category := str(data.get("category", ""))
		var catalog := "weapons" if category == "weapon" else ("equipment" if category == "equipment" else "items")
		result.append({"id": item, "name": str(data.get("name", item)), "description": str(data.get("description", "")),
			"price": price, "stock": int(stock[item]), "owned": owned, "available": available, "sellable": sellable,
			"reason": str(plan.error), "category": category, "definition": data.duplicate(true),
			"icon": _actor.inventory.database.get_content_icon(catalog, item)})
	return result

func quote_buy(shop_id: String, item: String, quantity: Variant = 1) -> Dictionary:
	return _quote(shop_id, item, quantity, "buy")

func quote_sell(shop_id: String, item: String, quantity: Variant = 1) -> Dictionary:
	return _quote(shop_id, item, quantity, "sell")

func _quote(shop_id: String, item: String, quantity: Variant, mode: String) -> Dictionary:
	var plan := _plan(shop_id, item, quantity, mode)
	last_error = plan.error
	var quote := {"ok": plan.ok, "error": plan.error, "shop_id": shop_id, "item_id": item,
		"quantity": int(quantity) if _integer(quantity, 1, MAX_QUANTITY) else 0, "mode": mode,
		"revision": _revision(), "price": int(plan.get("price", 0)), "total": int(plan.get("total", 0))}
	if not plan.ok: return quote
	# An opaque receipt identifies a detached service-owned quote. No client price
	# or edited field is trusted, even if its arithmetic happens to be plausible.
	var token := Crypto.new().generate_random_bytes(24).hex_encode()
	quote["token"] = token
	if _quotes.size() >= MAX_QUOTES: _quotes.erase(_quotes.keys()[0])
	_quotes[token] = {"quote": quote.duplicate(true), "fingerprint": _fingerprint()}
	return quote

func trade(quote: Dictionary) -> bool:
	var ready := _readiness_error()
	if not ready.is_empty(): return _reject(ready)
	var token: Variant = quote.get("token")
	if not token is String or not _quotes.has(token): return _reject("报价无效或已经使用，请重新选择数量")
	var issued: Dictionary = _quotes[token]
	if quote != issued.quote: return _reject("报价内容已改变，请重新报价")
	if issued.fingerprint != _fingerprint(): return _reject("物品、余额或库存已改变，请重新报价")
	var plan := _plan(quote.shop_id, quote.item_id, quote.quantity, quote.mode)
	if not plan.ok: return _reject(plan.error)
	if quote.revision != _revision() or quote.price != plan.price or quote.total != plan.total:
		return _reject("报价已过期，请重新报价")
	var owner := "economy:" + str(get_instance_id())
	if not Guard.acquire(_world, owner): return _reject("冒险状态更新中，请稍后交易")
	_busy = true
	# World import is silent and all possibly failing validation is already done.
	# No signal, await, or callback may appear between these two assignments.
	if not _world.import_state(plan.world):
		_busy = false
		Guard.release(_world, owner)
		return _reject("交易状态无法保存：" + _world.last_error)
	_actor.inventory.stacks = plan.stacks
	_actor.inventory.last_error = ""
	_quotes.clear()
	last_error = ""
	_actor.inventory.changed.emit()
	_world.object_changed.emit(WALLET)
	_world.object_changed.emit(SHOP_PREFIX + str(quote.shop_id))
	changed.emit()
	# Observers can query or save the complete state; mutations stay locked until
	# every observer has returned, including another service's changed callback.
	Guard.release(_world, owner)
	_busy = false
	last_error = ""
	return true

func validate_state(snapshot: Dictionary) -> String:
	if _definitions.is_empty(): return "商店目录尚未就绪"
	return _validate_records(snapshot, _definitions)

## Repository entry point: does not bind an actor, grant money, or mutate input.
static func validate_snapshot(world_snapshot: Dictionary, database: RefCounted) -> String:
	var definitions := _default_definitions(database)
	var reason := _validate_definitions(definitions, database)
	return reason if not reason.is_empty() else _validate_records(world_snapshot, definitions)

func refresh() -> void:
	if _busy: return
	_quotes.clear()
	if _usable(): changed.emit()

func dispose() -> void:
	if _busy or (is_instance_valid(_world) and Guard.busy(_world)): return
	_disconnect()
	_quotes.clear()
	_definitions.clear()
	_world = null
	_actor = null
	last_error = ""

func _plan(shop_id: String, item: String, quantity: Variant, mode: String) -> Dictionary:
	var reason := _readiness_error()
	if not reason.is_empty(): return _failure(reason)
	if not _integer(quantity, 1, MAX_QUANTITY): return _failure("交易数量必须是 1 至 1000000 的整数")
	if mode not in ["buy", "sell"] or not _definitions.has(shop_id): return _failure("商店或交易方向无效")
	var shop: Dictionary = _definitions[shop_id]
	if not shop.goods.has(item) or not shop.goods[item].has(mode + "_price"): return _failure("商人不经营这项交易")
	var world: Dictionary = _world.export_state()
	reason = _validate_records(world, _definitions)
	if not reason.is_empty(): return _failure(reason)
	reason = _inventory_error()
	if not reason.is_empty(): return _failure(reason)
	var amount := int(quantity)
	var price := int(shop.goods[item][mode + "_price"])
	if price > int(MAX_BALANCE / amount): return _failure("交易总价超出上限")
	var total := price * amount
	var funds := balance()
	var revision := _revision()
	if revision >= MAX_BALANCE: return _failure("交易记录已达上限")
	var stock := _stock(shop_id, world)
	var stacks: Dictionary = _actor.inventory.stacks.duplicate(true)
	var owned: int = _actor.inventory.count(item)
	if mode == "buy":
		if int(stock[item]) < amount: return _failure("商店库存不足")
		if funds < total: return _failure("铜币不足")
		if owned > MAX_QUANTITY - amount: return _failure("背包物品数量已达上限")
		stacks[item] = owned + amount
		stock[item] = int(stock[item]) - amount
		funds -= total
	else:
		var data: Dictionary = _actor.inventory.definition(item)
		if not data.get("discardable", true) or data.get("category", "") in ["quest", "quest_item"]:
			return _failure("这件物品不能出售")
		if owned - _actor.inventory.equipped_count(item) < amount: return _failure("没有足够的未装备物品可出售")
		if funds > MAX_BALANCE - total: return _failure("铜币已达上限")
		if owned == amount: stacks.erase(item)
		else: stacks[item] = owned - amount
		funds += total
	world.objects[WALLET] = {"version": VERSION, "balance": funds, "revision": revision + 1}
	world.objects[SHOP_PREFIX + shop_id] = {"version": VERSION, "catalog_version": int(shop.catalog_version), "stock": stock}
	reason = _validate_records(world, _definitions)
	if not reason.is_empty(): return _failure("交易无法保存：" + reason)
	return {"ok": true, "error": "", "world": world, "stacks": stacks, "price": price, "total": total}

func _inventory_error() -> String:
	for id in _actor.inventory.stacks:
		if not id is String or _actor.inventory.definition(id).is_empty() or not _integer(_actor.inventory.stacks[id], 1, MAX_QUANTITY):
			return "背包包含无效物品或超限数量"
	var used: Dictionary = {}
	for group in _actor.loadout.sets:
		var id: String = group.get("weapon", "")
		if not id.is_empty(): used[id] = int(used.get(id, 0)) + 1
	for id: String in _actor.loadout.equipment.values():
		if not id.is_empty(): used[id] = int(used.get(id, 0)) + 1
	for id in used:
		if _actor.inventory.count(id) < int(used[id]): return "已装备数量超过实际持有数量"
	return ""

func _readiness_error() -> String:
	if not _usable(): return "当前冒险商店尚未就绪"
	if _busy or Guard.busy(_world): return "冒险状态更新中，请稍后交易"
	if _actor.loadout.sandbox_mode: return "测试角色不能使用冒险商店"
	if _actor.get("control_mode") == "none": return "附身或失去控制时不能交易，请先返回本体"
	var form: Variant = _actor.get("form")
	if is_instance_valid(form) and form.active: return "请先恢复原形再交易"
	if not Readiness.can_manage(_actor): return "当前状态不能交易，请在存活且动作结束后重试"
	return ""

func _revision() -> int:
	if not _usable(): return 0
	var value: Variant = _world.get_object(WALLET).get("revision", 0)
	return int(value) if _integer(value, 0, MAX_BALANCE) else 0

func _stock(shop_id: String, snapshot: Dictionary) -> Dictionary:
	var record: Dictionary = snapshot.objects.get(SHOP_PREFIX + shop_id, {})
	if not record.is_empty(): return record.stock.duplicate(true)
	var result: Dictionary = {}
	for item in _definitions[shop_id].goods: result[item] = int(_definitions[shop_id].goods[item].stock)
	return result

func _fingerprint() -> String:
	return JSON.stringify([_world.export_state(), _actor.inventory.export_state(), _actor.loadout.export_state()]).sha256_text()

func _usable() -> bool:
	return is_instance_valid(_world) and is_instance_valid(_actor) and is_instance_valid(_actor.inventory) and is_instance_valid(_actor.loadout)

func _disconnect() -> void:
	if is_instance_valid(_actor):
		for component in [_actor.inventory, _actor.loadout]:
			if is_instance_valid(component) and component.changed.is_connected(_on_changed): component.changed.disconnect(_on_changed)
	if is_instance_valid(_world) and _world.object_changed.is_connected(_on_object_changed): _world.object_changed.disconnect(_on_object_changed)

func _on_changed() -> void:
	if not _busy: refresh()

func _on_object_changed(id: String) -> void:
	if id.begins_with("economy."): _on_changed()

func _reject(reason: String) -> bool:
	last_error = reason
	return false

static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "error": reason}

static func _default_definitions(database: RefCounted) -> Dictionary:
	return database.world_catalog("shops") if is_instance_valid(database) else {}

static func _validate_definitions(definitions: Dictionary, database: RefCounted) -> String:
	if not is_instance_valid(database) or definitions.is_empty() or definitions.size() > MAX_SHOPS: return "商店目录无效"
	for id in definitions:
		var shop: Variant = definitions[id]
		if not _id(id) or not shop is Dictionary or not _keys(shop, ["id", "name", "description", "currency", "catalog_version", "goods"]): return "商店定义字段无效"
		if shop.id != id or not _text(shop.name, 80) or not _text(shop.description, 1024) or shop.currency != "coin" or not _integer(shop.catalog_version, 1, MAX_BALANCE): return "商店身份、说明或版本无效"
		if not shop.goods is Dictionary or shop.goods.is_empty() or shop.goods.size() > MAX_GOODS: return "商品目录数量无效"
		for item in shop.goods:
			var goods: Variant = shop.goods[item]
			if not _id(item) or item == "magic_candy" or not _item_exists(database, item): return "商品引用无效或属于测试物品"
			if not goods is Dictionary or not _keys(goods, ["stock"], ["buy_price", "sell_price"]) or not _integer(goods.stock, 0, MAX_QUANTITY): return "商品字段或库存无效"
			if not goods.has("buy_price") and not goods.has("sell_price"): return "商品至少需要一个交易方向"
			for field in ["buy_price", "sell_price"]:
				if goods.has(field) and not _integer(goods[field], 1, MAX_BALANCE): return "商品价格必须是正整数"
			if not goods.has("buy_price") and goods.stock != 0: return "只收购的商品不能有货架库存"
			if goods.has("buy_price") and goods.has("sell_price") and goods.sell_price > goods.buy_price: return "收购价不能高于售价"
	# Default commerce has no intentional arbitrage. Validate across merchants too.
	for shop in definitions.values():
		for item in shop.goods:
			if not shop.goods[item].has("sell_price"): continue
			for other in definitions.values():
				if other.goods.has(item) and other.goods[item].has("buy_price") and shop.goods[item].sell_price > other.goods[item].buy_price: return "跨商店收购价高于售价"
	return ""

static func _validate_records(snapshot: Dictionary, definitions: Dictionary) -> String:
	var reason: String = WorldState.new().validate_state(snapshot)
	if not reason.is_empty(): return reason
	var objects: Dictionary = snapshot.objects
	if objects.has(WALLET):
		var wallet: Dictionary = objects[WALLET]
		if not _keys(wallet, ["version", "balance", "revision"]) or not _integer(wallet.version, VERSION, VERSION) or not _integer(wallet.balance, 0, MAX_BALANCE) or not _integer(wallet.revision, 0, MAX_BALANCE): return "钱包记录无效"
	for key: String in objects:
		if not key.begins_with("economy.") or key == WALLET: continue
		if not key.begins_with(SHOP_PREFIX): return "未知经济记录"
		var id := key.trim_prefix(SHOP_PREFIX)
		if not definitions.has(id) or not objects.has(WALLET): return "商店存档缺少目录或钱包"
		var record: Dictionary = objects[key]
		var shop: Dictionary = definitions[id]
		if not _keys(record, ["version", "catalog_version", "stock"]) or not _integer(record.version, VERSION, VERSION) or not _integer(record.catalog_version, int(shop.catalog_version), int(shop.catalog_version)) or not record.stock is Dictionary: return "商店存档字段或版本无效"
		if record.stock.size() != shop.goods.size(): return "商店存档库存字段不完整"
		for item in record.stock:
			if not shop.goods.has(item) or not _integer(record.stock[item], 0, int(shop.goods[item].stock)): return "商店存档库存无效"
	return ""

static func _keys(value: Dictionary, required: Array, optional: Array = []) -> bool:
	for key in required:
		if not value.has(key): return false
	for key in value:
		if key not in required and key not in optional: return false
	return true

static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and value >= minimum and value <= maximum

static func _id(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 96: return false
	for index in range(value.length()):
		var code: int = value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code in [45, 46, 58, 95]): return false
	return true

static func _text(value: Variant, maximum: int) -> bool:
	return value is String and not value.strip_edges().is_empty() and value.length() <= maximum

static func _item_exists(database: RefCounted, id: String) -> bool:
	return database.items.has(id) or database.weapons.has(id) or database.equipment.has(id)
