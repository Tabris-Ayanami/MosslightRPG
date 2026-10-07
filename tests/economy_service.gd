extends SceneTree

const Economy = preload("res://rpg/economy_service.gd")
const State = preload("res://rpg/world_state.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const Database = preload("res://combat/combat_database.gd")
const Inventory = preload("res://rpg/inventory_component.gd")
const Progression = preload("res://rpg/progression_component.gd")
const Loadout = preload("res://combat/loadout_component.gd")
const Stats = preload("res://combat/stats_component.gd")
const Resources = preload("res://combat/resource_component.gd")
const SHOP := "village_supply"

class FixtureCombat extends Node:
	var actor: Node
	var state := "NORMAL"
	var base_poise := 50.0
	var current_poise := 50.0
	var runner: Node
	var switch_time := 0.0
	func can_start() -> bool: return state == "NORMAL"
	func max_poise() -> float: return base_poise
	func context() -> Dictionary:
		var values: Dictionary = {}
		for key in Stats.IDS + ["Armor"]: values[key] = actor.stats.get_final_stat(key)
		return {"stats": values, "level": actor.loadout.level, "proficiencies": actor.loadout.proficiencies}

class Fixture extends Node:
	var stats: Node
	var resources: Node
	var loadout: Node
	var combat: Node
	var inventory: Node
	var progression: Node
	var control_mode := "human"
	var form: Node
	var game: Node

var checks := 0
var failures: Array[String] = []
var actors: Array[Node] = []
var services: Array[RefCounted] = []
var db: RefCounted

func _initialize() -> void: call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func fixture() -> Dictionary:
	var actor := Fixture.new()
	root.add_child(actor)
	actors.append(actor)
	actor.stats = Stats.new()
	actor.resources = Resources.new()
	actor.loadout = Loadout.new()
	actor.combat = FixtureCombat.new()
	actor.combat.actor = actor
	actor.inventory = Inventory.new()
	actor.progression = Progression.new()
	for component in [actor.stats, actor.resources, actor.loadout, actor.combat, actor.inventory, actor.progression]: actor.add_child(component)
	actor.loadout.setup(actor, db)
	actor.inventory.setup(actor, db)
	actor.progression.setup(actor, db, actor.inventory)
	actor.loadout.configure_progression(actor.inventory, actor.progression)
	actor.stats.changed.connect(actor.loadout.refresh_resources)
	actor.loadout._rebuild(true)
	actor.progression.choose_career("warrior")
	var world := State.new()
	var service := Economy.new()
	services.append(service)
	verify(service.setup(world, actor), "交易服务绑定真实背包/配装组件")
	return {"actor": actor, "world": world, "service": service}

func funds(f: Dictionary, amount: int, revision := 0) -> void:
	var snapshot: Dictionary = f.world.export_state()
	snapshot.objects[Economy.WALLET] = {"version": 1, "balance": amount, "revision": revision}
	verify(f.world.import_state(snapshot), "测试钱包状态注入且仅驻留内存")
	f.service.refresh()

func snapshot(f: Dictionary) -> Array:
	return [f.world.export_state(), f.actor.inventory.export_state(), f.actor.loadout.export_state()]

func rejected(f: Dictionary, quote: Dictionary, label: String) -> void:
	var before := snapshot(f)
	var signals: Array = []
	var callback := func(): signals.append(true)
	var object_callback := func(_id: String): signals.append(true)
	f.service.changed.connect(callback)
	f.actor.inventory.changed.connect(callback)
	f.world.object_changed.connect(object_callback)
	verify(not f.service.trade(quote) and snapshot(f) == before and signals.is_empty(), label)
	f.service.changed.disconnect(callback)
	f.actor.inventory.changed.disconnect(callback)
	f.world.object_changed.disconnect(object_callback)

func run() -> void:
	db = Database.new()
	verify(db.errors.is_empty(), "真实内容目录有效")
	_round_trip_and_observers()
	_quotes_and_limits()
	_equipment_and_quickslots()
	_state_validation_and_lifecycle()
	_catalog_validation()
	_capacity_and_readiness()
	for service in services: service.dispose()
	services.clear()
	for actor in actors: actor.free()
	actors.clear()
	print("ECONOMY_SERVICE_RESULT checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _round_trip_and_observers() -> void:
	var f := fixture()
	var before := snapshot(f)
	verify(f.service.balance() == 0 and f.service.entries(SHOP).size() == 4, "旧存档零余额且只售四种普通补给")
	verify(snapshot(f) == before and not f.service.quote_buy(SHOP, "healing_potion", 1).ok, "查询和失败报价不创建记录或赠送铜币")
	verify(not f.service.quote_buy(SHOP, "magic_candy").ok and not f.service.quote_sell(SHOP, "magic_candy").ok, "测试糖果不能买卖")
	var copy: Dictionary = f.service.definition(SHOP)
	copy.goods.healing_potion.buy_price = 1
	verify(f.service.definition(SHOP).goods.healing_potion.buy_price == 20, "目录查询返回深拷贝")
	f.actor.inventory.add_item("iron_longsword")
	var quote: Dictionary = f.service.quote_sell(SHOP, "iron_longsword", 1)
	var observations: Array[bool] = []
	var observe := func():
		observations.append(f.service.balance() == 30 and f.actor.inventory.count("iron_longsword") == 1 and f.world.get_object(Economy.WALLET).revision == 1)
		observations.append(not f.service.trade(quote) and not Guard.acquire(f.world, "other.service"))
	var observe_object := func(_id: String): observe.call()
	f.actor.inventory.changed.connect(observe)
	f.world.object_changed.connect(observe_object)
	f.service.changed.connect(observe)
	verify(quote.ok and f.service.trade(quote), "出售多余长剑获得目录铜币")
	verify(observations.size() == 8 and observations.all(func(value): return value), "所有最终信号只观察完整交易且跨服务重入被锁住")
	f.actor.inventory.changed.disconnect(observe)
	f.world.object_changed.disconnect(observe_object)
	f.service.changed.disconnect(observe)
	verify(not Guard.busy(f.world), "通知结束后释放共享锁")
	rejected(f, quote, "成功报价不可重放")
	var potions: int = f.actor.inventory.count("healing_potion")
	quote = f.service.quote_buy(SHOP, "healing_potion")
	verify(quote.ok and quote.price == 20 and quote.total == 20 and f.service.trade(quote), "权威价格购买补给")
	verify(f.service.balance() == 10 and f.actor.inventory.count("healing_potion") == potions + 1 and f.world.get_object(Economy.SHOP_PREFIX + SHOP).stock.healing_potion == 11, "余额物品库存整笔更新")
	var saved: Array = snapshot(f)
	var restored := fixture()
	verify(restored.world.import_state(saved[0]), "持久世界状态导入")
	restored.actor.inventory.import_state(saved[1])
	restored.actor.loadout.import_state(saved[2])
	restored.service.refresh()
	verify(snapshot(restored) == saved and restored.service.balance() == 10, "世界背包配装往返不重复发钱或补库存")
	verify(Economy.validate_snapshot(saved[0], db).is_empty(), "无game的存档校验入口接受有效经济状态")

func _quotes_and_limits() -> void:
	var f := fixture()
	funds(f, 1000)
	var quote: Dictionary = f.service.quote_buy(SHOP, "healing_potion", 2)
	for field in ["price", "total", "quantity", "revision", "mode", "item_id", "shop_id", "ok", "error"]:
		var forged := quote.duplicate(true)
		forged[field] = "forged"
		rejected(f, forged, "篡改报价字段被拒绝：" + field)
	var forged := quote.duplicate(true)
	forged["bonus"] = 999
	rejected(f, forged, "报价附加字段不能伪造")
	for amount in [0, -1, 1.5, true, "2", NAN, INF, 1000001]:
		var before := snapshot(f)
		verify(not f.service.quote_buy(SHOP, "healing_potion", amount).ok and snapshot(f) == before, "拒绝非法数量 " + str(amount))
	f.actor.inventory.add_item("fire_bomb")
	rejected(f, quote, "背包信号使旧报价失效")
	quote = f.service.quote_buy(SHOP, "healing_potion")
	f.world.set_flag("unrelated", true)
	rejected(f, quote, "无经济刷新信号的世界变化也令指纹过期")
	quote = f.service.quote_buy(SHOP, "healing_potion")
	f.service.refresh()
	rejected(f, quote, "读档refresh使旧报价失效")
	verify(not f.service.quote_buy("missing", "healing_potion").ok and not f.service.quote_sell(SHOP, "missing").ok, "未知商店与商品不可交易")
	verify(not f.service.quote_buy(SHOP, "healing_potion", 13).ok, "有限货架不能超卖")
	f.actor.inventory.stacks.healing_potion = Economy.MAX_QUANTITY
	verify(not f.service.quote_buy(SHOP, "healing_potion").ok, "购买前拒绝物品上限溢出")
	f.actor.inventory.stacks.healing_potion = 1
	funds(f, Economy.MAX_BALANCE)
	verify(not f.service.quote_sell(SHOP, "healing_potion").ok, "出售前拒绝钱包溢出")
	funds(f, 100, Economy.MAX_BALANCE)
	verify(not f.service.quote_buy(SHOP, "healing_potion").ok, "交易版本溢出前拒绝")
	funds(f, 240)
	quote = f.service.quote_buy(SHOP, "healing_potion", 12)
	verify(quote.ok and f.service.trade(quote) and f.world.get_object(Economy.SHOP_PREFIX + SHOP).stock.healing_potion == 0, "库存恰好买空仍保存零而非重置")
	verify(not f.service.quote_buy(SHOP, "healing_potion").ok, "零库存不可再次购买")

func _equipment_and_quickslots() -> void:
	var f := fixture()
	verify(not f.service.quote_sell(SHOP, "iron_longsword").ok, "已装备唯一武器不可售")
	f.actor.inventory.add_item("iron_longsword", 2)
	f.actor.loadout.sets[1].weapon = "iron_longsword"
	verify(f.actor.inventory.equipped_count("iron_longsword") == 2 and not f.service.quote_sell(SHOP, "iron_longsword", 2).ok, "AB两组同武器占用两份所有权")
	verify(f.service.trade(f.service.quote_sell(SHOP, "iron_longsword")) and f.actor.inventory.count("iron_longsword") == 2, "仅出售第三份武器")
	f.actor.inventory.add_item("hunter_ring", 3)
	f.actor.loadout.equipment.ring1 = "hunter_ring"
	f.actor.loadout.equipment.ring2 = "hunter_ring"
	verify(not f.service.quote_sell(SHOP, "hunter_ring", 2).ok and f.service.trade(f.service.quote_sell(SHOP, "hunter_ring")), "双戒指占用保护且第三份可售")
	f.actor.inventory.cooldowns.healing_potion = 3.0
	var slots: Array = f.actor.inventory.quickslots.duplicate()
	var amount: int = f.actor.inventory.count("healing_potion")
	verify(f.service.trade(f.service.quote_sell(SHOP, "healing_potion", amount)), "允许出售快捷栏消耗品全部副本")
	verify(f.actor.inventory.quickslots == slots and f.actor.inventory.cooldowns.healing_potion == 3.0, "出售不清除快捷引用或冷却")
	verify(f.service.trade(f.service.quote_buy(SHOP, "healing_potion")) and f.actor.inventory.cooldowns.healing_potion == 3.0, "重新购买不能绕过消耗品冷却")

func _state_validation_and_lifecycle() -> void:
	var f := fixture()
	funds(f, 100)
	verify(f.service.trade(f.service.quote_buy(SHOP, "healing_potion")), "准备真实交易存档")
	var valid: Dictionary = f.world.export_state()
	for field in ["balance", "revision", "version"]:
		for value in [-1, true, "1", 1.5, 2147483648]:
			var bad := valid.duplicate(true)
			bad.objects[Economy.WALLET][field] = value
			verify(not Economy.validate_snapshot(bad, db).is_empty(), "拒绝损坏钱包 " + field + ":" + str(value))
	var variants: Array[Dictionary] = []
	var bad := valid.duplicate(true)
	bad.objects[Economy.WALLET]["script"] = "run.gd"
	variants.append(bad)
	bad = valid.duplicate(true)
	bad.objects.erase(Economy.WALLET)
	variants.append(bad)
	bad = valid.duplicate(true)
	bad.objects[Economy.SHOP_PREFIX + SHOP].stock.erase("healing_potion")
	variants.append(bad)
	bad = valid.duplicate(true)
	bad.objects[Economy.SHOP_PREFIX + SHOP].stock.healing_potion = 13
	variants.append(bad)
	bad = valid.duplicate(true)
	bad.objects[Economy.SHOP_PREFIX + SHOP].catalog_version = 999
	variants.append(bad)
	bad = valid.duplicate(true)
	bad.objects["economy.shop.missing"] = bad.objects[Economy.SHOP_PREFIX + SHOP].duplicate(true)
	variants.append(bad)
	bad = valid.duplicate(true)
	bad.objects["economy.fake"] = {}
	variants.append(bad)
	for candidate in variants: verify(not Economy.validate_snapshot(candidate, db).is_empty(), "经济记录严格字段/引用/库存/版本验证")
	verify(Economy.validate_snapshot(State.new().export_state(), db).is_empty(), "缺经济记录的旧存档兼容")
	var old_quote: Dictionary = f.service.quote_buy(SHOP, "healing_potion")
	var replacement := State.new()
	verify(f.service.setup(replacement, f.actor) and f.service.balance() == 0, "绑定新冒险不继承旧钱包")
	var signals: Array = []
	var callback := func(): signals.append(true)
	f.service.changed.connect(callback)
	f.world.set_object(Economy.WALLET, {"version": 1, "balance": 900, "revision": 1})
	verify(signals.is_empty(), "旧世界信号已断开")
	verify(not f.service.trade(old_quote), "旧冒险报价不适用于新冒险")
	f.service.dispose()
	f.service.dispose()
	f.actor.inventory.add_item("fire_bomb")
	verify(signals.is_empty() and f.service.entries(SHOP).is_empty(), "dispose幂等且移除组件信号")

func _catalog_validation() -> void:
	var f := fixture()
	var original: Dictionary = f.service.definition(SHOP)
	for value in [0, -1, true, 1.5, "20"]:
		var shop := original.duplicate(true)
		shop.goods.healing_potion.buy_price = value
		verify(not f.service.setup(f.world, f.actor, {SHOP: shop}), "拒绝非法目录价格 " + str(value))
	var shop := original.duplicate(true)
	shop.goods.magic_candy = {"buy_price": 1, "stock": 1}
	verify(not f.service.setup(f.world, f.actor, {SHOP: shop}), "目录不能放入调试糖果")
	shop = original.duplicate(true)
	shop.goods.healing_potion.sell_price = 21
	verify(not f.service.setup(f.world, f.actor, {SHOP: shop}), "目录拒绝直接倒卖获利")
	shop = original.duplicate(true)
	shop["execute"] = "arbitrary.gd"
	verify(not f.service.setup(f.world, f.actor, {SHOP: shop}), "目录拒绝未知可执行字段")
	shop = original.duplicate(true)
	shop.goods.missing_item = {"sell_price": 1, "stock": 0}
	verify(not f.service.setup(f.world, f.actor, {SHOP: shop}), "目录要求真实物品引用")
	verify(f.service.definition(SHOP) == original, "失败setup保持原绑定与目录")
	shop = original.duplicate(true)
	shop.goods.healing_potion = {"buy_price": Economy.MAX_BALANCE, "stock": 2}
	verify(f.service.setup(f.world, f.actor, {SHOP: shop}) and not f.service.quote_buy(SHOP, "healing_potion", 2).ok, "乘法前拒绝交易总价溢出")

func _capacity_and_readiness() -> void:
	var f := fixture()
	funds(f, 100)
	var quote: Dictionary = f.service.quote_buy(SHOP, "healing_potion")
	verify(Guard.acquire(f.world, "repository.restore"), "测试持有其他服务的锁")
	rejected(f, quote, "读档或奖励持锁时交易失败且零副作用")
	verify(not f.service.quote_buy(SHOP, "healing_potion").ok, "持锁时不签发新报价")
	f.service.dispose()
	verify(not f.service.definition(SHOP).is_empty() and f.service.balance() == 100, "其他服务通知持锁期间dispose拒绝解绑")
	var refresh_signals: Array = []
	var callback := func(): refresh_signals.append(true)
	f.service.changed.connect(callback)
	f.service.refresh()
	verify(refresh_signals.size() == 1, "存档恢复持锁期间refresh仍发布刷新")
	f.service.changed.disconnect(callback)
	Guard.release(f.world, "repository.restore")
	rejected(f, quote, "持锁refresh同样清除旧报价")
	for mode in ["none", "human"]:
		f.actor.control_mode = mode
		verify(f.service.quote_buy(SHOP, "healing_potion").ok == (mode == "human"), "本体控制状态交易门禁 " + mode)
	f.actor.set_meta("traversal_locked", true)
	verify(not f.service.quote_buy(SHOP, "healing_potion").ok, "攀爬时禁止交易")
	f.actor.remove_meta("traversal_locked")
	f.actor.combat.state = "DEAD"
	verify(not f.service.quote_buy(SHOP, "healing_potion").ok, "死亡时禁止交易")
	f.actor.combat.state = "NORMAL"
	paused = true
	verify(f.service.quote_buy(SHOP, "healing_potion").ok, "书本暂停本身不禁止交易")
	paused = false
	var saturated: Dictionary = f.world.export_state()
	for index in range(256): saturated.flags["pad" + str(index)] = "x".repeat(4000)
	var index := 0
	while State.MAX_STATE_BYTES - JSON.stringify(saturated).to_utf8_buffer().size() > 4020:
		saturated.flags["extra" + str(index)] = "x".repeat(4000)
		index += 1
	saturated.flags["tail"] = ""
	var remaining: int = State.MAX_STATE_BYTES - JSON.stringify(saturated).to_utf8_buffer().size()
	saturated.flags.tail = "x".repeat(remaining)
	verify(f.world.import_state(saturated), "准备达到容量上限的世界状态")
	var before := snapshot(f)
	verify(not f.service.quote_buy(SHOP, "healing_potion").ok and snapshot(f) == before, "交易前检查整个世界容量且不先扣钱发物品")
