extends SceneTree
## Versioned shop-price save migration regression. Save data is a controlled
## migration fixture, not evidence of naturally earned progression or balance.
## Source release and bundle remain read-only; repositories live in OS Temp.
const Migration = preload("res://rpg/save_migration.gd")
const Source = preload("res://rpg/save_source_context.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Database = preload("res://combat/combat_database.gd")
const Bundle = preload("res://rpg/content_bundle.gd")
const Fixture = preload("res://tests/save_migration.gd")
const SHOP := "village_supply"
const SHOP_KEY := "economy.shop.village_supply"
const WALLET_KEY := "economy.wallet"
const SOLDIER := "encounter.forest.soldier_01"
const HEAVY := "encounter.forest.heavy_guard_01"

var checks := 0
var failures: Array[String] = []
var source_release := ""
var target_bundle := ""
var evidence := ""
var isolated := ""

func _initialize() -> void:
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--source-release="): source_release = argument.trim_prefix("--source-release=")
		elif argument.begins_with("--bundle="): target_bundle = argument.trim_prefix("--bundle=")
		elif argument.begins_with("--evidence="): evidence = argument.trim_prefix("--evidence=")
	if source_release.is_empty() or target_bundle.is_empty():
		printerr("Requires --source-release=ABS --bundle=ABS [--evidence=ABS]")
		quit(2)
		return
	isolated = OS.get_temp_dir().path_join("mosslight-shop-price-migration-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var selected := Database.configure_content_bundle(target_bundle)
	verify(selected.ok, "select the target content bundle")
	if not selected.ok:
		finish({})
		return
	var target: RefCounted = Database.new()
	var opened := Source.open_release(source_release)
	verify(opened.ok, "open and fingerprint the source release: " + opened.error)
	if not opened.ok:
		finish({})
		return
	var old: RefCounted = opened.context
	var old_shop: Dictionary = old.world_catalog("shops")[SHOP]
	var new_shop: Dictionary = target.world_catalog("shops")[SHOP]
	verify(int(old_shop.catalog_version) == 1 and int(new_shop.catalog_version) == 2, "fixture spans shop catalog version 1 to version 2")
	verify(old_shop.goods.spell_potion.buy_price == 30 and old_shop.goods.spell_potion.sell_price == 8, "source release has old spell-potion prices 30/8")
	verify(new_shop.goods.spell_potion.buy_price == 15 and new_shop.goods.spell_potion.sell_price == 4, "target bundle has new spell-potion prices 15/4")
	var source_repo := Repository.new(isolated.path_join("source-adventures"), old)
	var created: Dictionary = source_repo.create("价格迁移源档", 2)
	verify(created.ok, "create old-identity source fixture in OS Temp")
	if not created.ok:
		finish({})
		return
	# Reuse the established old Willow save fixture, then set merchant inventory
	# to represent prior purchases. Other old items, progress, reward receipts,
	# resources and pending encounter state remain part of that fixture.
	var snapshot: Dictionary = Fixture.populated(created.snapshot, old)
	snapshot.world_state.objects[SHOP_KEY].stock.spell_potion = 3
	snapshot.world_state.objects[SHOP_KEY].stock.qi_potion = 0
	snapshot.world_state.objects[SHOP_KEY].stock.healing_potion = 7
	verify(source_repo.validate_snapshot(snapshot).is_empty(), "controlled source fixture validates with spell stock 3, zero qi stock and healing stock 7")
	var saved: Dictionary = source_repo._commit(snapshot)
	verify(saved.ok, "persist old source fixture and backup")
	if not saved.ok:
		finish({})
		return
	var source_save: String = source_repo._path(2)
	var source_backup: String = source_save + ".bak"
	var source_hash := FileAccess.get_sha256(source_save)
	var backup_hash := FileAccess.get_sha256(source_backup)
	verify(not source_hash.is_empty() and not backup_hash.is_empty(), "source primary and backup exist for later replay")

	var same_version := Migration.build_plan(snapshot, old, old)
	verify(same_version.ok and Migration._same(same_version.snapshot.world_state, snapshot.world_state), "same shop version with unchanged prices keeps existing shop record unchanged")
	var static_plan := Migration.build_plan(snapshot, old, target)
	verify(static_plan.ok, "known versioned price change preflights semantically: " + static_plan.error)
	if not static_plan.ok:
		finish({"source_save": source_save, "source_backup": source_backup})
		return
	var proposed: Dictionary = static_plan.snapshot
	var expected := snapshot.duplicate(true)
	expected.content_set = target.identity()
	expected.world_state.objects[SHOP_KEY].catalog_version = int(new_shop.catalog_version)
	verify(Migration._same(proposed, expected), "only content identity and shop catalog_version change in migrated snapshot")
	var downgrade := Migration.build_plan(proposed, target, old)
	verify(not downgrade.ok and str(downgrade.error).contains("降低商店目录版本"), "valid version-two save cannot migrate back to the otherwise valid version-one shop")
	verify(Migration._same(proposed.inventory, snapshot.inventory), "existing inventory and cooldowns are preserved without price-difference refund")
	verify(Migration._same(proposed.resources, snapshot.resources) and Migration._same(proposed.progression, snapshot.progression) and Migration._same(proposed.loadout, snapshot.loadout), "resources, progression, equipment and skills remain unchanged")
	verify(proposed.world_state.objects[WALLET_KEY].balance == 15 and proposed.world_state.objects[WALLET_KEY].revision == 2, "wallet balance and revision are preserved without refund or compensation")
	verify(Migration._same(proposed.world_state.objects[SHOP_KEY].stock, snapshot.world_state.objects[SHOP_KEY].stock), "all prior stock is preserved: spell 3, qi 0 and healing 7")
	verify(proposed.world_state.objects[SHOP_KEY].stock.spell_potion == 3 and proposed.world_state.objects[SHOP_KEY].stock.qi_potion == 0 and proposed.world_state.objects[SHOP_KEY].stock.healing_potion == 7, "depleted and partially depleted stock does not refill")
	verify(Migration._same(proposed.world_state.objects[SOLDIER], snapshot.world_state.objects[SOLDIER]) and Migration._same(proposed.world_state.objects[HEAVY], snapshot.world_state.objects[HEAVY]), "pending/cooldown encounter receipts remain unchanged")
	var preview_text := " ".join(static_plan.changes)
	verify(preview_text.contains("小瓶能量药水") and preview_text.contains("30 → 15") and preview_text.contains("8 → 4"), "preview names the small energy potion and explicitly shows 30→15 and 8→4")
	verify(preview_text.contains("不补退旧交易差价") and preview_text.contains("剩余库存不变"), "preview states no backdated price refund and no stock refill")

	var destination := Repository.new(isolated.path_join("target-adventures"), target)
	var service := Migration.new(destination)
	var preflight: Dictionary = service.preflight(source_save, source_release)
	verify(preflight.ok, "explicit migration service preflight succeeds: " + str(preflight.error))
	verify(not DirAccess.dir_exists_absolute(destination.directory), "preflight creates no destination repository or save")
	if preflight.ok:
		var preflight_text := " ".join(preflight.changes)
		verify(preflight_text.contains("小瓶能量药水") and preflight_text.contains("30 → 15") and preflight_text.contains("8 → 4"), "user-facing preflight shows both concrete spell-potion price changes")
		var copied: Dictionary = service.commit("调价迁移副本", 9)
		verify(copied.ok and copied.slot == 9, "commit publishes the reviewed copy to the selected empty slot")
		if copied.ok:
			var reopened := Repository.new(destination.directory)
			var readback: Dictionary = reopened.load_slot(9)
			verify(readback.ok, "fresh repository reads the migrated save from disk")
			if readback.ok:
				var result: Dictionary = readback.snapshot
				var expected_world: Dictionary = snapshot.world_state.duplicate(true)
				expected_world.objects[SHOP_KEY].catalog_version = int(new_shop.catalog_version)
				verify(Migration._same(result.content_set, target.identity()), "disk copy carries the exact target bundle identity")
				verify(Migration._same(result.world_state, expected_world), "disk copy changes only shop catalog version inside world state")
				verify(Migration._same(result.inventory, snapshot.inventory) and Migration._same(result.resources, snapshot.resources) and Migration._same(result.progression, snapshot.progression), "disk copy retains item stacks, resources and progression exactly")
				verify(result.world_state.objects[WALLET_KEY].balance == 15 and result.world_state.objects[WALLET_KEY].revision == 2, "disk copy does not refund old purchases or change wallet revision")
				verify(result.world_state.objects[SHOP_KEY].stock.spell_potion == 3 and result.world_state.objects[SHOP_KEY].stock.qi_potion == 0 and result.world_state.objects[SHOP_KEY].stock.healing_potion == 7, "disk copy retains depleted shop stock exactly")
				verify(Migration._same(result.world_state.objects[SOLDIER], snapshot.world_state.objects[SOLDIER]) and Migration._same(result.world_state.objects[HEAVY], snapshot.world_state.objects[HEAVY]), "disk copy retains encounter reward and cooldown receipts")
		verify(not service.commit("重复提交", 10).ok, "one migration preview cannot be committed twice")

	_run_rejection_cases(snapshot, old, target)
	_run_untraded_case(source_repo, destination, old, source_release)
	verify(FileAccess.get_sha256(source_save) == source_hash and FileAccess.get_sha256(source_backup) == backup_hash, "source save and backup bytes remain unchanged after preflight and commit")
	verify(source_repo.load_slot(2).ok, "old source adventure remains readable under its original release")
	finish({"source_save": source_save, "source_backup": source_backup, "source_hash": source_hash, "backup_hash": backup_hash,
		"source_release": source_release, "target_bundle": target_bundle, "target_save": destination._path(9), "fixture_limits": ["controlled shop stock/wallet fixture, not natural play", "explicit migration preflight/commit and disk reconstruction", "no live App or combat session"]})

func _run_rejection_cases(snapshot: Dictionary, old: RefCounted, target: RefCounted) -> void:
	var source_shop: Dictionary = old.world_catalog("shops")[SHOP]
	var shop: Dictionary
	shop = target.world_catalog("shops")[SHOP]
	shop.catalog_version = int(source_shop.catalog_version)
	_reject_shop("price change without a version increase", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.catalog_version = int(source_shop.catalog_version) - 1
	_reject_shop("shop catalog version rollback", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.goods.erase("spell_potion")
	_reject_shop("removal of an existing shop good", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.goods.spell_potion.erase("sell_price")
	_reject_shop("removal of an existing transaction direction", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.goods.iron_longsword.buy_price = 40
	_reject_shop("addition of a transaction direction to an existing good", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.goods.spell_potion.stock += 1
	_reject_shop("change to an existing good's initial stock", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.goods.spell_potion.buy_price = 0
	_reject_shop("invalid zero price", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.goods.spell_potion.sell_price = 16
	_reject_shop("sell price above buy price (arbitrage)", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.name = "改名商店"
	_reject_shop("change to existing shop identity", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.currency = "gem"
	_reject_shop("change to existing shop currency", snapshot, old, target, shop)
	shop = target.world_catalog("shops")[SHOP]
	shop.unreviewed_field = true
	_reject_shop("unknown change to existing shop fields", snapshot, old, target, shop)

func _reject_shop(label: String, snapshot: Dictionary, old: RefCounted, target: RefCounted, changed_shop: Dictionary) -> void:
	var altered := _clone_with_shop(target, changed_shop)
	var plan := Migration.build_plan(snapshot, old, altered)
	verify(not plan.ok, "reject " + label + (": " + str(plan.error) if not plan.ok else ""))

func _run_untraded_case(source_repo: RefCounted, destination: RefCounted, old: RefCounted, release_path: String) -> void:
	var created: Dictionary = source_repo.create("未交易商店旅途", 3)
	verify(created.ok, "create no-shop-record source fixture")
	if not created.ok: return
	var snapshot: Dictionary = created.snapshot.duplicate(true)
	# Ensure this controlled untouched fixture has neither a shop transaction nor
	# a wallet record; this is state setup, not natural play.
	snapshot.world_state.objects.erase(SHOP_KEY)
	snapshot.world_state.objects.erase(WALLET_KEY)
	var saved: Dictionary = source_repo._commit(snapshot)
	verify(saved.ok and not snapshot.world_state.objects.has(SHOP_KEY), "untouched fixture has no merchant state record")
	if not saved.ok: return
	var save_path: String = source_repo._path(3)
	var service := Migration.new(destination)
	var preview: Dictionary = service.preflight(save_path, release_path)
	verify(preview.ok, "preflight accepts never-traded save: " + str(preview.error))
	if not preview.ok: return
	var copied: Dictionary = service.commit("未交易迁移副本", 10)
	verify(copied.ok, "commit never-traded copy")
	if not copied.ok: return
	var readback: Dictionary = Repository.new(destination.directory).load_slot(10)
	verify(readback.ok and not readback.snapshot.world_state.objects.has(SHOP_KEY), "disk copy does not create a shop record for a never-traded save")
	verify(readback.ok and not readback.snapshot.world_state.objects.has(WALLET_KEY), "disk copy does not mint a wallet for a never-traded save")

func _clone_with_shop(context: RefCounted, shop: Dictionary) -> RefCounted:
	var catalogs: Dictionary = {}
	for catalog: String in Bundle.CATALOGS:
		catalogs[catalog] = context.get(catalog).duplicate(true)
	var worlds := {"shops": context.world_catalog("shops"), "quests": context.world_catalog("quests")}
	worlds.shops[SHOP] = shop.duplicate(true)
	return Source.from_catalogs(catalogs, worlds, context.identity())

func finish(detail: Dictionary) -> void:
	detail.merge({"checks": checks, "failures": failures, "isolated": isolated})
	if not evidence.is_empty():
		DirAccess.make_dir_recursive_absolute(evidence)
		var file := FileAccess.open(evidence.path_join("report.json"), FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(detail, "\t"))
			file.close()
	print("SHOP_PRICE_MIGRATION ", JSON.stringify(detail))
	quit(0 if failures.is_empty() else 1)
