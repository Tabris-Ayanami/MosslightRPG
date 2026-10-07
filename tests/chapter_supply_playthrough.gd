extends "res://tests/chapter_playthrough.gd"
## Actual early-chapter supply route. Reuses the ordinary warrior controller and
## map walking, but never calls the base run (which accelerates its own clock).
## No item/money/resource/position fixtures, direct damage, or altered enemy AI.
## Godot --headless --path . --script tests/chapter_supply_playthrough.gd -- --evidence=ABS
const SUPPLY_SHOP := "village_supply"
const SPARE_SWORD := "iron_longsword"
const PURCHASE := "spell_potion"
const WAYSTONE := "prop.garden_waystone"
var supply_events: Array[Dictionary] = []
var initial_swords := 0
var initial_equipped := 0
var earned_swords := 0
var saved_supply: Dictionary = {}

func _initialize() -> void:
	output = ProjectSettings.globalize_path("res://.work/chapter-supply-playthrough/run-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	super._initialize()

func run() -> void:
	watchdog = create_timer(900, true, false, true)
	watchdog.timeout.connect(_watchdog)
	check(career == "warrior", "supply route uses the unchanged normal warrior policy")
	check(is_equal_approx(Engine.time_scale, 1.0) and Engine.physics_ticks_per_second == 60, "supply route retains the default world clock and 60 Hz physics")
	if not failures.is_empty(): await finish(false); return
	seed(seed_value)
	adventure_name = "巡路后的补给"
	repo = Repo.new(isolated.path_join("adventures"))
	var created: Dictionary = repo.create(adventure_name, 0)
	check(created.get("ok", false), "create a fresh isolated supply adventure")
	if not created.get("ok", false): await finish(false); return
	await enter_app(created.snapshot)
	check(actor.loadout.level == 0 and actor.inventory.count(SPARE_SWORD) == 0 and game.economy.balance() == 0, "fresh adventure has no career sword or injected copper")
	if not await prepare_supply_warrior(): await finish(false); return
	initial_swords = actor.inventory.count(SPARE_SWORD)
	initial_equipped = actor.inventory.equipped_count(SPARE_SWORD)
	check(initial_swords == 1 and initial_equipped == 1, "normal warrior starts with one owned and equipped iron longsword, no spare")
	if not failures.is_empty(): await finish(false); return
	if not await village("first-visit"): await finish(false); return
	if not await talk("我去看看。", "supply-patrol-accept"): await finish(false); return
	check(game.quests.status("village_patrol") == "active", "real warden dialogue accepts the patrol")
	if not await forest_gate("supply-patrol-departure"): await finish(false); return
	if not await fight(SOLDIER): await finish(false); return
	check(earned_swords >= 1 and actor.inventory.count(SPARE_SWORD) >= initial_swords + 1, "actual soldier reward signal and inventory contain the earned spare sword")
	check(actor.inventory.equipped_count(SPARE_SWORD) == initial_equipped, "earned sword remains a spare while the starter sword stays equipped")
	if not failures.is_empty(): await finish(false); return
	if not await village("supply-patrol-return"): await finish(false); return
	if not await talk("汇报巡路结果。", "supply-patrol-report"): await finish(false); return
	check(game.quests.status("village_patrol") == "rewarded", "normal patrol hand-in completes before visiting the merchant")
	if not await merchant_supply(): await finish(false); return
	if not await return_to_waystone(): await finish(false); return
	if not await save_and_rebuild_supply(): await finish(false); return
	await finish(failures.is_empty())

func prepare_supply_warrior() -> bool:
	set_stage("supply-career-study")
	await click_label("战士")
	await select_skill(skill_id)
	await click_label("研习此招式")
	await click_label("备战")
	await ticks(45)
	await click(app.ui.ink_buttons.get(0))
	for _frame in range(90):
		if not app.ui.ink_open and app.ui.ink_progress <= 0: break
		await process_frame
	await process_frame
	await close_book()
	check(app.ui.panel.is_empty() and not paused and not game.paused, "native preparation chooser and book close before walking")
	check(actor.loadout.career_ids == ["warrior"] and actor.loadout.sets[0].skills[0] == skill_id and skill_id in actor.loadout.learned_skills, "native book chooses warrior, studies thrust, and prepares Q")
	check(actor.inventory.count("magic_candy") == 0 and not actor.resources.unlimited.get("Energy", false) and not actor.resources.unlimited.get("Stamina", false), "adventure has no debug candy or unlimited combat resources")
	prepared = {"weapon": actor.loadout.weapon().id, "skill": actor.skill_at(0).duplicate(true), "ledger": ledger_snapshot(), "resources": resource_snapshot()}
	note("supply_prepared", prepared)
	return failures.is_empty()

func _enemy_reward(enemy_id: String, reward: Dictionary) -> void:
	super._enemy_reward(enemy_id, reward)
	if enemy_id == "soldier": earned_swords += int(reward.get("drops", {}).get(SPARE_SWORD, 0))

func merchant_supply() -> bool:
	set_stage("supply-merchant-approach")
	# Follow the open front of the village stalls; do not cut behind the buildings.
	for point in [Vector3(0, 2.3, -29.5), Vector3(4.5, 2.3, -31.2)]:
		if not await walk(point, .45): return false
	move_towards(Vector3.ZERO)
	game.aim_override = null
	await ticks(15)
	var merchant: Node3D
	for npc in game.narrative_npcs:
		if str(npc.definition.id) == "village_merchant": merchant = npc
	check(is_instance_valid(merchant) and game.nearest_interactable() == merchant, "ordinary walking reaches the actual merchant's interaction range")
	if not is_instance_valid(merchant) or game.nearest_interactable() != merchant: return false
	# Pin only the menu's screen-pointer sampling during this physical wheel/F
	# gesture, as in world_economy_integration. AI and world physics keep running.
	var ui_was_processing: bool = game.world_ui.is_processing()
	game.world_ui.set_process(false)
	var point: Vector2 = game.world_to_screen(merchant.global_position + Vector3.UP * 1.1)
	game.world_ui.update_context(.3, point)
	var menu: Control = game.world_ui.menu
	var trade_index := -1
	for index in menu.entries.size():
		if str(menu.entries[index].id) == "trade": trade_index = index
	check(game.world_ui.target == merchant and game.world_ui.pointed_object == merchant and trade_index >= 0, "pointing at the merchant exposes the native trade choice")
	if trade_index >= 0:
		for _step in range(menu.entries.size()):
			if menu.selected == trade_index: break
			var wheel := InputEventMouseButton.new()
			wheel.position = root.get_final_transform() * point
			wheel.global_position = wheel.position
			wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN if menu.selected < trade_index else MOUSE_BUTTON_WHEEL_UP
			wheel.pressed = true
			Input.parse_input_event(wheel)
			await process_frame
		if menu.selected == trade_index: await tap(KEY_F)
	game.world_ui.set_process(ui_was_processing)
	await ticks(3)
	check(game.shop_panel.is_open() and game.world_modal_open() and paused and game.paused, "native wheel selection and F open the paused merchant UI")
	if not game.shop_panel.is_open():
		note("supply_shop_not_open", {"error": game.interactions.last_error, "toast": game.toast_text})
		return false
	set_stage("supply-sell-spare")
	var panel: CanvasLayer = game.shop_panel
	if not await press_shop_button(panel.sell_button, "sell tab"): return false
	if not await select_shop_item(SPARE_SWORD): return false
	panel.quantity.value = 1
	await ticks(2)
	var goods: Dictionary = game.economy.definition(SUPPLY_SHOP).goods
	var sell_price := int(goods[SPARE_SWORD].sell_price)
	var sale_before: Dictionary = supply_snapshot()
	var row: Dictionary = panel._selected_row()
	check(int(row.get("price", -1)) == sell_price and panel.total_label.text == "获得  %d 铜币" % sell_price and panel.amounts.text.contains("单价  %d 铜币" % sell_price), "sale UI displays the authored catalog price and quantity-one total")
	check(int(row.get("sellable", 0)) == actor.inventory.count(SPARE_SWORD) - actor.inventory.equipped_count(SPARE_SWORD) and int(row.get("sellable", 0)) >= 1, "sale UI excludes the equipped sword from available copies")
	await supply_capture("01-sell-earned-sword")
	if not await press_shop_button(panel.trade_button, "confirm sale of one spare sword"): return false
	var sale_after: Dictionary = supply_snapshot()
	var expected_sale_stacks: Dictionary = sale_before.stacks.duplicate(true)
	expected_sale_stacks[SPARE_SWORD] = int(expected_sale_stacks[SPARE_SWORD]) - 1
	check(int(sale_after.balance) == int(sale_before.balance) + sell_price and int(sale_after.stacks.get(SPARE_SWORD, 0)) == int(sale_before.stacks[SPARE_SWORD]) - 1, "UI sale exchanges exactly one earned spare for its catalog value")
	check(sale_after.stacks == expected_sale_stacks, "selling the spare changes no other inventory item")
	check(sale_after.loadout == sale_before.loadout and actor.inventory.equipped_count(SPARE_SWORD) == initial_equipped, "sale leaves the equipped weapon and complete prepared loadout unchanged")
	check(sale_after.stock == sale_before.stock, "selling a spare does not silently restock merchant goods")
	record_supply("sale", {"item": SPARE_SWORD, "quantity": 1, "price": sell_price, "before": sale_before, "after": sale_after})
	if not failures.is_empty(): return false
	set_stage("supply-buy-potion")
	if not await press_shop_button(panel.buy_button, "buy tab"): return false
	if not await select_shop_item(PURCHASE): return false
	panel.quantity.value = 1
	await ticks(2)
	var buy_price := int(goods[PURCHASE].buy_price)
	var buy_before: Dictionary = supply_snapshot()
	row = panel._selected_row()
	check(int(row.get("price", -1)) == buy_price and panel.total_label.text == "需付  %d 铜币" % buy_price and panel.amounts.text.contains("单价  %d 铜币" % buy_price), "purchase UI displays the current catalog price, without a hard-coded old price")
	check(int(buy_before.balance) >= buy_price and int(row.get("stock", 0)) > 0, "earned sale proceeds cover one stocked energy potion")
	await supply_capture("02-buy-energy-potion")
	if not await press_shop_button(panel.trade_button, "confirm potion purchase"): return false
	var buy_after: Dictionary = supply_snapshot()
	var expected_buy_stacks: Dictionary = buy_before.stacks.duplicate(true)
	expected_buy_stacks[PURCHASE] = int(expected_buy_stacks.get(PURCHASE, 0)) + 1
	var expected_stock: Dictionary = buy_before.stock.duplicate(true)
	expected_stock[PURCHASE] = int(expected_stock[PURCHASE]) - 1
	check(int(buy_after.balance) == int(buy_before.balance) - buy_price and int(buy_after.stacks.get(PURCHASE, 0)) == int(buy_before.stacks.get(PURCHASE, 0)) + 1, "UI purchase spends exactly the displayed copper and grants one potion")
	check(int(buy_after.stock.get(PURCHASE, -1)) == int(buy_before.stock[PURCHASE]) - 1, "UI purchase decrements finite shelf stock by one")
	check(buy_after.stacks == expected_buy_stacks and buy_after.stock == expected_stock, "purchase leaves all unrelated inventory and stock unchanged")
	check(panel.balance_label.text == "钱袋  %d 铜币" % int(buy_after.balance), "merchant UI refreshes the actual remaining wallet")
	record_supply("purchase", {"item": PURCHASE, "quantity": 1, "price": buy_price, "before": buy_before, "after": buy_after})
	await tap(KEY_ESCAPE)
	check(not game.world_modal_open() and not paused and not game.paused, "Escape closes only the shop and resumes normal world time")
	return failures.is_empty()

func press_shop_button(button: Button, label: String) -> bool:
	var usable := is_instance_valid(button) and button.is_visible_in_tree() and not button.disabled
	check(usable, "native shop button available: " + label)
	if not usable: return false
	button.pressed.emit()
	await ticks(2)
	return true

func select_shop_item(id: String) -> bool:
	for button: Button in game.shop_panel.item_buttons:
		if button.name == "ShopItem_" + id.validate_node_name():
			return await press_shop_button(button, "select " + id)
	check(false, "native shop item exists: " + id)
	return false

func return_to_waystone() -> bool:
	set_stage("supply-waystone-return")
	for point in [Vector3(4.5, 2.3, -29.5), Vector3(0, 2.3, -26), Vector3(0, 2.3, -12), Vector3(.5, 2.3, -8.5), Vector3(.5, 2.3, -3.8), Vector3(.5, 2.3, 1.7), Vector3(2.0, 2.3, 4.4), Vector3(4.4, 2.3, 4.4)]:
		if not await walk(point, .6): return false
	move_towards(Vector3.ZERO)
	game.aim_override = null
	await ticks(12)
	var shrine: Node3D = game.nearest_interactable()
	check(is_instance_valid(shrine) and str(shrine.get("persistent_id")) == WAYSTONE, "ordinary return walk reaches the authored garden waystone")
	if not is_instance_valid(shrine) or str(shrine.get("persistent_id")) != WAYSTONE: return false
	# A real charge consumes one Stamina even out of combat. This creates a
	# reproducible need for rest without injecting damage or editing resources.
	set_stage("supply-waystone-rest")
	var paid_before := float(spent_totals.get("Stamina", 0))
	Input.action_press("attack_primary")
	await ticks(42)
	Input.action_release("attack_primary")
	await ticks(2)
	for _frame in range(180):
		if actor.combat.can_start(): break
		await ticks(1)
	var rest_before: Dictionary = resource_snapshot()
	check(float(spent_totals.get("Stamina", 0)) > paid_before and actor.resources.current("Stamina") < actor.resources.max_value("Stamina"), "normal charged attack pays real Stamina before resting")
	if not failures.is_empty(): return false
	var point: Vector2 = game.world_to_screen(shrine.global_position + Vector3.UP)
	game.world_ui.update_context(.3, point)
	await tap(KEY_F)
	check(game.world_state.get_object(WAYSTONE).get("activated", false) and shrine.activated, "physical F activates the actual waystone")
	for resource in ["HP", "Stamina", "Energy"]:
		check(is_equal_approx(actor.resources.current(resource), actor.resources.max_value(resource)), "waystone restores full " + resource)
	check(actor.spawn_point.is_equal_approx(game.checkpoint), "rest records the actor's normal respawn checkpoint")
	record_supply("rest", {"before": rest_before, "after": resource_snapshot(), "stamina_paid": float(spent_totals.get("Stamina", 0)) - paid_before, "checkpoint": str(game.checkpoint), "toast": game.toast_text})
	await supply_capture("03-waystone-restored")
	return failures.is_empty()

func save_and_rebuild_supply() -> bool:
	set_stage("supply-save-rebuild")
	move_towards(Vector3.ZERO)
	saved_supply = supply_snapshot()
	check(app.save_adventure(), "normal App save commits the completed supply route")
	if not failures.is_empty(): return false
	var old_app: WeakRef = weakref(app)
	app.selected_save = -1
	app.queue_free()
	await ticks(6)
	actor = null
	game = null
	app = null
	check(old_app.get_ref() == null, "old App is fully freed before rebuilding the adventure")
	last_position = Vector3.INF
	repo = Repo.new(isolated.path_join("adventures"))
	var loaded: Dictionary = repo.load_slot(0)
	check(loaded.get("ok", false), "a new repository instance reads the adventure from isolated disk")
	if not loaded.get("ok", false): return false
	await enter_app(loaded.snapshot)
	var reopened: Dictionary = supply_snapshot()
	check(reopened.balance == saved_supply.balance and same_disk_record(reopened.wallet, saved_supply.wallet), "rebuilt App preserves exact wallet balance and transaction revision")
	check(reopened.stacks == saved_supply.stacks and reopened.quickslots == saved_supply.quickslots, "rebuilt App preserves all earned, sold, and purchased inventory and quickslots")
	check(reopened.stock == saved_supply.stock and same_disk_record(reopened.shop, saved_supply.shop), "rebuilt App preserves the merchant's remaining finite stock")
	check(reopened.loadout == saved_supply.loadout and reopened.progression == saved_supply.progression and reopened.patrol == saved_supply.patrol, "rebuilt App preserves the normally earned career, learned skill, XP, and quest hand-in")
	check(same_disk_record(reopened.waystone, saved_supply.waystone) and reopened.checkpoint == saved_supply.checkpoint, "rebuilt App preserves waystone activation and the recorded checkpoint")
	record_supply("rebuild", {"before": saved_supply, "after": reopened})
	return failures.is_empty()

func same_disk_record(actual: Dictionary, expected: Dictionary) -> bool:
	# JSON has one number type: raw WorldState fields read as floats, while the
	# freshly committed record uses ints. Round-trip both complete records so
	# equality still checks every key/value, including transaction revisions.
	return JSON.parse_string(JSON.stringify(actual)) == JSON.parse_string(JSON.stringify(expected))

func supply_snapshot() -> Dictionary:
	var stock: Dictionary = {}
	for row: Dictionary in game.economy.entries(SUPPLY_SHOP, "buy"): stock[str(row.id)] = int(row.stock)
	return {"balance": game.economy.balance(), "wallet": game.world_state.get_object("economy.wallet").duplicate(true), "shop": game.world_state.get_object("economy.shop." + SUPPLY_SHOP).duplicate(true), "stock": stock, "stacks": actor.inventory.stacks.duplicate(true), "quickslots": actor.inventory.quickslots.duplicate(), "loadout": actor.loadout.export_state(), "progression": actor.progression.export_state(), "patrol": game.quests.status("village_patrol"), "waystone": game.world_state.get_object(WAYSTONE).duplicate(true), "checkpoint": str(game.checkpoint)}

func record_supply(kind: String, details: Dictionary) -> void:
	var entry := details.duplicate(true)
	entry["event"] = kind
	entry["seconds"] = simulated
	supply_events.append(entry)
	note("supply_" + kind, details)

func supply_capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(label + ".png"))

func fingerprints() -> Dictionary:
	var result: Dictionary = super.fingerprints()
	for path in ["tests/chapter_supply_playthrough.gd", "scripts/frontend/shop_panel.gd", "rpg/economy_service.gd", "rpg/world_objects.gd", "data/world/objects.json"]:
		result[path] = FileAccess.get_sha256("res://" + path)
	return result

func finish(success: bool) -> void:
	if finished: return
	finished = true
	if watchdog != null and watchdog.timeout.is_connected(_watchdog): watchdog.timeout.disconnect(_watchdog)
	watchdog = null
	if is_instance_valid(game): move_towards(Vector3.ZERO)
	Input.action_release("attack_primary")
	var passed := success and failures.is_empty()
	note("SUPPLY_COMPLETE" if passed else "SUPPLY_BLOCKED", {"checks": checks, "failures": failures})
	if not phase_records.is_empty():
		phase_records[-1]["end"] = state()
		phase_records[-1]["ledger_end"] = ledger_snapshot() if is_instance_valid(actor) else {}
	var report := {"ok": passed, "checks": checks, "failures": failures, "career": career, "seed": seed_value, "isolated": isolated, "evidence": output, "argv": OS.get_cmdline_user_args(), "wall_seconds": float(Time.get_ticks_msec() - started_wall) / 1000.0, "simulated_seconds": simulated, "time_scale": Engine.time_scale, "physics_ticks_per_second": Engine.physics_ticks_per_second, "end": state(), "prepared": prepared, "stages": phase_records, "combats": combat_records, "enemy_rewards": reward_events, "actions": action_events, "resource_spent": spent_totals, "resource_spent_events": spent_events, "items_used": item_uses, "deaths": deaths, "respawns": respawns_seen, "earned_swords": earned_swords, "supply_events": supply_events, "source_sha256": fingerprints(), "scope": "New warrior adventure through actual career/study UI, unchanged ordinary chapter warrior combat and InputMap walking, first patrol hand-in, physical merchant wheel/F, native sell/buy controls, physical F waystone rest, and full App/repository disk rebuild. No complete-chapter or manual-play claim. No money/items/resources/position injection, direct damage, changed enemy AI, cooldown skipping, or modified world clock. A normal charged attack creates the Stamina deficit before rest; only merchant pointer sampling is briefly pinned during the input gesture."}
	var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report, "  ")); file.close()
	if is_instance_valid(app): app.selected_save = -1; app.queue_free()
	await ticks(4)
	actor = null
	game = null
	app = null
	print("CHAPTER_SUPPLY ", "PASS" if passed else "BLOCKED", " evidence=", output)
	quit(0 if passed else 1)
