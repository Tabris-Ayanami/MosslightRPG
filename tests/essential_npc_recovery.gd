extends SceneTree
## Actual map, NPCs, combat, F interaction, dialogue, trade and save migration.
## Preferences and every repository path are OS-temp before any scene enters tree.
const Preferences = preload("res://rpg/game_preferences.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const Interactions = preload("res://rpg/world_interactions.gd")
var game: Node
var repo: RefCounted
var baseline: Dictionary
var checks := 0
var failures: Array[String] = []
var reentry_checks: Array[bool] = []
var publications := 0

func _initialize() -> void: call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
	print("PASS " if value else "FAIL ", label)

func ticks(count := 3) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame

func npc(id: String) -> Node3D:
	for candidate in game.narrative_npcs:
		if candidate.definition.id == id: return candidate
	return null

func seed_for(caught: bool) -> int:
	var probe := RandomNumberGenerator.new()
	for value in range(100):
		probe.seed = value
		if (probe.randf() < .42) == caught: return value
	return -1

func move_near(villager: Node3D) -> void:
	game.player.global_position = villager.spawn_point + Vector3(0, .03, 1.4)
	game.player.velocity = Vector3.ZERO
	game.player.move_direction = Vector3.ZERO
	game.world_ui.target = null
	game.world_ui.menu.hide()

func load_record(villager: Node3D, defeated: bool, legacy := true) -> void:
	var incoming: Dictionary = baseline.duplicate(true)
	incoming.world_state.objects[villager.social_id()] = {"version":1,"kind":"npc","attempted":true,"hostile":true,"defeated":defeated}
	if legacy:
		incoming.version = 4
		incoming.erase("content_set")
	check(repo.restore(incoming, game.player, game).ok, "legacy five-field NPC record restores before recovery")
	for enemy in game.combat_world.enemies: enemy.ai_enabled = false
	villager.ai_enabled = false
	move_near(villager)
	await ticks(20)

func player_resources() -> Dictionary:
	var result := {}
	for key in ["HP", "Stamina", "Energy"]: result[key] = game.player.resources.current(key)
	return result

func run() -> void:
	create_timer(120, true).timeout.connect(func(): printerr("ESSENTIAL_NPC_RECOVERY timeout"); quit(2))
	var isolated := OS.get_temp_dir().path_join("mosslight-essential-npc-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	Preferences.settings_path = isolated + ".cfg"
	repo = Repository.new(isolated)
	var created: Dictionary = repo.create("必要村民恢复验证")
	check(created.ok, "create an exclusive OS-temp adventure before scene setup")
	if not created.ok: quit(1); return
	baseline = created.snapshot.duplicate(true)
	root.size = Vector2i(1280, 720)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.sound.muted = true
	await ticks(20)
	var warden := npc("village_warden")
	var merchant := npc("village_merchant")
	check(is_instance_valid(warden) and is_instance_valid(merchant) and warden.is_essential() and merchant.is_essential(), "authored quest and trade villagers explicitly opt into recovery")
	if not is_instance_valid(warden) or not is_instance_valid(merchant): quit(1); return
	await load_record(warden, false)
	check(game.player.inventory.stacks.is_empty() and game.economy.balance() == 0, "legacy recovery remains possible with no career, items or currency")
	check(warden.hostile and game.interactions.actions(warden)[0].id == "reconcile" and warden.marker.visible, "old hostile NPC exposes a visible reconciliation action")
	check(not game.begin_dialogue(warden.definition, warden), "hostility still blocks ordinary dialogue before reconciliation")
	game.player.resources.change("HP", -7)
	game.player.combat.engage()
	warden.combat.engage()
	check(warden.combat.weapon_action("PRIMARY_TAP"), "real hostile NPC can begin an actual attack before the player apologizes")
	var hp: Dictionary = player_resources()
	var before_inventory: Dictionary = game.player.inventory.export_state()
	var before_wallet: Dictionary = game.world_state.get_object("economy.wallet")
	var observer := func(id: String) -> void:
		if id != warden.social_id(): return
		publications += 1
		reentry_checks.append(Guard.busy(game.world_state))
		reentry_checks.append(not game.interactions.execute(warden, "reconcile"))
		reentry_checks.append(not repo.restore(baseline, game.player, game).ok)
		reentry_checks.append(not warden.hostile and not warden.dead and game.world_state.get_object(id).attempted)
	game.world_state.object_changed.connect(observer)
	var interact := InputEventAction.new()
	interact.action = "interact"
	interact.pressed = true
	game._unhandled_input(interact)
	game.world_state.object_changed.disconnect(observer)
	check(not warden.hostile and not warden.dead and warden.control_mode == "none", "real F dispatch reconciles while both parties are still in combat")
	check(not warden.combat.runner.busy() and warden.current_target == null and not game.combat_world.are_hostile(warden, game.player), "reconciliation cancels the pending attack, target and faction hostility")
	check(game.player.combat.in_combat and player_resources() == hp, "reconciliation does not heal the player or erase their combat timer")
	check(game.player.inventory.export_state() == before_inventory and game.world_state.get_object("economy.wallet") == before_wallet, "free reconciliation makes no hidden item or currency charge")
	check(publications == 1 and reentry_checks.size() == 4 and false not in reentry_checks and not Guard.busy(game.world_state) and game.interactions.last_error.is_empty(), "one atomic publication rejects reentry and restore until the guard releases, without leaving a stale error")
	check(not game.interactions.execute(warden, "reconcile") and publications == 1, "repeated recovery cannot create another transaction")
	check(game.world_state.get_object(warden.social_id()) == {"version":1,"kind":"npc","attempted":true,"hostile":false,"defeated":false}, "recovered record retains the spent theft opportunity without changing its schema")
	check(not game.interactions.execute(warden, "steal"), "reconciliation never refreshes theft loot")
	check(game.player.progression.choose_career("warrior"), "normal career progression still works after recovering an old hostile NPC")
	check(game.begin_dialogue(warden.definition, warden), "actual warden dialogue opens again after reconciliation")
	await ticks(5)
	check(game.dialogue_open() and game.quests.accept("village_patrol"), "main quest can be accepted while restored NPC dialogue is open")
	game.close_world_modal()
	await ticks(3)
	game.player.combat.reset()
	var saved: Dictionary = repo.save(0, "必要村民恢复验证", game.player, game)
	check(saved.ok, "reconciled NPC and active main quest pass the real save validator")
	if not saved.ok: printerr(saved.error); await finish(); return
	baseline = saved.snapshot.duplicate(true)
	await load_record(merchant, true)
	check(merchant.dead and merchant.hostile and merchant.control_mode == "none", "legacy defeated merchant stays wounded until explicitly helped")
	check(merchant.global_position.distance_to(merchant.spawn_point) < .15 and merchant.marker.visible and merchant.marker.text == "援", "defeated essential NPC is visible at the reachable village home")
	check(game.interactions.available(merchant) and game.nearest_interactable() == merchant and game.interactions.actions(merchant)[0].label.contains("救助"), "dead collision does not remove the physical recovery target")
	check(not game.begin_shop(merchant), "wounded merchant still cannot trade before aid")
	game.player.global_position += Vector3(0,0,10)
	var record: Dictionary = game.world_state.get_object(merchant.social_id())
	check(not game.interactions.execute(merchant,"reconcile") and game.world_state.get_object(merchant.social_id()) == record, "remote recovery fails without changing persistent state")
	move_near(merchant)
	Guard.acquire(game.world_state,"test.essential")
	check(not game.interactions.execute(merchant,"reconcile") and merchant.dead, "a competing adventure mutation prevents recovery")
	Guard.release(game.world_state,"test.essential")
	merchant.definition.essential = false
	check(game.interactions.actions(merchant).is_empty() and not game.interactions.execute(merchant,"reconcile"), "nonessential NPCs do not inherit the special recovery rule")
	merchant.definition.essential = true
	before_inventory = game.player.inventory.export_state()
	before_wallet = game.world_state.get_object("economy.wallet")
	check(game.interactions.execute(merchant,"reconcile"), "helping a legacy defeated merchant succeeds")
	check(not merchant.dead and not merchant.hostile and merchant.resources.current("HP") > 0 and (merchant.collision_layer & 1) != 0, "aid restores a living, neutral, solid merchant")
	check(game.player.inventory.export_state() == before_inventory and game.world_state.get_object("economy.wallet") == before_wallet, "aid consumes neither money nor healing items")
	check(game.begin_shop(merchant), "actual merchant shop opens again")
	var quote: Dictionary = game.economy.quote_sell("village_supply", "healing_potion", 1)
	check(quote.ok and game.economy.trade(quote), "restored merchant can complete a real inventory/currency trade")
	game.close_world_modal()
	await ticks(3)
	saved = repo.save(0, "必要村民恢复验证", game.player, game)
	var loaded: Dictionary = repo.load_slot(0)
	check(saved.ok and loaded.ok and repo.restore(loaded.snapshot,game.player,game).ok and not merchant.dead and not merchant.hostile and game.quests.status("village_patrol") == "active", "recovery, commerce and quest progress survive loading the actual isolated save file")
	# New theft must retain both original outcomes, including actual combat death.
	check(repo.restore(baseline,game.player,game).ok,"restore neutral merchant fixture for new theft")
	merchant.ai_enabled = false
	move_near(merchant)
	game.player.combat.reset()
	var potions: int = game.player.inventory.count("healing_potion")
	game.interactions.rng.seed = seed_for(false)
	check(game.interactions.execute(merchant,"steal") and game.player.inventory.count("healing_potion") == potions + 1 and not merchant.hostile,"successful theft still grants exactly one potion")
	check(not game.interactions.execute(merchant,"steal"),"successful theft remains one-shot")
	check(repo.restore(baseline,game.player,game).ok,"restore neutral merchant fixture for caught theft")
	merchant.ai_enabled = false
	move_near(merchant)
	game.player.combat.reset()
	game.interactions.rng.seed = seed_for(true)
	check(game.interactions.execute(merchant,"steal") and merchant.hostile and merchant.control_mode == "ai", "caught theft retains actual hostile combat behavior")
	var events: int = game.world_state.get_event_count("enemy_defeated")
	merchant.global_position += Vector3(7,0,3)
	merchant.combat.receive_damage({"formula":{"base":999999},"can_crit":false,"damage_type":"PHYSICAL"},game.player,Vector3.FORWARD)
	check(merchant.dead and game.world_state.get_object(merchant.social_id()).defeated and merchant.global_position.distance_to(merchant.spawn_point) < .01, "actual lethal damage leaves a persistent wounded NPC back at their village home")
	check(game.world_state.get_event_count("enemy_defeated") == events, "villager defeat does not farm quest kills or enemy rewards")
	move_near(merchant)
	game.player.combat.state = "NORMAL"
	check(game.interactions.execute(merchant,"reconcile") and not merchant.dead and not merchant.hostile, "newly defeated essential NPC also recovers during the combat timer")
	check(Interactions.validate_snapshot(game.world_state.export_state()).is_empty(), "final recovered records remain compatible with existing world validation")
	await finish()

func finish() -> void:
	paused = false
	if is_instance_valid(game): game.queue_free()
	await ticks(6)
	print("ESSENTIAL_NPC_RECOVERY %d/%d passed" % [checks - failures.size(),checks])
	quit(0 if failures.is_empty() else 1)
