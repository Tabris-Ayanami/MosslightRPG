extends SceneTree
## Real deaths, actual disk restores and authored encounter generations.
const Repository = preload("res://rpg/save_repository.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const SOLDIER := "encounter.forest.soldier_01"
const HEAVY := "encounter.forest.heavy_guard_01"
const LETHAL := {"formula": {"base": 1000000}, "can_crit": false, "damage_type": "PHYSICAL"}
var game: Node
var repo: RefCounted
var checks := 0
var failures: Array[String] = []
var observations: Array[bool] = []

func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func freeze() -> void:
	game.player.set_physics_process(false)
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
func enemy(id: String) -> Node:
	return game.combat_world._encounter_nodes.get(id)
func kill(body: Node) -> void:
	body.combat.receive_damage(LETHAL, game.player, Vector3.FORWARD)
func record(id: String) -> Dictionary:
	return game.encounters.record(id)

func enable_lifecycle_fixture() -> void:
	# This suite tests all four life ledgers independently of story progression.
	# Explicit test policy keeps real quest records valid; chapter_runtime covers
	# the authored locks and their normal-play unlock conditions.
	var fixture: Dictionary = game.chapter.definition()
	for id: String in fixture.encounters: fixture.encounters[id] = {}
	if not game.chapter.setup(game.quests, game.encounters, game.combat_world.database, fixture):
		push_error(game.chapter.last_error)
		quit(1)
		return
	game.combat_world._spawn_saved_lives()

func run() -> void:
	create_timer(90, true).timeout.connect(func(): printerr("ENCOUNTER_RUNTIME timeout"); quit(1))
	var path := OS.get_temp_dir().path_join("mosslight-encounter-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	Preferences.settings_path = path + ".cfg"
	repo = Repository.new(path)
	var initial: Dictionary = repo.create("遭遇生命周期")
	var alternate: Dictionary = repo.create("另一遭遇冒险", 1)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(12)
	enable_lifecycle_fixture()
	game.sound.muted = true
	check(game.combat_world._encounter_nodes.size() == 4, "four authored encounter slots spawn real units")
	check(game.player.progression.choose_career("warrior"), "real player chooses career")
	freeze()
	check(game.quests.accept("village_patrol"), "real quest observes authored soldier")
	game.player.progression.experience = 80
	var potions: int = game.player.inventory.count("healing_potion")
	var soldier: Node = enemy(SOLDIER)
	var callback := func():
		observations.append(Guard.busy(game.world_state))
		observations.append(record(SOLDIER).phase == "cooldown")
		observations.append(game.world_state.get_event_count("enemy_defeated", "soldier") == 1)
		observations.append(game.player.loadout.level == 2 and game.player.progression.experience == 20)
		observations.append(game.player.inventory.count("healing_potion") == potions + 1)
		observations.append(game.player.progression.enemy_kills.get("soldier") == 1)
		observations.append(game.quests.status("village_patrol") == "ready" and not game.quests.claim("village_patrol"))
		observations.append(not repo.restore(initial.snapshot, game.player, game).ok)
		observations.append(game.player.progression.reward_enemy("soldier").is_empty())
		var saved: Dictionary = repo.save(0, "遭遇生命周期", game.player, game)
		observations.append(saved.ok and saved.snapshot.world_state.objects[SOLDIER].phase == "cooldown" and saved.snapshot.inventory.stacks.healing_potion == potions + 1)
	game.player.inventory.changed.connect(callback)
	kill(soldier)
	game.player.inventory.changed.disconnect(callback)
	check(observations.size() == 10 and observations.all(func(value: bool): return value), "death observers see encounter, quest, XP and all loot committed together")
	var after: Dictionary = game.player.inventory.export_state()
	game.combat_world._enemy_defeated(soldier)
	check(game.player.inventory.export_state() == after and game.world_state.get_event_count("enemy_defeated", "soldier") == 1, "same life callback cannot pay twice")
	check(record(SOLDIER).remaining == 45.0 and game.combat_world.respawns.is_empty(), "authored cooldown is durable instead of transient respawn list")
	game.combat_world._tick_encounters(12.0)
	check(is_equal_approx(record(SOLDIER).remaining, 45.0), "elapsed time leaves defeated slot waiting for short rest")
	game.paused = true
	game.combat_world._physics_process(10.0)
	check(is_equal_approx(record(SOLDIER).remaining, 45.0), "host pause stops encounter time even without tree pause")
	game.paused = false
	game.combat_world._physics_process(10.0)
	check(is_equal_approx(record(SOLDIER).remaining, 45.0), "transition-frozen protagonist stops encounter time")
	var checkpoint: Dictionary = repo.save(0, "遭遇生命周期", game.player, game)
	check(checkpoint.ok, "real disk save includes cooldown and paid rewards")
	var old_heavy: Node = enemy(HEAVY)
	check(repo.restore(alternate.snapshot, game.player, game).ok, "switch adventure restores a new encounter generation set")
	freeze()
	check(record(SOLDIER).phase == "alive" and record(SOLDIER).generation == 1 and is_instance_valid(enemy(SOLDIER)), "new adventure does not inherit original cooldown")
	check(not old_heavy.is_inside_tree() and game.combat_world.enemies.size() == 4, "old units detach before final restore notifications")
	game.combat_world._enemy_defeated(old_heavy)
	check(game.world_state.get_event_count("enemy_defeated") == 0, "late callback from old epoch cannot reward new adventure")
	check(repo.restore(repo.load_slot(0).snapshot, game.player, game).ok, "restore original disk snapshot in same live scene")
	freeze()
	check(record(SOLDIER).phase == "cooldown" and record(SOLDIER).remaining == 45.0 and not is_instance_valid(enemy(SOLDIER)), "defeated life remains absent with exact stored cooldown")
	check(game.combat_world.enemies.size() == 3, "restore rebuilds only currently living authored slots")
	var heavy: Node = enemy(HEAVY)
	heavy.global_position = game.combat_world._encounter_position(game.encounters.definition(SOLDIER))
	check(game.combat_world.control.possess(heavy, 100), "possess a real body at the defeated encounter spawn")
	game.combat_world._tick_encounters(40.0)
	check(record(SOLDIER).phase == "cooldown" and record(SOLDIER).remaining == 45.0, "time cannot refresh a defeated life while possessing another body")
	game.combat_world.control.release()
	heavy.global_position += Vector3.RIGHT * 20
	var refresh: Dictionary = game.encounters.plan_short_rest(game.world_state.export_state())
	check(refresh.ok and game.world_state.import_state(refresh.world), "commit a short rest before refreshing encounters")
	game.combat_world.refresh_after_short_rest()
	check(record(SOLDIER).phase == "alive" and record(SOLDIER).generation == 2 and is_instance_valid(enemy(SOLDIER)), "safe spawn creates exactly next generation")
	freeze()
	var second: Node = enemy(SOLDIER)
	game.player.inventory.stacks["healing_potion"] = 1000000
	var count_before: int = game.world_state.get_event_count("enemy_defeated", "soldier")
	var growth_before: Dictionary = game.player.progression.export_state()
	kill(second)
	check(record(SOLDIER).phase == "pending" and game.player.inventory.count("healing_potion") == 1000000, "full backpack persists defeated pending life without overflow")
	check(game.player.progression.export_state() == growth_before and game.world_state.get_event_count("enemy_defeated", "soldier") == count_before, "pending reward has no partial XP, drop rotation or quest event")
	var pending: Dictionary = repo.save(0, "遭遇生命周期", game.player, game)
	check(pending.ok, "pending reward is a valid disk-save state")
	check(repo.restore(pending.snapshot, game.player, game).ok and record(SOLDIER).phase == "pending" and not is_instance_valid(enemy(SOLDIER)), "pending life stays defeated after reload")
	freeze()
	game.combat_world._retry_pending()
	check(record(SOLDIER).phase == "pending" and game.world_state.get_event_count("enemy_defeated", "soldier") == count_before, "full inventory retry cannot duplicate progress")
	game.player.inventory.stacks["healing_potion"] = 2
	game.combat_world._retry_pending()
	check(record(SOLDIER).phase == "cooldown" and game.player.inventory.count("healing_potion") == 3, "freed backpack space settles deferred loot and begins cooldown")
	check(game.world_state.get_event_count("enemy_defeated", "soldier") == count_before + 1 and game.player.progression.enemy_kills.soldier == 2, "deferred settlement advances task and drop rotation once")
	game.combat_world._retry_pending()
	check(game.player.inventory.count("healing_potion") == 3, "subsequent retry is inert after settlement")
	# A full world record table is distinct from a full item stack: even the
	# pending record cannot be persisted, so save must fail until retry succeeds.
	var full_world: Dictionary = game.world_state.export_state()
	var index := 0
	while full_world.objects.size() < 2048:
		full_world.objects["capacity.fixture.%d" % index] = {}
		index += 1
	check(game.world_state.import_state(full_world), "prepare legal world with no room for another encounter record")
	var full_enemy: Node = enemy(HEAVY)
	var before_full: Dictionary = game.player.progression.export_state()
	kill(full_enemy)
	check(not full_enemy.get_meta("rpg_defeat_resolved", false) and game.combat_world._pending_deaths.size() == 1, "world capacity failure keeps unresolved corpse queued for retry")
	check(game.player.progression.export_state() == before_full, "world capacity failure does not pay partial reward")
	check(not repo.save(0, "遭遇生命周期", game.player, game).ok, "unpersisted defeated life prevents a misleading successful save")
	var second_full: Node = enemy("encounter.forest.fire_elemental_01")
	kill(second_full)
	check(game.combat_world._pending_deaths.size() == 2, "two unrecorded corpses can await capacity together")
	var reentrant_saves: Array[bool] = []
	var save_during_retry := func(_id: String, _reward: Dictionary): reentrant_saves.append(repo.save(0, "遭遇生命周期", game.player, game).ok)
	game.player.progression.reward_received.connect(save_during_retry)
	full_world.objects.erase("capacity.fixture.0")
	check(game.world_state.import_state(full_world), "free exactly one world record without changing current corpse")
	game.combat_world._retry_pending()
	game.player.progression.reward_received.disconnect(save_during_retry)
	check(record(HEAVY).phase == "cooldown" and game.player.progression.enemy_kills.heavy_guard == 1, "free world capacity allows queued life to settle once")
	check(reentrant_saves == [false] and not game.combat_world.save_error().is_empty(), "first retry observers cannot save while another unrecorded life is still pending")
	full_world = game.world_state.export_state()
	full_world.objects.erase("capacity.fixture.1")
	game.world_state.import_state(full_world)
	game.combat_world._retry_pending()
	check(record("encounter.forest.fire_elemental_01").phase == "cooldown", "second capacity release settles the remaining corpse")
	check(game.combat_world.save_error().is_empty(), "successful retry removes save barrier")
	full_world = game.world_state.export_state()
	for id: String in full_world.objects.keys():
		if id.begins_with("capacity.fixture."): full_world.objects.erase(id)
	game.world_state.import_state(full_world)
	var saved_final: Dictionary = repo.save(0, "遭遇生命周期", game.player, game)
	var malformed: Dictionary = saved_final.snapshot.duplicate(true)
	malformed.world_state.objects[SOLDIER].generation = 0
	var unchanged: Dictionary = game.world_state.export_state()
	check(not repo.restore(malformed, game.player, game).ok and game.world_state.export_state() == unchanged, "malformed encounter rejected before touching scene or player")
	game.queue_free()
	await ticks(3)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(10)
	enable_lifecycle_fixture()
	check(repo.restore(repo.load_slot(0).snapshot, game.player, game).ok, "fresh main scene restores real saved encounter")
	freeze()
	check(record(SOLDIER).phase == "cooldown" and record(SOLDIER).generation == 2 and not is_instance_valid(enemy(SOLDIER)), "process-style scene restart cannot instantly refill defeated slot")
	check(game.player.inventory.count("healing_potion") == 3 and game.player.progression.enemy_kills.soldier == 2, "scene restart preserves loot and rotation with no replay")
	game.queue_free()
	await ticks(3)
	print("ENCOUNTER_RUNTIME %d/%d passed" % [checks - failures.size(), checks])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
