extends SceneTree
## Hermetic catalog composition tests: only dictionaries and bundled JSON are
## read. No App, preferences, repository or player save directory is opened.
const Acquisition = preload("res://rpg/content_acquisition.gd")
const Economy = preload("res://rpg/economy_service.gd")
const State = preload("res://rpg/world_state.gd")
const ITEM := "trail_guard:tonic"
const WEAPON := "trail_guard:blade"
const ARMOR := "trail_guard:hood"
const SHOP := "village_supply"
const QUEST := "village_patrol"
var checks := 0
var failures: Array[String] = []

class FixtureDatabase extends RefCounted:
	var items: Dictionary
	var weapons: Dictionary
	var equipment: Dictionary
	var worlds: Dictionary
	func world_catalog(name: String) -> Dictionary: return worlds.get(name, {}).duplicate(true)

func _initialize() -> void: call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func fixture() -> Dictionary:
	var catalogs: Dictionary = {}
	for name in ["items", "weapons", "equipment", "enemies", "progression"]:
		catalogs[name] = JSON.parse_string(FileAccess.get_file_as_string("res://data/combat/" + name + ".json"))
	catalogs.items[ITEM] = {"id": ITEM}
	catalogs.weapons[WEAPON] = {"id": WEAPON}
	catalogs.equipment[ARMOR] = {"id": ARMOR}
	var worlds: Dictionary = {}
	var hashes: Dictionary = {}
	for name in ["shops", "quests"]:
		var path: String = "res://data/world/" + name + ".json"
		worlds[name] = JSON.parse_string(FileAccess.get_file_as_string(path))
		hashes[name] = FileAccess.get_sha256(path)
	var plan := {"format_version": 1, "world_base_sha256": hashes,
		"shops": {SHOP: {ITEM: {"stock": 5, "buy_price": 20, "sell_price": 5}}},
		"quests": {QUEST: {ARMOR: 1}}, "enemy_drops": {"soldier": {WEAPON: 2}}}
	return {"plan": plan, "catalogs": catalogs, "worlds": worlds, "packs": [{"pack_id": "trail_guard", "version": "1.0.0", "sha256": "a".repeat(64)}]}

func compose(f: Dictionary) -> Dictionary:
	return Acquisition.apply(f.plan, f.catalogs, f.worlds, f.packs)

func rejected(f: Dictionary, label: String) -> void:
	var before := f.duplicate(true)
	var result := compose(f)
	verify(not result.ok and not result.error.is_empty() and result.catalogs.is_empty() and result.world_catalogs.is_empty(), label)
	verify(var_to_bytes(f) == var_to_bytes(before), label + " leaves every input unchanged")

func run() -> void:
	var f := fixture()
	var before := f.duplicate(true)
	var result := compose(f)
	verify(result.ok, "three inventory catalogs acquire through existing routes: " + result.error)
	if not result.ok:
		finish()
		return
	verify(f == before, "successful composition leaves all input dictionaries untouched")
	verify(result.world_catalogs.shops[SHOP].goods[ITEM].stock == 5 and result.world_catalogs.quests[QUEST].rewards.items[ARMOR] == 1 and result.catalogs.progression.soldier.drops[WEAPON] == 2, "all three declared routes are present")
	verify(result.catalogs.progression.soldier.experience == f.catalogs.progression.soldier.experience and result.catalogs.progression.soldier.equipment_rotation == f.catalogs.progression.soldier.equipment_rotation, "enemy XP and deterministic rotation remain intact")
	verify(result.world_catalogs.quests[QUEST].objectives == f.worlds.quests[QUEST].objectives and result.world_catalogs.quests[QUEST].rewards.experience == f.worlds.quests[QUEST].rewards.experience, "quest goals and XP remain intact")
	result.world_catalogs.shops[SHOP].goods[ITEM].stock = 0
	result.catalogs.items[ITEM].id = "changed"
	verify(f == before, "returned nested data cannot mutate the original catalogs or plan")
	f = fixture()
	for route in Acquisition.ROUTES: f.plan[route] = {}
	rejected(f, "explicit empty acquisition is rejected rather than creating a meaningless new identity")
	f = fixture()
	f.plan.quests[QUEST][ITEM] = 1000000.0
	f.plan.enemy_drops.soldier[ITEM] = 1
	f.plan.shops[SHOP][WEAPON] = {"stock": 0, "sell_price": 2147483647.0}
	verify(compose(f).ok, "same owned item may have multiple routes; whole JSON numbers and boundary quantities are accepted")
	_shape_failures()
	_reference_failures()
	_target_identifiers()
	_economy_failures()
	_capacity_failures()
	_snapshot_validation()
	finish()

func _shape_failures() -> void:
	var f := fixture()
	f.plan.script = "arbitrary()"
	rejected(f, "unknown executable plan field rejected")
	f = fixture()
	f.plan.format_version = 2
	rejected(f, "unknown acquisition version rejected")
	f = fixture()
	f.plan.erase("enemy_drops")
	rejected(f, "compiled plan requires all route maps")
	f = fixture()
	f.plan.world_base_sha256.shops = "not a fingerprint"
	rejected(f, "malformed base fingerprint rejected")
	f = fixture()
	f.plan.world_base_sha256.extra = "a".repeat(64)
	rejected(f, "unknown fingerprint field rejected")
	for route in Acquisition.ROUTES:
		f = fixture()
		f.plan[route] = []
		rejected(f, "route map is required: " + route)
	f = fixture()
	f.plan.shops[SHOP] = {}
	rejected(f, "empty target declaration rejected")
	f = fixture()
	f.packs.append(f.packs[0].duplicate(true))
	rejected(f, "duplicate pack identity rejected")
	for value in [0, -1, 1.5, 1000001, true, null, INF, NAN]:
		f = fixture()
		f.plan.quests[QUEST][ARMOR] = value
		rejected(f, "invalid quest quantity rejected: " + str(value))
		f = fixture()
		f.plan.enemy_drops.soldier[WEAPON] = value
		rejected(f, "invalid enemy quantity rejected: " + str(value))

func _reference_failures() -> void:
	var f := fixture()
	f.plan.shops.unknown_shop = f.plan.shops[SHOP].duplicate(true)
	rejected(f, "routes cannot invent an unplaced shop")
	f = fixture()
	f.plan.quests.unknown_quest = f.plan.quests[QUEST].duplicate(true)
	rejected(f, "routes cannot invent an unoffered quest")
	f = fixture()
	f.catalogs.progression.erase("soldier")
	rejected(f, "enemy must have an existing reward definition")
	f = fixture()
	f.catalogs.enemies.erase("soldier")
	rejected(f, "reward target must name an actual enemy")
	f = fixture()
	f.plan.quests[QUEST] = {"healing_potion": 1}
	rejected(f, "base item cannot be declared as pack-owned acquisition")
	f = fixture()
	f.packs = [{"pack_id": "other_pack"}]
	rejected(f, "item namespace must belong to a selected pack")
	f = fixture()
	f.catalogs.items.erase(ITEM)
	rejected(f, "unknown item cannot be granted")
	f = fixture()
	f.catalogs.equipment[ITEM] = {"id": ITEM}
	rejected(f, "ambiguous ID shared across inventory catalogs rejected")
	f = fixture()
	f.catalogs.items[ITEM].id = WEAPON
	rejected(f, "item definition identity mismatch rejected")
	f = fixture()
	var long_id := "trail_guard:" + "a".repeat(85)
	f.catalogs.items[long_id] = {"id": long_id}
	f.plan.quests[QUEST][long_id] = 1
	rejected(f, "acquisition IDs must fit runtime 96-character contract")
	for route in Acquisition.ROUTES:
		f = fixture()
		match route:
			"shops": f.worlds.shops[SHOP].goods[ITEM] = {"stock": 1, "buy_price": 5}
			"quests": f.worlds.quests[QUEST].rewards.items[ARMOR] = 1
			"enemy_drops": f.catalogs.progression.soldier.drops[WEAPON] = 1
		rejected(f, "existing acquisition entries cannot be overwritten: " + route)

func _target_identifiers() -> void:
	for id in ["chapter/patrol", "q" + "a".repeat(95)]:
		var f := fixture()
		f.worlds.quests[id] = f.worlds.quests[QUEST].duplicate(true)
		f.worlds.quests[id].id = id
		f.plan.quests = {id: {ARMOR: 1}}
		var result := compose(f)
		verify(result.ok and result.world_catalogs.quests[id].rewards.items[ARMOR] == 1, "quest acquisition follows QuestService ID contract: " + id)
	for id in ["chapter?patrol", "chapter patrol", "chapter@patrol", "chapter\\patrol", "q" + "a".repeat(96)]:
		var f := fixture()
		f.worlds.quests[id] = f.worlds.quests[QUEST].duplicate(true)
		f.worlds.quests[id].id = id
		f.plan.quests = {id: {ARMOR: 1}}
		rejected(f, "quest acquisition rejects invalid characters or excess length: " + id)
	var f := fixture()
	f.worlds.shops["chapter/shop"] = f.worlds.shops[SHOP].duplicate(true)
	f.worlds.shops["chapter/shop"].id = "chapter/shop"
	f.plan.shops = {"chapter/shop": {ITEM: {"stock": 1, "buy_price": 20}}}
	rejected(f, "quest slash compatibility does not loosen shop IDs")
	f = fixture()
	f.catalogs.enemies["chapter/soldier"] = f.catalogs.enemies.soldier.duplicate(true)
	f.catalogs.enemies["chapter/soldier"].id = "chapter/soldier"
	f.catalogs.progression["chapter/soldier"] = f.catalogs.progression.soldier.duplicate(true)
	f.catalogs.progression["chapter/soldier"].id = "chapter/soldier"
	f.plan.enemy_drops = {"chapter/soldier": {WEAPON: 1}}
	rejected(f, "quest slash compatibility does not loosen combat enemy IDs")

func _economy_failures() -> void:
	for goods in [{"stock": 1}, {"stock": 1, "sell_price": 2}, {"stock": 1, "buy_price": 2, "sell_price": 3}, {"stock": -1, "buy_price": 2}, {"stock": 1000001, "buy_price": 2}, {"stock": 1, "buy_price": 0}, {"stock": 1, "buy_price": 2147483648}, {"stock": 1, "buy_price": true}, {"stock": 1, "buy_price": 1.5}, {"stock": 1, "buy_price": 3, "script": "bad"}]:
		var f := fixture()
		f.plan.shops[SHOP][ITEM] = goods
		rejected(f, "invalid shop declaration rejected: " + str(goods))
	var f := fixture()
	f.worlds.shops["second"] = f.worlds.shops[SHOP].duplicate(true)
	f.worlds.shops.second.id = "second"
	f.plan.shops["second"] = {ITEM: {"stock": 0, "sell_price": 21}}
	rejected(f, "cross-shop acquisition arbitrage rejected")
	f.plan.shops.second[ITEM].sell_price = 20
	var result := compose(f)
	verify(result.ok, "equal buy/sell prices are legal across shops: " + result.error)

func _capacity_failures() -> void:
	for route in Acquisition.ROUTES:
		var f := fixture()
		var destination: Dictionary
		var maximum := 128 if route == "shops" else 32
		match route:
			"shops": destination = f.worlds.shops[SHOP].goods
			"quests": destination = f.worlds.quests[QUEST].rewards.items
			"enemy_drops": destination = f.catalogs.progression.soldier.drops
		while destination.size() < maximum:
			var id := "existing_%d" % destination.size()
			destination[id] = {"stock": 0, "sell_price": 1} if route == "shops" else 1
		rejected(f, "merged capacity counts pre-existing entries: " + route)

func _snapshot_validation() -> void:
	var f := fixture()
	var merged := compose(f)
	var db := FixtureDatabase.new()
	db.items = merged.catalogs.items
	db.weapons = merged.catalogs.weapons
	db.equipment = merged.catalogs.equipment
	db.worlds = merged.world_catalogs
	var snapshot := State.new().export_state()
	var stock: Dictionary = {}
	for item in merged.world_catalogs.shops[SHOP].goods: stock[item] = merged.world_catalogs.shops[SHOP].goods[item].stock
	stock[ITEM] = 0
	snapshot.objects[Economy.WALLET] = {"version": 1, "balance": 3, "revision": 1}
	snapshot.objects[Economy.SHOP_PREFIX + SHOP] = {"version": 1, "catalog_version": int(merged.world_catalogs.shops[SHOP].catalog_version), "stock": stock}
	verify(Economy.validate_snapshot(snapshot, db).is_empty(), "repository validator reads same frozen expanded shop catalog and accepts exhausted added stock")
	snapshot.objects[Economy.SHOP_PREFIX + SHOP].stock.erase(ITEM)
	verify(not Economy.validate_snapshot(snapshot, db).is_empty(), "old shop stock cannot silently refill or migrate an added product")
	verify(f.worlds.shops[SHOP].goods.size() + 1 == db.worlds.shops[SHOP].goods.size(), "snapshot validation cannot mutate base or frozen definitions")

func finish() -> void:
	print("CONTENT ACQUISITION: %d/%d" % [checks - failures.size(), checks])
	for failure in failures: push_error(failure)
	quit(1 if not failures.is_empty() else 0)
