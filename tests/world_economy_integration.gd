extends SceneTree
## Real frontend + physical merchant + persistent chest + authoritative commerce.
## All disk IO and preferences are isolated before the frontend enters the tree.
const Preferences = preload("res://rpg/game_preferences.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const OUT := "res://docs/world-economy/"
var app: Node
var game: Node
var repo: RefCounted
var checks := 0
var failures: Array[String] = []
var observations: Array[bool] = []
var gpu := false

func _initialize() -> void: call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		Input.parse_input_event(event)
		await ticks(2)
	await ticks(3)

func shot(label: String) -> void:
	if not gpu: return
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	check(picture.save_png(OUT + label + ".png") == OK, "GPU screenshot: " + label)

func run() -> void:
	create_timer(100, true).timeout.connect(func(): printerr("WORLD_ECONOMY timeout"); quit(1))
	var isolated := OS.get_temp_dir().path_join("mosslight-economy-integration-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	Preferences.settings_path = isolated + ".cfg"
	repo = Repository.new(isolated)
	var created: Dictionary = repo.create("商店闭环验证")
	check(created.ok, "create isolated adventure")
	gpu = DisplayServer.get_name() != "headless"
	root.size = Vector2i(1280, 720)
	if gpu: DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = repo
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.close_panel(true)
	app.ui.modulate.a = 1
	app.ui.region_clock = 0
	game = app.game
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	await ticks(8)
	check(repo.restore(created.snapshot, game.player, game).ok, "fresh snapshot restores with new services")
	check(game.economy.balance() == 0, "loading an old empty economy does not mint currency")
	check(game.player.progression.choose_career("warrior"), "choose real starter career")
	var merchant: Node3D
	var chest: Node3D
	for npc in game.narrative_npcs:
		if npc.definition.id == "village_merchant": merchant = npc
	for prop in game.world_objects.populate():
		if prop.persistent_id == "prop.village_supply_chest": chest = prop
	check(is_instance_valid(merchant) and is_instance_valid(chest), "merchant and stable chest are in actual map")
	if not is_instance_valid(merchant) or not is_instance_valid(chest):
		quit(1)
		return
	check(not game.begin_shop(merchant) and not game.world_modal_open(), "remote merchant session is rejected")
	game.player.global_position = chest.global_position + Vector3(0, .035, 1.25)
	game.player.velocity = Vector3.ZERO
	await ticks(15)
	var initial_potions: int = game.player.inventory.count("healing_potion")
	await key(KEY_F)
	check(chest.opened and game.player.inventory.count("healing_potion") == initial_potions + 2, "real F opens chest and grants configured reward")
	await shot("01-village-chest")
	game.player.global_position = merchant.global_position + Vector3(0, .035, 1.25)
	game.player.velocity = Vector3.ZERO
	await ticks(40)
	# Trade is now selected while pointing at the merchant. Hold this pointer
	# during the fixture so offscreen GPU runs ignore the real desktop cursor.
	game.world_ui.set_process(false)
	var point: Vector2=game.world_to_screen(merchant.global_position+Vector3.UP*1.1)
	game.world_ui.update_context(.3,point)
	var wheel:=InputEventMouseButton.new()
	wheel.position=root.get_final_transform()*point
	wheel.global_position=wheel.position
	wheel.button_index=MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed=true
	Input.parse_input_event(wheel)
	await ticks(2)
	await key(KEY_F)
	game.world_ui.set_process(true)
	check(game.shop_panel.is_open() and game.world_modal_open() and paused and game.paused, "real F starts merchant modal and pauses world")
	if not game.shop_panel.is_open():
		quit(1)
		return
	check(not game.begin_shop(merchant), "cannot open a duplicate merchant session")
	check(game.shop_panel.trade_button.disabled, "zero balance cannot buy")
	await key(KEY_J)
	check(app.ui.panel.is_empty() and game.shop_panel.is_open(), "journal shortcut cannot overlay merchant")
	var panel: CanvasLayer = game.shop_panel
	panel.sell_button.pressed.emit()
	panel._select("healing_potion")
	panel.quantity.value = 4
	await ticks(3)
	check(not panel.trade_button.disabled, "paused merchant can sell four spare potions")
	var before_sell: int = game.player.inventory.count("healing_potion")
	panel.trade_button.pressed.emit()
	await ticks(3)
	check(game.economy.balance() == 20 and game.player.inventory.count("healing_potion") == before_sell - 4, "sale atomically exchanges items for 20 copper")
	panel.buy_button.pressed.emit()
	panel._select("healing_potion")
	await ticks(3)
	check(not panel.trade_button.disabled and panel.balance_label.text.contains("20"), "wallet and buy availability refresh after sale")
	await shot("02-merchant-buy")
	var before_buy: int = game.player.inventory.count("healing_potion")
	var observer := func():
		observations.append(Guard.busy(game.world_state))
		observations.append(game.economy.balance() == 0 and game.player.inventory.count("healing_potion") == before_buy + 1)
		observations.append(game.world_state.get_object("economy.shop.village_supply").stock.healing_potion == 11)
		observations.append(not game.quests.accept("village_patrol"))
		observations.append(not game.world_objects.interact(chest))
		observations.append(not game.economy.quote_sell("village_supply", "healing_potion", 1).ok)
		observations.append(not repo.restore(created.snapshot, game.player, game).ok)
		var saved_in_signal: Dictionary = repo.save(0, "商店闭环验证", game.player, game)
		observations.append(saved_in_signal.ok and saved_in_signal.snapshot.world_state.objects["economy.wallet"].balance == 0 and saved_in_signal.snapshot.inventory.stacks.healing_potion == before_buy + 1)
	game.player.inventory.changed.connect(observer)
	panel.trade_button.pressed.emit()
	game.player.inventory.changed.disconnect(observer)
	await ticks(3)
	check(observations.size() == 8 and observations.all(func(value: bool): return value), "trade observers see complete state, can save, cannot mutate or restore reentrantly")
	check(game.economy.balance() == 0 and panel.trade_button.disabled, "purchase consumes copper and refreshes insufficient-funds button")
	await key(KEY_ESCAPE)
	check(not game.world_modal_open() and not paused and not game.paused and app.ui.panel.is_empty(), "Esc closes only shop and resumes gameplay")
	check(not game.can_trade("village_supply").is_empty(), "closed panel releases merchant session")
	var saved: Dictionary = repo.save(0, "商店闭环验证", game.player, game)
	check(saved.ok and repo.load_slot(0).ok, "merchant and chest state persist in same real disk snapshot")
	var another: Dictionary = repo.create("另一商店冒险", 1)
	check(repo.restore(another.snapshot, game.player, game).ok and not chest.opened and game.economy.balance() == 0, "another adventure gets unopened chest and its own zero balance")
	check(repo.restore(repo.load_slot(0).snapshot, game.player, game).ok and chest.opened and is_equal_approx(chest.lid.rotation.x, -1.2), "return to original adventure restores open lid without rewards")
	check(game.world_state.get_object("economy.shop.village_supply").stock.healing_potion == 11, "finite shop stock stays sold after reload")
	var broken: Dictionary = saved.snapshot.duplicate(true)
	broken.world_state.objects["economy.wallet"].balance = -1
	var unchanged: Dictionary = game.world_state.export_state()
	check(not repo.restore(broken, game.player, game).ok and game.world_state.export_state() == unchanged, "corrupt wallet rejected before destination changes")
	game.player.global_position = merchant.global_position + Vector3(0, .035, 1.25)
	game.player.combat.reset()
	await ticks(5)
	check(game.begin_shop(merchant), "merchant can reopen after save restore")
	var quote: Dictionary = game.economy.quote_sell("village_supply", "healing_potion", 1)
	check(quote.ok, "obtain valid pre-restore quote")
	check(repo.restore(saved.snapshot, game.player, game).ok and not game.world_modal_open() and not paused, "restore closes merchant and clears its session")
	check(not game.economy.trade(quote), "restore invalidates all pre-restore quotes")
	check(game.quests.accept("village_patrol"), "shared guard releases after transactions and restore")
	app.queue_free()
	await ticks(4)
	check(not paused, "frontend shutdown leaves tree unpaused")
	print("WORLD_ECONOMY_INTEGRATION checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
