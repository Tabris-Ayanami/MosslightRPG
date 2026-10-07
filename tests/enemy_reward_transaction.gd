extends SceneTree
## Real RPG components, in-memory adventures only. No app, preferences, save
## repository or user:// file access is used by this fixture.
const Database = preload("res://combat/combat_database.gd")
const Inventory = preload("res://rpg/inventory_component.gd")
const Progression = preload("res://rpg/progression_component.gd")
const Loadout = preload("res://combat/loadout_component.gd")
const Stats = preload("res://combat/stats_component.gd")
const Resources = preload("res://combat/resource_component.gd")
const State = preload("res://rpg/world_state.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const Form = preload("res://combat/unit_form.gd")
const Quests = preload("res://rpg/quest_service.gd")

class FixtureHost extends RefCounted:
	var world_state := State.new()

class FixtureArena extends RefCounted:
	var host := FixtureHost.new()

class FixtureCombat extends Node:
	var actor: Node
	var state := "NORMAL"
	var base_poise := 50.0
	var current_poise := 50.0
	func can_start() -> bool: return state == "NORMAL"
	func max_poise() -> float: return base_poise
	func context() -> Dictionary:
		var values: Dictionary = {}
		for key in Stats.IDS + ["Armor"]:
			values[key] = actor.stats.get_final_stat(key)
		return {"stats": values, "level": actor.loadout.level, "proficiencies": actor.loadout.proficiencies}

class Fixture extends Node:
	var stats: Node
	var resources: Node
	var loadout: Node
	var combat: Node
	var inventory: Node
	var progression: Node
	var arena := FixtureArena.new()
	var form: RefCounted
	var definition := {"level": 0}

var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func actor_fixture(choose := true) -> Fixture:
	var actor := Fixture.new()
	root.add_child(actor)
	var db := Database.new()
	actor.stats = Stats.new()
	actor.resources = Resources.new()
	actor.loadout = Loadout.new()
	actor.combat = FixtureCombat.new()
	actor.combat.actor = actor
	actor.inventory = Inventory.new()
	actor.progression = Progression.new()
	for component in [actor.stats, actor.resources, actor.loadout, actor.combat, actor.inventory, actor.progression]:
		actor.add_child(component)
	actor.loadout.setup(actor, db)
	actor.inventory.setup(actor, db)
	actor.progression.setup(actor, db, actor.inventory)
	actor.loadout.configure_progression(actor.inventory, actor.progression)
	actor.stats.changed.connect(actor.loadout.refresh_resources)
	actor.loadout._rebuild(true)
	if choose: actor.progression.choose_career("warrior")
	return actor

func snapshot(actor: Fixture) -> Dictionary:
	return {"inventory": actor.inventory.export_state(), "growth": actor.progression.export_state(),
		"loadout": actor.loadout.export_state(), "resources": actor.resources.pools.duplicate(true),
		"world": actor.arena.host.world_state.export_state()}

func signals(actor: Fixture) -> Dictionary:
	var seen := {"inventory": 0, "growth": 0, "reward": 0, "level": 0, "loadout": 0, "resources": 0}
	actor.inventory.changed.connect(func(): seen.inventory += 1)
	actor.progression.changed.connect(func(): seen.growth += 1)
	actor.progression.reward_received.connect(func(_id, _reward): seen.reward += 1)
	actor.progression.leveled_up.connect(func(_level): seen.level += 1)
	actor.loadout.changed.connect(func(): seen.loadout += 1)
	actor.resources.resource_changed.connect(func(_id, _current, _maximum): seen.resources += 1)
	return seen

func no_signals(seen: Dictionary) -> bool:
	for value in seen.values():
		if value != 0: return false
	return true

func rejected(actor: Fixture, label: String, enemy_id := "soldier", reward_key := "failure-receipt") -> void:
	var before := snapshot(actor)
	var seen := signals(actor)
	actor.progression.last_error = "unchanged by planning"
	var plan: Dictionary = actor.progression.plan_enemy_reward(enemy_id, reward_key)
	verify(not plan.ok and not str(plan.error).is_empty(), label + ": preflight rejects")
	verify(snapshot(actor) == before and actor.progression.last_error == "unchanged by planning" and no_signals(seen), label + ": planning is pure")
	verify(actor.progression.reward_enemy(enemy_id, reward_key).is_empty() and snapshot(actor) == before and no_signals(seen), label + ": failure changes no reward state")

func run() -> void:
	_pure_plan_and_split_commit()
	_rotation_and_boundaries()
	_invalid_data()
	_observers_and_reentry()
	_direct_commit_and_local_guard()
	_form_and_battle()
	await process_frame
	print("ENEMY_REWARD_TRANSACTION_RESULT checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _pure_plan_and_split_commit() -> void:
	var actor := actor_fixture()
	actor.progression.experience = 70
	actor.progression.last_error = "before"
	var seen := signals(actor)
	var before := snapshot(actor)
	var plan: Dictionary = actor.progression.plan_enemy_reward("soldier", "life-1")
	verify(plan.ok and plan.level == 2 and plan.experience == 10, "pure plan calculates level and remainder from real curve")
	verify(snapshot(actor) == before and no_signals(seen) and actor.progression.last_error == "before", "successful preflight changes neither state nor last_error")
	verify(plan.stacks.healing_potion == before.inventory.stacks.healing_potion + 1 and plan.enemy_kills.soldier == 1 and plan.claimed_rewards["life-1"], "plan includes loot, rotation count and receipt together")
	var detached: Dictionary = plan.duplicate(true)
	detached.stacks.healing_potion = 12345
	detached.reward.drops.healing_potion = 999
	verify(snapshot(actor) == before and actor.progression.database.progression.soldier.drops.healing_potion == 1, "planned dictionaries cannot mutate live ownership or source catalog")
	var world: RefCounted = actor.arena.host.world_state
	verify(Guard.acquire(world, "combined-death"), "outer world transaction obtains adventure guard")
	actor.progression.commit_enemy_reward(plan, false)
	verify(no_signals(seen), "silent commit emits no inventory, growth, resource or loadout signals")
	verify(actor.inventory.stacks == plan.stacks and actor.progression.experience == 10 and actor.loadout.level == 2 and actor.progression.claimed_rewards["life-1"], "silent commit assigns the whole persistent reward")
	actor.progression.publish_enemy_reward(plan, 1)
	verify(seen.inventory == 1 and seen.growth == 1 and seen.reward == 1 and seen.level == 1 and seen.loadout == 1 and seen.resources > 0, "separate publication rebuilds once and emits one reward")
	verify(Guard.busy(world), "component publication leaves outer transaction guard owned by caller")
	Guard.release(world, "combined-death")
	rejected(actor, "duplicate persisted receipt", "soldier", "life-1")
	actor.free()

func _rotation_and_boundaries() -> void:
	var actor := actor_fixture(false)
	rejected(actor, "unselected level zero")
	actor.free()
	actor = actor_fixture()
	var first: Dictionary = actor.progression.reward_enemy("soldier", "first")
	var second: Dictionary = actor.progression.reward_enemy("soldier", "second")
	verify(first.drops.has("iron_longsword") and second.drops.has("hunter_dagger") and actor.progression.enemy_kills.soldier == 2, "success retains deterministic equipment rotation")
	var growth_copy: Dictionary = actor.progression.export_state()
	var restored := actor_fixture()
	restored.progression.import_state(growth_copy)
	verify(restored.progression.reward_enemy("soldier", "third").drops.has("shortbow"), "imported rotation continues at the next equipment")
	restored.free()
	actor.loadout.level = actor.progression.max_level()
	actor.progression.experience = 0
	verify(not actor.progression.reward_enemy("ogre").is_empty() and actor.progression.experience == 0 and actor.loadout.level == actor.progression.max_level(), "maximum level still earns loot and ignores XP")
	actor.free()
	actor = actor_fixture()
	actor.loadout.level = actor.progression.max_level()-1
	actor.progression.experience = actor.progression.to_next_level()-10
	verify(not actor.progression.reward_enemy("soldier").is_empty() and actor.loadout.level == actor.progression.max_level() and actor.progression.experience == 0, "reaching maximum level clears excess XP")
	actor.free()
	actor = actor_fixture()
	actor.inventory.stacks.healing_potion = 1000000
	rejected(actor, "one full reward stack rejects every item")
	actor.free()
	actor = actor_fixture()
	actor.progression.database.progression.soldier.drops = {"healing_potion": 1, "iron_longsword": 1}
	actor.inventory.stacks.iron_longsword = 999999
	rejected(actor, "base and rotation drops aggregate before capacity check")
	actor.free()
	actor = actor_fixture()
	actor.progression.enemy_kills.soldier = 1000000
	rejected(actor, "kill counter capacity")
	actor.free()
	actor = actor_fixture()
	actor.progression.experience = 2147483640
	rejected(actor, "XP addition overflow")
	actor.free()
	actor = actor_fixture()
	for index in range(100000): actor.progression.claimed_rewards["life-%d" % index] = true
	rejected(actor, "receipt capacity", "soldier", "new-life")
	verify(not actor.progression.reward_enemy("soldier").is_empty(), "unkeyed natural life reward does not grow full receipt collection")
	actor.free()

func _invalid_data() -> void:
	var configs: Array = [
		{"id": "soldier", "experience": 40, "drops": {"healing_potion": 1, "unknown_item": 1}},
		{"id": "soldier", "experience": 40, "drops": {"healing_potion": -1}},
		{"id": "soldier", "experience": 40, "drops": {"healing_potion": 1.5}},
		{"id": "soldier", "experience": 40, "drops": {"healing_potion": true}},
		{"id": "soldier", "experience": 40, "drops": []},
		{"id": "soldier", "experience": -1, "drops": {}},
		{"id": "soldier", "experience": INF, "drops": {}},
		{"id": "soldier", "experience": 2147483648, "drops": {}},
		{"id": "soldier", "experience": 40, "drops": {}, "equipment_rotation": ["iron_longsword", "unknown_item"]},
		{"id": "soldier", "experience": 40, "drops": {}, "equipment_rotation": "iron_longsword"},
		{"id": "wrong", "experience": 40, "drops": {}},
		[]]
	for index in range(configs.size()):
		var actor := actor_fixture()
		actor.progression.database.progression.soldier = configs[index]
		rejected(actor, "invalid reward config %d" % index)
		actor.free()
	for threshold in [0, -1, 1.5, true, INF, "100"]:
		var actor := actor_fixture()
		actor.progression.database.progression.rules.xp_to_next["1"] = threshold
		rejected(actor, "invalid XP threshold " + str(threshold))
		actor.free()
	var actor := actor_fixture()
	actor.progression.database.progression.rules.max_level = 0
	rejected(actor, "invalid maximum level")
	actor.free()
	actor = actor_fixture()
	rejected(actor, "unknown enemy", "missing")
	rejected(actor, "oversized receipt", "soldier", "x".repeat(129))
	actor.progression.claimed_rewards["bad"] = 1
	rejected(actor, "malformed prior receipt")
	actor.free()

func _observers_and_reentry() -> void:
	var actor := actor_fixture()
	actor.progression.database.progression.soldier.experience = 770
	var plan: Dictionary = actor.progression.plan_enemy_reward("soldier", "outer")
	var seen := {"partial": false, "nested": false, "callbacks": 0, "quest_reentry": false}
	var quests := Quests.new()
	verify(quests.setup(actor.arena.host.world_state, actor), "real quest service shares the reward adventure")
	var observer := func():
		seen.callbacks += 1
		if actor.inventory.stacks != plan.stacks or actor.progression.enemy_kills != plan.enemy_kills or actor.progression.claimed_rewards != plan.claimed_rewards or actor.progression.experience != plan.experience or actor.loadout.level != plan.level:
			seen.partial = true
		if not actor.progression.reward_enemy("ogre", "nested").is_empty(): seen.nested = true
		if quests.accept("village_patrol"): seen.quest_reentry = true
	actor.resources.resource_changed.connect(func(_id, _current, _maximum): observer.call())
	actor.loadout.changed.connect(observer)
	actor.inventory.changed.connect(observer)
	actor.progression.leveled_up.connect(func(_level): observer.call())
	actor.progression.reward_received.connect(func(_id, reward):
		observer.call()
		reward.drops.healing_potion = 777)
	actor.progression.changed.connect(observer)
	var reward: Dictionary = actor.progression.reward_enemy("soldier", "outer")
	verify(not reward.is_empty() and plan.level == 5 and plan.experience == 0, "one transaction can cross several real levels")
	verify(seen.callbacks > 6 and not seen.partial, "every resource, loadout, level, inventory and growth observer sees whole durable reward")
	verify(not seen.nested and not actor.progression.claimed_rewards.has("nested"), "all final observers reject reentrant enemy rewards")
	verify(not seen.quest_reentry and quests.status("village_patrol") == "available", "shared guard also prevents quest mutation inside reward observers")
	verify(reward.drops.healing_potion == 1 and actor.progression.database.progression.soldier.drops.healing_potion == 1, "reward signal dictionary cannot mutate return value or content")
	verify(not Guard.busy(actor.arena.host.world_state) and actor.progression.last_error.is_empty(), "success releases the shared guard and clears nested error")
	quests.dispose()
	actor.free()
	actor = actor_fixture()
	var before := snapshot(actor)
	verify(Guard.acquire(actor.arena.host.world_state, "trade"), "another adventure service can own transaction guard")
	verify(actor.progression.reward_enemy("soldier", "blocked").is_empty() and snapshot(actor) == before, "foreign transaction blocks reward without consuming a receipt")
	Guard.release(actor.arena.host.world_state, "trade")
	verify(not actor.progression.reward_enemy("soldier", "blocked").is_empty(), "same receipt remains available after foreign transaction ends")
	actor.free()

func _direct_commit_and_local_guard() -> void:
	var actor := actor_fixture()
	actor.progression.experience = 90
	var plan: Dictionary = actor.progression.plan_enemy_reward("soldier", "direct")
	var seen := signals(actor)
	actor.progression.commit_enemy_reward(plan)
	verify(actor.inventory.stacks == plan.stacks and actor.loadout.level == 2 and actor.progression.experience == 30, "default commit applies the entire preflight result")
	verify(seen.inventory == 1 and seen.growth == 1 and seen.reward == 1 and seen.level == 1 and not Guard.busy(actor.arena.host.world_state), "default commit publishes once and releases adventure guard")
	plan = actor.progression.plan_enemy_reward("soldier", "blocked-commit")
	var before := snapshot(actor)
	Guard.acquire(actor.arena.host.world_state, "foreign")
	actor.progression.commit_enemy_reward(plan)
	verify(snapshot(actor) == before and seen.reward == 1, "default commit respects a foreign transaction before assigning anything")
	Guard.release(actor.arena.host.world_state, "foreign")
	actor.free()
	actor = actor_fixture()
	actor.arena = null
	var nested := {"attempted": false, "succeeded": false}
	actor.inventory.changed.connect(func():
		nested.attempted = true
		nested.succeeded = not actor.progression.reward_enemy("ogre", "nested").is_empty())
	verify(not actor.progression.reward_enemy("soldier", "no-arena").is_empty() and nested.attempted and not nested.succeeded, "standalone RPG component still blocks reentry without an adventure host")
	verify(actor.progression.enemy_kills == {"soldier": 1} and not actor.progression.claimed_rewards.has("nested"), "local guard prevents secondary loot and receipts")
	actor.free()

func _form_and_battle() -> void:
	var actor := actor_fixture()
	actor.form = Form.new()
	actor.form.actor = actor
	actor.form.active = true
	actor.combat.state = "ATTACK"
	actor.progression.experience = 80
	var reward: Dictionary = actor.progression.reward_enemy("soldier", "transformed-kill")
	verify(not reward.is_empty() and actor.loadout.level == 2 and actor.progression.experience == 20, "normal kill rewards are allowed during attack and active transformation")
	verify(actor.form.canonical_loadout().level == 2 and actor.inventory.count("healing_potion") == 6, "live canonical loadout and ownership retain transformed-body rewards")
	actor.free()
