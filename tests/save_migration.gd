extends SceneTree
## Real on-disk old-release -> selected new bundle copy. The handcrafted snapshot
## is a migration fixture, not evidence of earned progression or game balance.
## All saves stay under a unique OS-temp directory. Source releases are read-only.
const Migration = preload("res://rpg/save_migration.gd")
const Source = preload("res://rpg/save_source_context.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Database = preload("res://combat/combat_database.gd")
const ITEM := "willow_watch:herb_brew"
const WEAPON := "willow_watch:willow_blade"
const ARMOR := "willow_watch:watch_hood"
const CAREER := "willow_watch:willow_sentinel"
const SKILL := "willow_watch:willow_strike"
const PASSIVE := "willow_watch:willow_step"
const SOLDIER := "encounter.forest.soldier_01"
const HEAVY := "encounter.forest.heavy_guard_01"
var checks := 0
var failures: Array[String] = []
var isolated := ""
var old_release := ""
var target_bundle := ""
var evidence := ""

func _initialize() -> void: call_deferred("run")
func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--source-release="): old_release = argument.trim_prefix("--source-release=")
		elif argument.begins_with("--bundle="): target_bundle = argument.trim_prefix("--bundle=")
		elif argument.begins_with("--evidence="): evidence = argument.trim_prefix("--evidence=")
	if old_release.is_empty() or target_bundle.is_empty():
		printerr("Requires --source-release=ABS and --bundle=ABS")
		quit(2)
		return
	isolated = OS.get_temp_dir().path_join("mosslight-save-migration-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var selected := Database.configure_content_bundle(target_bundle)
	verify(selected.ok, "target selected once before database construction")
	var target := Database.new()
	var old := Source.open_release(old_release)
	verify(old.ok, "read old release independently: " + old.error)
	if not old.ok:
		finish({})
		return
	verify(target.identity() == selected.identity, "old content inspection leaves global target selection unchanged")
	var source_repo := Repository.new(isolated.path_join("old-adventures"), old.context)
	var created: Dictionary = source_repo.create("旧旅途", 2)
	verify(created.ok, "create isolated source under old identity")
	if not created.ok:
		finish({})
		return
	var snapshot := populated(created.snapshot, old.context)
	verify(source_repo.validate_snapshot(snapshot).is_empty(), "fixture with resources, stock, rewarded quest and pending soldier is valid in old context")
	var saved: Dictionary = source_repo._commit(snapshot)
	verify(saved.ok, "persist representative old adventure and backup")
	var source_path: String = source_repo._path(2)
	var before_hash := FileAccess.get_sha256(source_path)
	var backup_hash := FileAccess.get_sha256(source_path + ".bak")
	var original := snapshot.duplicate(true)
	var plan := Migration.build_plan(snapshot, old.context, target)
	verify(plan.ok, "0.2 -> 0.3 compatible acquisition upgrade preflight: " + plan.error)
	if not plan.ok:
		finish({})
		return
	verify(Migration._same(snapshot, original), "planning does not mutate input snapshot")
	var proposed: Dictionary = plan.snapshot
	for key in ["inventory", "progression", "loadout", "attributes", "resources", "combat", "world"]:
		verify(Migration._same(proposed[key], snapshot[key]), "preserve exact " + key)
	verify(proposed.world_state.objects["economy.shop.village_supply"].stock.healing_potion == 7, "consumed old merchant stock is not replenished")
	verify(proposed.world_state.objects["economy.shop.village_supply"].stock[ITEM] == 6, "new merchant good receives advertised initial stock")
	verify(proposed.world_state.objects["quest.village_patrol"].status == "rewarded" and proposed.inventory.stacks[ARMOR] == 1, "rewarded quest not retroactively paid")
	verify(Migration._same(proposed.world_state.objects[SOLDIER], snapshot.world_state.objects[SOLDIER]), "unchanged pending loot generation remains pending without payout")
	verify(Migration._same(proposed.world_state.counters, snapshot.world_state.counters) and Migration._same(proposed.world_state.seen_events, snapshot.world_state.seen_events), "event and reward deduplication receipts preserved")
	verify(str(plan.changes).contains("不会补发") and str(plan.changes).contains("3 种"), "preview describes concrete reward and merchant changes")
	var pending := snapshot.duplicate(true)
	pending.world_state.objects[HEAVY] = {"version": 1, "generation": 4, "phase": "pending", "remaining": 0.0}
	var blocked := Migration.build_plan(pending, old.context, target)
	verify(not blocked.ok and str(blocked.error).contains("旧版本"), "pending changed heavy-guard loot must settle in original version")
	var ready := snapshot.duplicate(true)
	ready.world_state.objects["quest.village_patrol"].status = "active"
	var ready_plan := Migration.build_plan(ready, old.context, target)
	verify(ready_plan.ok and str(ready_plan.changes).contains("领取时"), "unclaimed quest retains progress and explicitly opts into target rewards")
	for change in ["formula", "missing_item", "existing_stock", "quest_objective", "experience", "rotation"]:
		var altered := clone_context(target)
		match change:
			"formula": altered.careers.warrior.formulas.Stamina = "999"
			"missing_item": altered.weapons.erase(WEAPON)
			"existing_stock":
				var worlds := {"shops": altered.world_catalog("shops"), "quests": altered.world_catalog("quests")}
				worlds.shops.village_supply.goods.healing_potion.stock += 1
				altered = Source.from_catalogs(altered.catalog_snapshot(), worlds, altered.identity())
			"quest_objective":
				var worlds := {"shops": altered.world_catalog("shops"), "quests": altered.world_catalog("quests")}
				worlds.quests.village_patrol.objectives[0].target += 1
				altered = Source.from_catalogs(altered.catalog_snapshot(), worlds, altered.identity())
			"experience": altered.progression.rules.xp_to_next["3"] = 300
			"rotation": altered.progression.soldier.equipment_rotation.reverse()
		verify(not Migration.build_plan(snapshot, old.context, altered).ok, "reject incompatible " + change)
	var invalid := snapshot.duplicate(true)
	invalid.world_state.objects["quest.village_patrol"].baselines.clear()
	verify(not Migration.build_plan(invalid, old.context, target).ok, "source quest records validated before changing identity")
	var destination := Repository.new(isolated.path_join("new-adventures"))
	var service := Migration.new(destination)
	verify(service.preflight(source_path, old_release).ok, "actual file preflight succeeds")
	verify(not DirAccess.dir_exists_absolute(destination.directory), "preflight creates no target directory or save")
	var copied := service.commit("春风副本", 9)
	verify(copied.ok and copied.slot == 9, "publish into chosen empty slot")
	verify(not service.commit("重复副本", 10).ok and not destination.slot(10).occupied, "preview cannot be committed twice")
	var reopened := Repository.new(destination.directory)
	var result: Dictionary = reopened.load_slot(9)
	verify(result.ok and result.snapshot.name == "春风副本", "new repository reads copied save from disk")
	if result.ok:
		verify(Migration._same(result.snapshot.content_set, target.identity()), "copy uses target identity after semantic migration")
		verify(result.snapshot.created_at_unix == snapshot.created_at_unix, "copy preserves original creation time")
		verify(Migration._same(result.snapshot.resources, snapshot.resources) and Migration._same(result.snapshot.combat, snapshot.combat), "copy does not heal, refill resources or reset cooldowns")
		verify(Migration._same(result.snapshot.world_state, proposed.world_state), "all world records survive disk round trip")
	verify(FileAccess.get_sha256(source_path) == before_hash and FileAccess.get_sha256(source_path + ".bak") == backup_hash, "original and backup bytes remain untouched")
	verify(source_repo.load_slot(2).ok, "original remains readable with original version")
	verify(not destination.read_verified_file(source_path).ok, "ordinary target loader still refuses old content identity")
	verify(service.preflight(source_path, old_release).ok, "new preview before slot conflict")
	var occupied: Dictionary = destination.create("竞争写入", 10)
	var occupied_hash := FileAccess.get_sha256(destination._path(10))
	verify(occupied.ok and not service.commit("冲突副本", 10).ok and FileAccess.get_sha256(destination._path(10)) == occupied_hash, "slot occupied after preview is never overwritten")
	verify(service.preflight(source_path, old_release).ok, "new preview before source change")
	var changed := snapshot.duplicate(true)
	changed.resources.HP -= 1
	verify(source_repo._commit(changed).ok, "simulate old game advancing after preview")
	verify(not service.commit("过期副本", 11).ok and not destination.slot(11).occupied, "source changed after preview requires new preflight")
	verify(source_repo._commit(snapshot).ok, "restore fixture content for UI replay")
	verify(service.preflight(source_path + ".bak", old_release).ok, "explicit original backup can be verified as migration source")
	verify(service.preflight(source_path, old_release).ok, "new preview before target-rule change")
	destination.database.careers.warrior.formulas.Stamina = "1"
	verify(not service.commit("规则改变", 12).ok and not destination.slot(12).occupied, "target rule mutation after preview invalidates plan")
	verify(Migration._same(target.identity(), selected.identity), "global target identity remains fixed through every operation")
	# Starting from built-in content also has to preserve its existing career
	# branch order while permitting the compiler's new optional advancement.
	var base_catalogs: Dictionary = {}
	for catalog: String in Database.CATALOGS:
		base_catalogs[catalog] = JSON.parse_string(FileAccess.get_file_as_string("res://data/combat/" + catalog + ".json"))
	var base_worlds := {"shops": JSON.parse_string(FileAccess.get_file_as_string("res://data/world/shops.json")), "quests": JSON.parse_string(FileAccess.get_file_as_string("res://data/world/quests.json"))}
	var builtin := Source.from_catalogs(base_catalogs, base_worlds, {})
	var builtin_repo := Repository.new(isolated.path_join("builtin-adventures"), builtin)
	var civilian: Dictionary = builtin_repo.create("内置旧旅途", 0)
	var expanded := Migration.build_plan(civilian.snapshot, builtin, target)
	verify(expanded.ok, "builtin context can acquire optional new career branch and six new catalog entries: " + expanded.error)
	verify(expanded.ok and expanded.snapshot.inventory.stacks.is_empty() and expanded.snapshot.loadout.level == 0 and expanded.snapshot.progression.starter_granted == false, "adding content neither chooses a career nor grants preview samples")
	verify(expanded.ok and str(expanded.changes).contains("新增 6 项"), "preflight reports actual added catalog count")
	var reverse := Migration.build_plan(snapshot, old.context, builtin)
	verify(not reverse.ok, "removing a pack is not silently treated as a downgrade migration")
	finish({"source_save": source_path, "source_release": old_release, "target_bundle": target_bundle, "copied_save": destination._path(9), "changes": plan.changes})

static func populated(initial: Dictionary, context: RefCounted) -> Dictionary:
	var snapshot := initial.duplicate(true)
	snapshot.loadout.level = 3
	snapshot.loadout.career_ids = ["warrior", CAREER]
	snapshot.loadout.learned_skills = [SKILL]
	snapshot.loadout.equipment.head = ARMOR
	snapshot.loadout.sets[0] = {"weapon": WEAPON, "skills": [SKILL, "", ""]}
	snapshot.attributes = context.careers.warrior.stats.duplicate(true)
	snapshot.inventory = {"stacks": {WEAPON: 1, ARMOR: 1, ITEM: 2, "healing_potion": 3}, "quickslots": [ITEM, "healing_potion", "", ""], "cooldowns": {ITEM: 2.25}}
	snapshot.progression = {"experience": 55, "starter_granted": true, "career_rewards": [CAREER], "claimed_rewards": {"fixture.old-kill": true}, "enemy_kills": {"soldier": 1}, "acquired_traits": {PASSIVE: {"source": "迁移测试祝福", "kind": "祝福"}}}
	snapshot.resources = {"HP": 73.0, "Stamina": 1.25, "Energy": 12.0}
	snapshot.combat = {"cooldowns": {SKILL: 2.5}, "stamina_clock": 0.35, "energy_clock": 1.2}
	var stock: Dictionary = {}
	for id: String in context.world_catalog("shops").village_supply.goods: stock[id] = context.world_catalog("shops").village_supply.goods[id].stock
	stock.healing_potion = 7
	snapshot.world_state.objects = {"economy.wallet": {"version": 1, "balance": 15, "revision": 2}, "economy.shop.village_supply": {"version": 1, "catalog_version": int(context.world_catalog("shops").village_supply.catalog_version), "stock": stock}, "quest.village_patrol": {"status": "rewarded", "baselines": {"clear_soldiers": 0}}, SOLDIER: {"version": 1, "generation": 2, "phase": "pending", "remaining": 0.0}, HEAVY: {"version": 1, "generation": 1, "phase": "cooldown", "remaining": 23.5}}
	snapshot.world_state.counters = {"enemy_defeated": {"": 1, "soldier": 1}}
	snapshot.world_state.seen_events = {"fixture.old-event": true}
	return snapshot

static func clone_context(context: RefCounted) -> RefCounted:
	var catalogs: Dictionary = {}
	for name: String in Database.CATALOGS: catalogs[name] = context.get(name).duplicate(true)
	return Source.from_catalogs(catalogs, {"shops": context.world_catalog("shops"), "quests": context.world_catalog("quests")}, context.identity())

func finish(detail: Dictionary) -> void:
	detail.merge({"checks": checks, "failures": failures, "isolated": isolated})
	if not evidence.is_empty():
		DirAccess.make_dir_recursive_absolute(evidence)
		var file := FileAccess.open(evidence.path_join("report.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(detail, "\t"))
		file.close()
	print("MIGRATION_REPORT ", JSON.stringify(detail))
	quit(0 if failures.is_empty() else 1)
