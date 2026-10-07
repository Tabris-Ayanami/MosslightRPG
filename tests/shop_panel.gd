extends SceneTree
## Native modal contract test. No gameplay scene, preferences or user saves are
## loaded; a deterministic economy fixture isolates GUI behavior and input.
const ShopPanel = preload("res://scripts/frontend/shop_panel.gd")
var checks := 0
var failures: Array[String] = []

class EconomyFixture extends RefCounted:
	signal changed
	var last_error := ""
	var money := 1000
	var trades := 0
	var quote_calls := 0
	var guarded := false
	var price := 5
	var owned := 12
	var stock := 80
	var empty_sell := false
	func balance() -> int: return money
	func definition(id: String) -> Dictionary: return {"id": id} if id == "village_supply" else {}
	func entries(_shop: String, direction: String = "buy") -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		if direction == "sell" and empty_sell: return result
		for index in range(36):
			result.append({"id": "item_%02d" % index, "name": "旅人补给 · %02d" % index, "description": "以药草与清泉调制，适合漫长旅途中随身携带。\n\n".repeat(8), "price": price, "stock": stock, "owned": owned, "available": 0 if guarded else 20})
		return result
	func quote_buy(shop: String, id: String, count: int) -> Dictionary: return _quote(shop, id, count, "buy")
	func quote_sell(shop: String, id: String, count: int) -> Dictionary: return _quote(shop, id, count, "sell")
	func _quote(shop: String, id: String, count: int, direction: String) -> Dictionary:
		quote_calls += 1
		var error := ""
		if guarded: error = "交易进行中。"
		elif count <= 0: error = "数量必须大于零。"
		elif direction == "buy" and count > stock: error = "库存不足。"
		elif direction == "buy" and price * count > money: error = "铜币不足。"
		elif direction == "sell" and count > owned - 2: error = "不能卖出正在装备的物品。"
		return {"ok": error.is_empty(), "error": error, "shop": shop, "id": id, "qty": count, "mode": direction, "price": price}
	func trade(quote: Dictionary) -> bool:
		if not quote.ok or quote.price != price: return false
		trades += 1
		money += (-1 if quote.mode == "buy" else 1) * quote.price * quote.qty
		owned += (1 if quote.mode == "buy" else -1) * quote.qty
		stock += (-1 if quote.mode == "buy" else 1) * quote.qty
		notify_guarded()
		return true
	func notify_guarded() -> void:
		guarded = true
		changed.emit()
		guarded = false

class Host extends Node:
	var economy := EconomyFixture.new()
	var session_error := ""
	var session_checks := 0
	func can_trade(_shop: String) -> String:
		session_checks += 1
		return session_error

class InputSink extends Node:
	var events := 0
	func _unhandled_input(_event: InputEvent) -> void: events += 1

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func ticks(count := 3) -> void:
	for index in range(count): await process_frame

func key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)

func click(control: Control) -> void:
	var at: Vector2 = root.get_final_transform() * control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await ticks(1)

func shot(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.work/" + name + ".png"))

func run() -> void:
	create_timer(30, true).timeout.connect(func(): quit(2))
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	var host := Host.new()
	root.add_child(host)
	var sink := InputSink.new()
	sink.process_mode = Node.PROCESS_MODE_ALWAYS
	host.add_child(sink)
	var previous := Button.new()
	previous.text = "先前焦点"
	previous.process_mode = Node.PROCESS_MODE_ALWAYS
	host.add_child(previous)
	previous.grab_focus()
	var panel := ShopPanel.new()
	panel.setup(host)
	host.add_child(panel)
	var signals := {"opened": 0, "closed": 0}
	panel.opened.connect(func():
		signals.opened += 1
		paused = true)
	panel.closed.connect(func():
		signals.closed += 1
		paused = false)
	check(not panel.start("missing", "不存在的商店") and not panel.visible and signals.opened == 0, "invalid shop never acquires a modal")
	host.session_error = "商人已离开。"
	check(not panel.start("village_supply", "诺安") and panel.last_error == host.session_error, "start validates the live merchant session")
	host.session_error = ""
	check(panel.start("village_supply", "行商 · 诺安"), "valid shop opens synchronously")
	await ticks()
	check(paused and panel.process_mode == Node.PROCESS_MODE_ALWAYS and signals.opened == 1, "modal controls remain active during the host pause")
	check(not panel.start("village_supply", "重复") and signals.opened == 1, "duplicate open cannot replace the active shop")
	check(panel.item_buttons.size() == 36 and panel.selected_id == "item_00" and not panel.trade_button.disabled, "first listing and authoritative valid quote appear")
	check(panel.balance_label.text == "钱袋  1000 铜币", "balance and currency are Chinese")
	check(panel.quantity.get_theme_color("up_icon_modulate") == panel.INK and panel.quantity.get_theme_color("down_icon_modulate") == panel.INK, "native quantity arrows use readable ink colors")
	check(panel.paper.get_global_rect().end.x <= 1280 and panel.paper.get_global_rect().end.y <= 720, "1280 by 720 paper fits viewport")
	check(panel.paper.get_global_rect().encloses(panel.trade_button.get_global_rect()) and panel.paper.get_global_rect().encloses(panel.close_button.get_global_rect()), "transaction and exit fit paper")
	check(panel.list_scroll.size.y < panel.item_list.size.y and panel.description.size.y > 0, "long inventory scrolls without displacing details")
	await shot("shop-panel-1280")
	var events := sink.events
	key(KEY_F)
	key(KEY_I)
	await ticks()
	check(sink.events == events and host.economy.trades == 0, "gameplay shortcuts are swallowed by the modal")
	panel.close_button.grab_focus()
	key(KEY_TAB)
	await ticks()
	check(panel.buy_button.has_focus() and not previous.has_focus(), "Tab wraps within the shop instead of focusing the world behind it")
	panel.close_button.grab_focus()
	key(KEY_DOWN)
	await ticks()
	check(panel.buy_button.has_focus(), "native directional focus also stays inside the modal")
	panel.buy_button.grab_focus()
	key(KEY_TAB)
	await ticks()
	check(panel.sell_button.has_focus(), "native Tab advances between mode controls")
	key(KEY_ENTER)
	await ticks()
	check(panel.mode == "sell" and panel.sell_button.button_pressed and not panel.buy_button.button_pressed, "native Enter switches to selling once")
	await click(panel.buy_button)
	check(panel.mode == "buy", "native mouse switches to buying while paused")
	panel.item_buttons[22].grab_focus()
	await ticks()
	check(panel.selected_id == "item_22" and panel.list_scroll.scroll_vertical > 0, "keyboard focus selects and reveals an offscreen row")
	var scroll := panel.list_scroll.scroll_vertical
	await click(panel.sell_button)
	await click(panel.buy_button)
	await ticks()
	check(panel.selected_id == "item_22" and panel.list_scroll.scroll_vertical == scroll, "switching modes restores selected ID and scroll")
	panel.quantity.get_line_edit().text = "3"
	panel.quantity.apply()
	await ticks()
	check(int(panel.quantity.value) == 3 and panel.total_label.text == "需付  15 铜币", "native quantity editing updates the displayed total")
	host.economy.price = 7
	var calls := host.economy.quote_calls
	var sessions := host.session_checks
	await click(panel.trade_button)
	await ticks()
	check(host.economy.trades == 1 and host.economy.money == 979 and host.economy.owned == 15, "click obtains a fresh price and makes exactly one trade")
	check(host.economy.quote_calls > calls and host.session_checks > sessions, "commit rechecks both merchant session and economy quote")
	check(panel.selected_id == "item_22" and panel.list_scroll.scroll_vertical == scroll and int(panel.quantity.value) == 3, "successful trade retains item, quantity and scroll")
	check(panel.balance_label.text == "钱袋  979 铜币" and panel.status_label.text.contains("交易完成"), "successful trade refreshes money and feedback")
	host.economy.notify_guarded()
	await ticks()
	check(not panel.trade_button.disabled, "guarded changed signal refreshes after transaction guard release")
	panel.quantity.value = 999
	await ticks()
	check(panel.trade_button.disabled and panel.status_label.text.contains("库存不足"), "authoritative failed quote disables confirmation and explains why")
	panel.quantity.value = 1
	host.session_error = "商人已离开。"
	await click(panel.trade_button)
	check(host.economy.trades == 1 and panel.status_label.text == host.session_error, "stale live session rejects the click without a transaction")
	host.session_error = ""
	await click(panel.sell_button)
	panel.quantity.value = host.economy.owned
	await ticks()
	check(panel.trade_button.disabled and panel.status_label.text.contains("装备"), "sell rejection exposes service-owned equipped-item protection")
	panel.quantity.value = 2
	await click(panel.trade_button)
	check(host.economy.trades == 2 and host.economy.money == 993, "selling invokes the sell quote and gains the quoted money")
	host.economy.empty_sell = true
	host.economy.notify_guarded()
	await ticks()
	check(panel.selected_id.is_empty() and panel.trade_button.disabled and not panel.quantity.editable, "empty sale inventory is a valid disabled state")
	check(panel.quantity.get_line_edit().get_theme_stylebox("read_only").bg_color == Color("e3d7bc") and panel.quantity.get_line_edit().get_theme_color("font_uneditable_color") == panel.SOFT, "read-only quantity field keeps warm paper styling")
	root.size = Vector2i(960, 540)
	await ticks(5)
	check(panel.paper.get_global_rect().end.x <= 960 and panel.paper.get_global_rect().end.y <= 540, "supported minimum window fits the whole paper")
	check(panel.paper.get_global_rect().encloses(panel.close_button.get_global_rect()), "minimum window keeps exit visible")
	await shot("shop-panel-960")
	key(KEY_ESCAPE)
	await ticks()
	check(not panel.is_open() and not paused and signals.closed == 1 and previous.has_focus(), "Escape releases modal and restores previous focus")
	panel.close()
	check(signals.closed == 1, "close is idempotent")
	check(panel.start("village_supply", "诺安"), "closed shop can reopen")
	await ticks()
	panel.queue_free()
	await ticks()
	check(signals.closed == 2 and not paused, "freeing the open panel releases its modal once")
	host.queue_free()
	await ticks()
	print("Shop panel: %d/%d checks passed" % [checks - failures.size(), checks])
	for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)

