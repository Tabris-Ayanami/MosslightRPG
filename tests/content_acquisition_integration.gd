extends "res://tests/frontend_rpg.gd"
## Acquisition integration, NOT a normal-damage playthrough or balance test.
## Real App, merchant controls, nearby NPC dialogue, enemy death transactions,
## progression, book controls and disk reconstruction. Enemies/world timers are
## frozen; teleports and explicit lethal damage isolate acquisition behavior.
## Only the BASE qi_potion stack is temporarily filled to exercise atomic pending
## loot. Candidate items, experience, quest states and death receipts are never
## injected. All preferences/repositories are injected before App enters tree.
## godot --headless --path . --script res://tests/content_acquisition_integration.gd
##   -- --bundle=ABSOLUTE_COMPILED_WILLOW_030
## A packaged run may replace --bundle with --release-root=ABS; pass
## --evidence=ABS for reports/screenshots outside the virtual PCK resource root.
## Add --gpu with a real display only when GPU execution is explicitly scheduled.
const Database = preload("res://combat/combat_database.gd")
const ContentRelease = preload("res://rpg/content_release.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const ITEM := "willow_watch:herb_brew"
const WEAPON := "willow_watch:willow_blade"
const ARMOR := "willow_watch:watch_hood"
const CAREER := "willow_watch:willow_sentinel"
const SKILL := "willow_watch:willow_strike"
const PASSIVE := "willow_watch:willow_step"
const SHOP := "village_supply"
const SOLDIER := "encounter.forest.soldier_01"
const HEAVY := "encounter.forest.heavy_guard_01"
const OGRE := "encounter.forest.ogre_01"
const LETHAL := {"formula": {"base": 1000000}, "can_crit": false, "damage_type": "PHYSICAL"}
var game: Node
var repository: RefCounted
var database: RefCounted
var bundle_path := ""
var release_root := ""
var isolated := ""
var evidence := ""
var stage := "initialization"
var gpu := false
var identity: Dictionary = {}
var trace: Array[Dictionary] = []

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--bundle="): bundle_path = argument.trim_prefix("--bundle=")
		elif argument.begins_with("--release-root="): release_root = argument.trim_prefix("--release-root=")
		elif argument.begins_with("--evidence="): evidence = argument.trim_prefix("--evidence=")
		elif argument == "--gpu": gpu = true
	isolated = OS.get_temp_dir().path_join("mosslight-content-acquisition-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if evidence.is_empty():
		evidence = ProjectSettings.globalize_path("res://.work/content-acquisition-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	elif not evidence.is_absolute_path():
		printerr("--evidence must be an absolute output directory")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(isolated)
	DirAccess.make_dir_recursive_absolute(evidence)
	Preferences.settings_path = isolated.path_join("preferences.cfg")
	call_deferred("_run_at_display_size")

func tap(code: Key) -> void:
	key(code, true)
	await process_frame
	key(code, false)
	await process_frame
	await ticks(2)

func frozen_rewards() -> Dictionary:
	return {"inventory": actor.inventory.export_state(), "progression": actor.progression.export_state(), "counters": game.world_state.export_state().counters}

func note(label: String) -> void:
	var entry := {"event": label, "stage": stage, "level": actor.loadout.level, "xp": actor.progression.experience,
		"items": {ITEM: actor.inventory.count(ITEM), WEAPON: actor.inventory.count(WEAPON), ARMOR: actor.inventory.count(ARMOR)},
		"balance": game.economy.balance(), "patrol": game.quests.status("village_patrol"), "forest": game.quests.status("forest_investigation"),
		"receipts": actor.progression.claimed_rewards.duplicate(true), "kills": actor.progression.enemy_kills.duplicate(true)}
	trace.append(entry)
	print("ACQUISITION ", JSON.stringify(entry))

func freeze_enemies() -> void:
	game.combat_world.set_physics_process(false)
	for enemy: Node in game.combat_world.enemies:
		if is_instance_valid(enemy): enemy.set_physics_process(false)

func reconcile() -> void:
	game.combat_world._tick_encounters(0)
	freeze_enemies()

func body(id: String) -> Node:
	return game.combat_world._encounter_nodes.get(id)

func npc(id: String) -> Node3D:
	for candidate: Node3D in game.narrative_npcs:
		if candidate.definition.id == id: return candidate
	return null

func start_app(snapshot: Dictionary) -> void:
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = repository
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app.selected_save = 0
	app.selected_name = snapshot.name
	app.pending_snapshot = snapshot.duplicate(true)
	app._enter_world(load("res://scenes/main.tscn"))
	check(is_instance_valid(app.game), "real main scene exists after restoring the named adventure")
	if not is_instance_valid(app.game): return
	app._finish_arrival()
	game = app.game
	actor = game.rpg
	game.sound.muted = true
	game.combat_world.encounters_started = true
	freeze_enemies()
	app.ui.modulate.a = 1
	app.ui.region_clock = 0
	await settle()
	if actor.loadout.level > 0:
		app.ui.close_panel(true)
		await settle()
	reconcile()
	check(actor == game.player and app.ui.rpg == actor, "actual App presenter binds its real playable actor")

func reopen(snapshot: Dictionary) -> bool:
	paused = false
	app.selected_save = -1
	app.queue_free()
	await ticks(5)
	app = null
	actor = null
	game = null
	# Rebuild the repository too, using the same explicit disk directory; content
	# remains process-frozen and no Database static field is reset.
	repository = Repository.new(isolated.path_join("adventures"))
	var read: Dictionary = repository.load_slot(0)
	check(read.ok and same(read.snapshot, snapshot), "new Repository reads the exact saved acquisition snapshot from disk")
	if not read.ok: return false
	await start_app(read.snapshot)
	return is_instance_valid(actor)

func same(left: Variant, right: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))

func move_fixture_to(target: Node3D) -> void:
	game._release_actions()
	actor.global_position = target.global_position + Vector3(0, .035, 1.25)
	actor.velocity = Vector3.ZERO
	await ticks(20)
	check(actor.global_position.distance_to(target.global_position) < 2.15, "position fixture places actor within the real NPC interaction radius")

func open_merchant() -> bool:
	var merchant := npc("village_merchant")
	check(is_instance_valid(merchant), "real map contains the authored merchant")
	if not is_instance_valid(merchant): return false
	await move_fixture_to(merchant)
	# Use the actual world interaction menu and F, keeping synthetic pointer focus
	# on the merchant so a desktop cursor cannot change the selected action.
	game.world_ui.set_process(false)
	var point: Vector2 = game.world_to_screen(merchant.global_position + Vector3.UP * 1.1)
	game.world_ui.update_context(.3, point)
	game.world_ui.menu.selected = 0
	var wheel := InputEventMouseButton.new()
	wheel.position = root.get_final_transform() * point
	wheel.global_position = wheel.position
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	Input.parse_input_event(wheel)
	await ticks(2)
	await tap(KEY_F)
	game.world_ui.set_process(true)
	check(game.shop_panel.is_open() and paused and game.paused, "actual merchant action and F open the real paused shop UI")
	return game.shop_panel.is_open()

func shop_select(id: String, selling := false) -> void:
	var panel: Node = game.shop_panel
	(panel.sell_button if selling else panel.buy_button).pressed.emit()
	await ticks(3)
	for index in range(panel._rows.size()):
		if panel._rows[index].id != id: continue
		panel.item_buttons[index].pressed.emit()
		await ticks(3)
		check(panel.selected_id == id, "real shop row selects " + id)
		return
	check(false, "real shop row exists: " + id)

func talk(choice: String) -> bool:
	var warden := npc("village_warden")
	await move_fixture_to(warden)
	game.world_ui.set_process(false)
	game.world_ui.update_context(.3, game.world_to_screen(warden.global_position + Vector3.UP * 1.1))
	game.world_ui.menu.selected = 0
	await tap(KEY_F)
	game.world_ui.set_process(true)
	check(game.dialogue_open(), "nearby F opens the real warden conversation")
	if not game.dialogue_open(): return false
	var chosen := false
	for _step in range(120):
		var panel: Node = game.dialogue_panel
		if not panel.is_open(): return chosen
		if panel._busy or panel.dialogue_line == null:
			await ticks(2)
			continue
		if panel._typing.finished and not panel.dialogue_line.responses.is_empty():
			var selection := -1
			for index in range(panel.dialogue_line.responses.size()):
				var response: Variant = panel.dialogue_line.responses[index]
				if response.is_allowed and response.text == choice: selection = index
			if selection < 0:
				check(false, "requested real dialogue choice is available: " + choice)
				return false
			for _move in range(panel.dialogue_line.responses.size()):
				if panel.menu.selected == selection: break
				await tap(KEY_DOWN)
			chosen = true
		await tap(KEY_ENTER)
		await ticks(2)
	check(false, "real dialogue finishes within its bounded input loop")
	return false

func kill_fixture(id: String) -> void:
	var enemy := body(id)
	check(is_instance_valid(enemy), "eligible authored encounter exists for lethal fixture: " + id)
	if not is_instance_valid(enemy): return
	enemy.combat.receive_damage(LETHAL, actor, Vector3.FORWARD)
	check(enemy.combat.state == "DEAD", "lethal fixture runs actual CombatController death: " + id)

func capture(label: String) -> void:
	if not gpu: return
	game.combat_world.floaters.clear()
	game.floaters.clear()
	await ticks(4)
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(evidence.path_join(label + ".png")) == OK, "real acquisition UI screenshot: " + label)

func run() -> void:
	create_timer(240, true).timeout.connect(func(): check(false, "acquisition watchdog at " + stage); write_report(); quit(1))
	root.size = Vector2i(1280, 720)
	if (release_root.is_empty() and (bundle_path.is_empty() or not bundle_path.is_absolute_path())) or (not release_root.is_empty() and not release_root.is_absolute_path()) or (gpu and DisplayServer.get_name() == "headless"):
		check(false, "supply absolute --bundle or --release-root and use a real display only with --gpu")
		await finish()
		return
	var selected: Dictionary = ContentRelease.activate(release_root, isolated.path_join("releases")) if not release_root.is_empty() else Database.configure_content_bundle(bundle_path)
	check(selected.ok, "acquisition content selects before the first Database: " + str(selected.error))
	if not selected.ok: await finish(); return
	identity = selected.identity
	if not release_root.is_empty():
		check(ContentRelease.is_active() and same(ContentRelease.identity(), identity), "formal release context publishes the exact tested acquisition identity")
	database = Database.new()
	repository = Repository.new(isolated.path_join("adventures"))
	check(database.errors.is_empty() and same(repository.database.identity(), identity), "repository and combat catalogs share the exact compiled identity")
	for pair: Array in [["items", ITEM], ["weapons", WEAPON], ["equipment", ARMOR], ["careers", CAREER], ["skills", SKILL], ["passives", PASSIVE]]:
		check(database.get(pair[0]).has(pair[1]) and database.get_content_icon(pair[0], pair[1]) != null, "real candidate definition and existing image resolve: " + pair[1])
	var created: Dictionary = repository.create("内容获取验收旅人", 0)
	check(created.ok, "create fresh named adventure only in isolated Temp repository")
	if not created.ok: await finish(); return
	await start_app(created.snapshot)
	if not is_instance_valid(actor): await finish(); return
	check(actor.loadout.level == 0 and actor.inventory.stacks.is_empty(), "no sample: actual fresh Lv0 character starts with an empty inventory")
	await click_label("战士")
	check(actor.loadout.career_ids == ["warrior"] and actor.inventory.count("magic_candy") == 0, "native initial career card grants only normal warrior progression")
	check(actor.inventory.count(ITEM) == 0 and actor.inventory.count(WEAPON) == 0 and actor.inventory.count(ARMOR) == 0, "candidate consumable, weapon and armor are not starter grants")
	app.ui.close_panel(true)
	await settle()
	var goods: Dictionary = game.economy.definition(SHOP).get("goods", {})
	print("ACQUISITION_GOODS ", JSON.stringify({ITEM: goods.get(ITEM, {}), WEAPON: goods.get(WEAPON, {}), ARMOR: goods.get(ARMOR, {})}))
	check(same(goods.get(ITEM, {}), {"buy_price": 30, "sell_price": 8, "stock": 6}), "frozen acquisition supplies authored brew prices and finite merchant stock")
	check(same(goods.get(WEAPON, {}), {"sell_price": 45, "stock": 0}) and same(goods.get(ARMOR, {}), {"sell_price": 20, "stock": 0}), "candidate weapon and armor are buyback-only goods with no initial stock")
	check(game.quests.definition("village_patrol").rewards.items.get(ARMOR, 0) == 1 and database.progression.heavy_guard.drops.get(WEAPON, 0) == 1, "actual quest and enemy reward definitions receive the frozen acquisition additions")
	if not failures.is_empty(): await finish(); return
	await purchase()
	if not failures.is_empty(): await finish(); return
	await quest_reward()
	if not failures.is_empty(): await finish(); return
	await pending_enemy_reward()
	if not failures.is_empty(): await finish(); return
	await advancement()
	if not failures.is_empty(): await finish(); return
	await final_roundtrip()
	await finish()

func purchase() -> void:
	stage = "merchant-purchase"
	if not await open_merchant(): return
	var panel: Node = game.shop_panel
	await shop_select("fire_bomb", true)
	panel.quantity.value = 3
	await ticks(3)
	check(not panel.trade_button.disabled and game.economy.balance() == 0, "normal starter bombs can fund the purchase through the real sell UI")
	panel.trade_button.pressed.emit()
	await ticks(3)
	check(game.economy.balance() == 30 and actor.inventory.count("fire_bomb") == 0, "selling three owned base bombs yields exactly 30 copper without injected currency")
	await shop_select(ITEM)
	panel.quantity.value = 1
	await ticks(3)
	check(not panel.trade_button.disabled and panel.total_label.text.contains("30"), "candidate brew is purchasable for its real displayed quote")
	var icon: Texture2D = database.get_content_icon("items", ITEM)
	var row_icon: Texture2D
	for index in range(panel._rows.size()):
		if panel._rows[index].id == ITEM: row_icon = panel.item_buttons[index].icon
	check(icon != null and row_icon == icon and panel.item_icon.texture == icon and panel.item_icon.visible, "real merchant row and visible detail use the exact verified candidate PNG texture")
	var observed: Array[bool] = []
	var observer := func(): observed.append(Guard.busy(game.world_state) and actor.inventory.count(ITEM) == 1 and game.economy.balance() == 0 and game.world_state.get_object("economy.shop." + SHOP).stock[ITEM] == 5)
	actor.inventory.changed.connect(observer)
	panel.trade_button.pressed.emit()
	actor.inventory.changed.disconnect(observer)
	await ticks(4)
	check(not observed.is_empty() and observed.all(func(value: bool): return value), "buy publication exposes item, balance and stock together under the mutation guard")
	check(actor.inventory.count(ITEM) == 1 and game.economy.balance() == 0 and game.world_state.get_object("economy.shop." + SHOP).stock[ITEM] == 5, "merchant purchase consumes 30 copper and one of six brew stock")
	await capture("01-merchant-brew-purchased")
	await shop_select(ITEM, true)
	check(panel._selected_row().price == 8 and not panel.trade_button.disabled, "owned brew receives its authored 8-copper resale quote")
	panel.close_button.pressed.emit()
	await ticks(3)
	note("purchased")

func quest_reward() -> void:
	stage = "npc-patrol-reward"
	check(await talk("我去看看。") and game.quests.status("village_patrol") == "active", "actual NPC response accepts the patrol")
	reconcile()
	kill_fixture(SOLDIER)
	check(game.quests.status("village_patrol") == "ready" and actor.progression.experience == 40 and actor.inventory.count(ARMOR) == 0, "real soldier death produces objective and XP without paying the quest armor early")
	var observed: Array[bool] = []
	var observer := func(): observed.append(Guard.busy(game.world_state) and actor.inventory.count(ARMOR) == 1 and game.quests.status("village_patrol") == "rewarded" and actor.loadout.level == 2 and actor.progression.experience == 0)
	actor.inventory.changed.connect(observer)
	check(await talk("汇报巡路结果。"), "actual NPC reward choice completes the first report")
	actor.inventory.changed.disconnect(observer)
	check(not observed.is_empty() and observed.all(func(value: bool): return value), "quest reward publication combines the hood, reward ledger and normal Lv2 experience atomically")
	check(actor.inventory.count(ARMOR) == 1 and game.quests.status("village_patrol") == "rewarded", "patrol hand-in grants exactly one candidate hood")
	var before := frozen_rewards()
	check(await talk("等我整理好装备。"), "returning to the warden offers the next commission rather than the spent reward")
	check(frozen_rewards() == before, "revisiting the rewarded NPC grants no duplicate armor, XP or enemy receipt")
	check(await talk("我会清查林中的威胁。") and game.quests.status("forest_investigation") == "active", "separate actual dialogue accepts the guard investigation")
	reconcile()
	note("patrol-rewarded")

func pending_enemy_reward() -> void:
	stage = "guard-pending-disk-restore"
	var qi_before: int = actor.inventory.count("qi_potion")
	# Base-item capacity fixture only. No candidate ownership is forged, and
	# removing this fixture later merely restores the previously owned quantity.
	actor.inventory.stacks.qi_potion = 1000000
	var before := frozen_rewards()
	kill_fixture(HEAVY)
	check(game.encounters.record(HEAVY).phase == "pending" and frozen_rewards() == before and actor.inventory.count(WEAPON) == 0, "a full base drop blocks the entire real guard transaction, including the new sword")
	check(not game.chapter.objective_complete("forest_investigation", "break_guard") and not is_instance_valid(body(OGRE)), "unpaid guard death cannot publish the quest event or unlock the boss")
	check(app.save_adventure(), "pending guard and full base stack save through the real App")
	var pending: Dictionary = repository.load_slot(0)
	check(pending.ok, "pending acquisition snapshot passes repository validation")
	if not pending.ok: return
	if not await reopen(pending.snapshot): return
	check(game.encounters.record(HEAVY).phase == "pending" and not is_instance_valid(body(HEAVY)) and actor.inventory.count(WEAPON) == 0 and frozen_rewards() == before, "fresh App reconstructs the unpaid dead life without a body, sword, XP or receipt")
	actor.inventory.stacks.qi_potion = qi_before
	var observed: Array[bool] = []
	var observer := func(): observed.append(Guard.busy(game.world_state) and actor.inventory.count(WEAPON) == 1 and actor.inventory.count("qi_potion") == qi_before + 1 and actor.progression.experience == 70 and game.encounters.record(HEAVY).phase == "cooldown" and game.world_state.get_event_count("enemy_defeated", "heavy_guard") == 1)
	actor.inventory.changed.connect(observer)
	game.combat_world._retry_pending()
	actor.inventory.changed.disconnect(observer)
	check(not observed.is_empty() and observed.all(func(value: bool): return value), "pending settlement publishes original drop, new sword, XP, quest event and encounter phase together")
	check(actor.inventory.count(WEAPON) == 1 and actor.progression.enemy_kills.get("heavy_guard", 0) == 1 and actor.progression.experience == 70, "clearing only the base capacity fixture pays one genuine sword and the normal 70 XP")
	var paid := frozen_rewards()
	game.combat_world._retry_pending()
	check(frozen_rewards() == paid, "settled pending death cannot repeat candidate or ordinary rewards")
	reconcile()
	kill_fixture(OGRE)
	check(actor.loadout.level == 3 and actor.progression.experience == 70, "soldier, patrol, guard and boss rewards naturally total Lv3 plus 70 XP")
	check(actor.inventory.count(WEAPON) == 1 and actor.inventory.count(ARMOR) == 1 and actor.inventory.count(ITEM) == 1, "ordinary later rewards do not duplicate acquisition content")
	note("guard-settled-and-level-three")

func advancement() -> void:
	stage = "candidate-career-and-book"
	if not await open_merchant(): return
	await shop_select(WEAPON, true)
	check(game.shop_panel._selected_row().price == 45 and not game.shop_panel.trade_button.disabled, "earned candidate sword has a real enabled 45-copper buyback quote")
	await shop_select(ARMOR, true)
	check(game.shop_panel._selected_row().price == 20 and not game.shop_panel.trade_button.disabled, "earned candidate hood has a real enabled 20-copper buyback quote")
	game.shop_panel.close_button.pressed.emit()
	await ticks(3)
	app.ui.show_panel("character")
	await settle()
	app.ui._select_career()
	await settle()
	await click_label(str(database.careers[CAREER].name))
	check(actor.loadout.career_ids == ["warrior", CAREER] and PASSIVE in actor.loadout.passive_ids and SKILL in actor.loadout.available_skills, "native progression card selects the linked Lv3 career and grants its actual active/passive definitions")
	app.ui.show_panel("skills")
	await settle()
	await select_skill(SKILL)
	await click_label("研习此招式")
	check(SKILL in actor.loadout.learned_skills, "native skill page explicitly learns the newly granted skill")
	await click_label("备战")
	await ticks(35)
	await click(app.ui.ink_buttons.get(0))
	await ticks(40)
	check(actor.loadout.sets[0].skills[0] == SKILL, "native preparation chooser places the learned candidate skill in A Q")
	await capture("02-candidate-skill-learned")
	app.ui.show_panel("bag")
	await settle()
	await click_label("武器")
	await select_item(WEAPON)
	await click_label("装备至 A")
	await capture("03-earned-sword-equipped")
	await click_label("护具")
	await select_item(ARMOR)
	await click_label("穿戴")
	check(actor.loadout.weapon_at(0).id == WEAPON and actor.loadout.equipment.head == ARMOR, "real bag equips only the sword and hood already earned through acquisition")
	check(actor.stats.modifiers.equipment_head == database.equipment[ARMOR].modifiers, "earned hood applies its authored equipment modifiers")
	await capture("04-earned-hood-equipped")
	actor.resources.change("Energy", -actor.resources.current("Energy"))
	actor.combat.passives.trigger("perfect_dodge", actor.combat.context())
	check(is_equal_approx(actor.resources.current("Energy"), 10.0) and actor.combat.passives.internal_cooldowns.get(PASSIVE, 0) == 6, "controlled perfect-dodge event executes the acquired passive's authored 10 Energy and six-second cooldown")
	actor.combat.passives.trigger("perfect_dodge", actor.combat.context())
	check(is_equal_approx(actor.resources.current("Energy"), 10.0), "acquired passive cooldown prevents a duplicate immediate event reward")
	app.ui.close_panel(true)
	await settle()
	note("candidate-equipped-and-learned")

func final_roundtrip() -> void:
	stage = "complete-app-reconstruction"
	check(app.save_adventure(), "fully acquired character saves through real App")
	var saved: Dictionary = repository.load_slot(0)
	check(saved.ok and same(saved.snapshot.content_set, identity), "disk snapshot carries the exact acquisition bundle identity")
	if not saved.ok: return
	var inventory: Dictionary = actor.inventory.export_state()
	var progression: Dictionary = actor.progression.export_state()
	var loadout: Dictionary = actor.loadout.export_state()
	var stock: Dictionary = game.world_state.get_object("economy.shop." + SHOP)
	if not await reopen(saved.snapshot): return
	check(same(actor.inventory.export_state(), inventory) and same(actor.progression.export_state(), progression), "fresh App restores owned quantities, experience and every reward receipt unchanged")
	check(same(actor.loadout.export_state(), loadout) and same(actor.loadout.database.identity(), identity), "fresh App restores candidate career, learned/prepared skill, equipment and content identity")
	check(game.world_state.get_object("economy.shop." + SHOP) == stock and actor.inventory.count(ITEM) == 1 and actor.inventory.count(ARMOR) == 1 and actor.inventory.count(WEAPON) == 1, "merchant finite stock and three separately earned candidate items persist")
	check(game.quests.status("village_patrol") == "rewarded" and game.world_state.get_event_count("enemy_defeated", "heavy_guard") == 1, "quest and enemy acquisition ledgers survive complete reconstruction")
	var before := frozen_rewards()
	game.combat_world._retry_pending()
	check(frozen_rewards() == before, "reconstructed reward reconciliation cannot pay a second sword or hood")
	check(Preferences.settings_path.begins_with(isolated + "/") and repository.directory.begins_with(isolated + "/"), "preferences and every reconstructed repository remain inside this isolated Temp workspace")
	check(app.save_adventure(), "reconstructed acquired character remains saveable")
	note("restored-complete")

func write_report() -> void:
	var report := {"ok": failures.is_empty(), "checks": checks, "failures": failures, "stage": stage, "bundle": bundle_path, "release_root": release_root, "formal_release": ContentRelease.is_active(), "identity": identity, "isolated": isolated, "evidence": evidence, "gpu": gpu, "renderer": RenderingServer.get_current_rendering_method(), "trace": trace,
		"fixture_limits": ["enemy physics and encounter timers frozen", "near-NPC teleports", "automatic lethal damage", "temporary full base qi_potion stack", "controlled perfect_dodge passive event", "not normal-damage combat or human balance acceptance"]}
	var file := FileAccess.open(evidence.path_join("report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("CONTENT_ACQUISITION %d/%d report=%s" % [checks - failures.size(), checks, evidence.path_join("report.json")])

func finish() -> void:
	write_report()
	paused = false
	if is_instance_valid(app):
		app.selected_save = -1
		app.queue_free()
	await ticks(4)
	quit(0 if failures.is_empty() else 1)
