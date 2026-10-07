extends CanvasLayer
## Scene-owned native shop modal. The host owns the pause and merchant session;
## the economy remains authoritative for prices, stock and transaction validation.
signal opened
signal closed

const ART = preload("res://scripts/frontend/ui_art.gd")
const TITLE_FONT = preload("res://assets/ui/fonts/LongCang-Regular.ttf")
const INK := Color("34483b")
const SOFT := Color("897b63")
const PAPER := Color("ebdec4")
const LINE := Color("bdb091")
const SAGE := Color("737c61")

var shop_id := ""
var mode := "buy"
var selected_id := ""
var last_error := ""
var surface: Control
var paper: PanelContainer
var merchant_label: Label
var balance_label: Label
var buy_button: Button
var sell_button: Button
var close_button: Button
var list_scroll: ScrollContainer
var item_list: VBoxContainer
var item_buttons: Array[Button] = []
var item_name: Label
var item_icon: TextureRect
var description: RichTextLabel
var amounts: Label
var quantity: SpinBox
var total_label: Label
var status_label: Label
var trade_button: Button

var _game: WeakRef
var _economy: WeakRef
var _focus_before: WeakRef
var _open := false
var _trading := false
var _refreshing := false
var _rows: Array[Dictionary] = []
var _selected_by_mode := {"buy": "", "sell": ""}
var _scroll_by_mode := {"buy": 0, "sell": 0}
var _layout_generation := 0
var _theme: Theme
var _margin: MarginContainer
var _column: VBoxContainer
var _content: HBoxContainer
var _detail: VBoxContainer
var _hint: Label

func setup(game: Node) -> void:
	_disconnect_economy()
	_game = weakref(game) if is_instance_valid(game) else null
	var economy: Variant = game.get("economy") if is_instance_valid(game) else null
	if is_instance_valid(economy):
		_economy = weakref(economy)
		economy.changed.connect(_on_economy_changed)

func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	surface = Control.new()
	surface.name = "ShopModal"
	surface.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(surface)
	_theme = Theme.new()
	_theme.default_font = ART.font(500)
	_theme.default_font_size = 18
	_theme.set_color("font_color", "Label", INK)
	_theme.set_color("default_color", "RichTextLabel", INK)
	surface.theme = _theme
	var dim := ColorRect.new()
	dim.color = Color(.10, .12, .09, .46)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	surface.add_child(dim)
	paper = PanelContainer.new()
	paper.name = "ShopPaper"
	paper.mouse_filter = Control.MOUSE_FILTER_STOP
	paper.add_theme_stylebox_override("panel", _plate(PAPER, LINE))
	surface.add_child(paper)
	_margin = MarginContainer.new()
	paper.add_child(_margin)
	_column = VBoxContainer.new()
	_margin.add_child(_column)
	var heading := HBoxContainer.new()
	_column.add_child(heading)
	merchant_label = Label.new()
	merchant_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	merchant_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	merchant_label.add_theme_font_override("font", TITLE_FONT)
	heading.add_child(merchant_label)
	balance_label = Label.new()
	balance_label.add_theme_color_override("font_color", INK)
	heading.add_child(balance_label)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 10)
	_column.add_child(tabs)
	buy_button = _button("买入")
	buy_button.name = "ShopBuyTab"
	buy_button.toggle_mode = true
	buy_button.pressed.connect(_switch_mode.bind("buy"))
	tabs.add_child(buy_button)
	sell_button = _button("卖出")
	sell_button.name = "ShopSellTab"
	sell_button.toggle_mode = true
	sell_button.pressed.connect(_switch_mode.bind("sell"))
	tabs.add_child(sell_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(spacer)
	_hint = Label.new()
	_hint.text = "Tab 切换焦点 · Enter 确认"
	_hint.add_theme_color_override("font_color", SOFT)
	tabs.add_child(_hint)
	var rule := HSeparator.new()
	_column.add_child(rule)
	_content = HBoxContainer.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_column.add_child(_content)
	list_scroll = ScrollContainer.new()
	list_scroll.name = "ShopItems"
	list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.size_flags_stretch_ratio = 1.12
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.follow_focus = true
	_content.add_child(list_scroll)
	item_list = VBoxContainer.new()
	item_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_list.add_theme_constant_override("separation", 6)
	list_scroll.add_child(item_list)
	var divider := VSeparator.new()
	_content.add_child(divider)
	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.size_flags_stretch_ratio = 1.0
	_detail.add_theme_constant_override("separation", 10)
	_content.add_child(_detail)
	var item_heading := HBoxContainer.new()
	item_heading.add_theme_constant_override("separation", 12)
	_detail.add_child(item_heading)
	item_icon = TextureRect.new()
	item_icon.custom_minimum_size = Vector2(48, 48)
	item_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	item_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	item_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item_heading.add_child(item_icon)
	item_name = Label.new()
	item_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_name.add_theme_font_override("font", ART.font(650))
	item_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	item_heading.add_child(item_name)
	description = RichTextLabel.new()
	description.bbcode_enabled = false
	description.scroll_active = true
	description.size_flags_vertical = Control.SIZE_EXPAND_FILL
	description.add_theme_font_override("normal_font", ART.font(500))
	_detail.add_child(description)
	amounts = Label.new()
	amounts.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_child(amounts)
	var quantity_row := HBoxContainer.new()
	quantity_row.add_theme_constant_override("separation", 12)
	_detail.add_child(quantity_row)
	var quantity_label := Label.new()
	quantity_label.text = "数量"
	quantity_row.add_child(quantity_label)
	quantity = SpinBox.new()
	quantity.name = "TradeQuantity"
	quantity.min_value = 1
	quantity.max_value = 999
	quantity.step = 1
	quantity.rounded = true
	quantity.value = 1
	quantity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quantity.value_changed.connect(_quantity_changed)
	quantity_row.add_child(quantity)
	for direction in ["up", "down"]:
		quantity.add_theme_color_override(direction + "_icon_modulate", INK)
		quantity.add_theme_color_override(direction + "_hover_icon_modulate", INK)
		quantity.add_theme_color_override(direction + "_pressed_icon_modulate", INK)
		quantity.add_theme_color_override(direction + "_disabled_icon_modulate", SOFT)
	var quantity_edit := quantity.get_line_edit()
	quantity_edit.add_theme_color_override("font_color", INK)
	quantity_edit.add_theme_color_override("font_uneditable_color", SOFT)
	quantity_edit.add_theme_color_override("caret_color", INK)
	quantity_edit.add_theme_stylebox_override("normal", _plate(Color("f1e5cc"), LINE))
	quantity_edit.add_theme_stylebox_override("focus", _plate(Color.TRANSPARENT, SAGE))
	quantity_edit.add_theme_stylebox_override("read_only", _plate(Color("e3d7bc"), LINE))
	total_label = Label.new()
	total_label.add_theme_font_override("font", ART.font(650))
	_detail.add_child(total_label)
	trade_button = _button("买入")
	trade_button.name = "ConfirmTrade"
	trade_button.pressed.connect(_try_trade)
	_detail.add_child(trade_button)
	status_label = Label.new()
	status_label.name = "TradeStatus"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", SOFT)
	_column.add_child(status_label)
	var footer := HBoxContainer.new()
	_column.add_child(footer)
	var footer_note := Label.new()
	footer_note.text = "价格与库存以成交时为准"
	footer_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_note.add_theme_color_override("font_color", SOFT)
	footer.add_child(footer_note)
	close_button = _button("离开 · Esc")
	close_button.name = "CloseShop"
	close_button.pressed.connect(close)
	footer.add_child(close_button)
	get_viewport().size_changed.connect(_resize)
	_resize()
	hide()

func start(id: String, merchant_name: String) -> bool:
	var economy: Variant = _service()
	if _open or not is_node_ready() or not is_instance_valid(economy) or economy.definition(id).is_empty():
		last_error = "当前无法交易。"
		return false
	var game: Variant = _host()
	last_error = str(game.can_trade(id))
	if not last_error.is_empty(): return false
	shop_id = id
	mode = "buy"
	selected_id = ""
	_selected_by_mode = {"buy": "", "sell": ""}
	_scroll_by_mode = {"buy": 0, "sell": 0}
	quantity.set_value_no_signal(1)
	merchant_label.text = merchant_name if not merchant_name.is_empty() else "旅途商店"
	var previous := get_viewport().gui_get_focus_owner()
	_focus_before = weakref(previous) if is_instance_valid(previous) else null
	_open = true
	last_error = ""
	_refresh()
	show()
	if not item_buttons.is_empty(): item_buttons[0].grab_focus()
	else: close_button.grab_focus()
	opened.emit()
	return true

func is_open() -> bool: return _open

func close() -> void:
	if not _open: return
	_open = false
	_layout_generation += 1
	shop_id = ""
	selected_id = ""
	_rows.clear()
	hide()
	var previous: Variant = _focus_before.get_ref() if _focus_before != null else null
	_focus_before = null
	if is_instance_valid(previous) and previous is Control and previous.is_visible_in_tree(): previous.grab_focus()
	closed.emit()

func _exit_tree() -> void:
	close()
	_disconnect_economy()
	_game = null

func _host() -> Variant:
	return _game.get_ref() if _game != null else null

func _service() -> Variant:
	return _economy.get_ref() if _economy != null else null

func _disconnect_economy() -> void:
	var economy: Variant = _service()
	if is_instance_valid(economy) and economy.changed.is_connected(_on_economy_changed): economy.changed.disconnect(_on_economy_changed)
	_economy = null

func _switch_mode(value: String) -> void:
	if not _open or _trading: return
	_selected_by_mode[mode] = selected_id
	_scroll_by_mode[mode] = list_scroll.scroll_vertical
	mode = value
	selected_id = str(_selected_by_mode[mode])
	quantity.set_value_no_signal(1)
	last_error = ""
	_refresh(int(_scroll_by_mode[mode]))

func _on_economy_changed() -> void:
	if _open and not _trading: _refresh.call_deferred()

func _refresh(scroll_override: int = -1) -> void:
	var economy: Variant = _service()
	if not _open or not is_instance_valid(economy): return
	_refreshing = true
	var scroll := list_scroll.scroll_vertical if scroll_override < 0 else scroll_override
	var focus := get_viewport().gui_get_focus_owner()
	var restore_row_focus := is_instance_valid(focus) and item_list.is_ancestor_of(focus)
	_rows.assign(economy.entries(shop_id, mode))
	item_buttons.clear()
	for child in item_list.get_children():
		item_list.remove_child(child)
		child.queue_free()
	var selected_found := false
	for row in _rows:
		if str(row.get("id", "")) == selected_id: selected_found = true
	if not selected_found: selected_id = str(_rows[0].get("id", "")) if not _rows.is_empty() else ""
	for row in _rows:
		var id := str(row.get("id", ""))
		var button := _button("")
		button.name = "ShopItem_" + id.validate_node_name()
		button.text = "%s\n%d 铜币 · %s" % [str(row.get("name", id)), int(row.get("price", 0)), _row_count(row)]
		button.icon = row.get("icon")
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 44)
		button.add_theme_constant_override("h_separation", 10)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.toggle_mode = true
		button.set_pressed_no_signal(id == selected_id)
		button.pressed.connect(_select.bind(id))
		button.focus_entered.connect(_select.bind(id))
		item_list.add_child(button)
		item_buttons.append(button)
		if restore_row_focus and id == selected_id: button.grab_focus()
	if _rows.is_empty():
		var empty := Label.new()
		empty.text = "商店暂时没有商品。" if mode == "buy" else "背包中没有可出售的物品。"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", SOFT)
		item_list.add_child(empty)
	buy_button.set_pressed_no_signal(mode == "buy")
	sell_button.set_pressed_no_signal(mode == "sell")
	balance_label.text = "钱袋  %d 铜币" % int(economy.balance())
	_refreshing = false
	_update_detail()
	_layout_generation += 1
	_restore_scroll.call_deferred(scroll, _layout_generation)

func _restore_scroll(value: int, generation: int) -> void:
	if _open and generation == _layout_generation: list_scroll.scroll_vertical = value

func _row_count(row: Dictionary) -> String:
	if mode == "sell": return "持有 %d" % int(row.get("owned", 0))
	var stock := int(row.get("stock", -1))
	if stock == 0: return "已售罄"
	return "库存充足" if stock < 0 else "库存 %d" % stock

func _selected_row() -> Dictionary:
	for row in _rows:
		if str(row.get("id", "")) == selected_id: return row
	return {}

func _select(id: String) -> void:
	if not _open or _refreshing: return
	if selected_id != id:
		selected_id = id
		quantity.set_value_no_signal(1)
		last_error = ""
	_selected_by_mode[mode] = selected_id
	for index in item_buttons.size(): item_buttons[index].set_pressed_no_signal(str(_rows[index].get("id", "")) == selected_id)
	_update_detail()

func _quantity_changed(_value: float) -> void:
	if _refreshing: return
	last_error = ""
	_update_detail()

func _quote() -> Dictionary:
	var economy: Variant = _service()
	if not is_instance_valid(economy) or selected_id.is_empty(): return {"ok": false, "error": "请选择一件物品。"}
	return economy.quote_buy(shop_id, selected_id, int(quantity.value)) if mode == "buy" else economy.quote_sell(shop_id, selected_id, int(quantity.value))

func _update_detail() -> void:
	var row := _selected_row()
	item_icon.texture = row.get("icon")
	item_icon.visible = item_icon.texture != null
	quantity.editable = not row.is_empty()
	trade_button.text = "确认买入" if mode == "buy" else "确认卖出"
	if row.is_empty():
		item_name.text = "暂无物品"
		description.text = "在这里查看商品说明、数量与价格。"
		amounts.text = ""
		total_label.text = "合计  —"
		trade_button.disabled = true
		status_label.text = last_error
		_wire_focus()
		return
	item_name.text = str(row.get("name", selected_id))
	description.text = str(row.get("description", ""))
	var definition: Dictionary = row.get("definition", {})
	if str(definition.get("category", "")) == "consumable":
		var cooldown := float(definition.get("cooldown", 0.0))
		if cooldown > 0.0:
			description.text += "\n\n此物品使用间隔：%s 秒。" % String.num(cooldown, 2)
		if str(definition.get("effect", "")) == "resource":
			description.text += "\n恢复至上限后，多出的恢复量不保留。"
	var stock := int(row.get("stock", -1))
	if mode == "sell":
		amounts.text = "单价  %d 铜币\n持有  %d    可售  %d（已扣除装备占用）" % [int(row.get("price", 0)), int(row.get("owned", 0)), int(row.get("sellable", row.get("owned", 0)))]
	else:
		amounts.text = "单价  %d 铜币\n库存  %s    持有  %d" % [int(row.get("price", 0)), "充足" if stock < 0 else str(stock), int(row.get("owned", 0))]
	# A broad UI limit keeps typing practical. Quote owns all actual limits,
	# including equipped items, balance, finite stock and inventory stack caps.
	total_label.text = "%s  %d 铜币" % ["需付" if mode == "buy" else "获得", int(row.get("price", 0)) * int(quantity.value)]
	var quote := _quote()
	trade_button.disabled = _trading or not bool(quote.get("ok", false))
	status_label.text = last_error if not last_error.is_empty() else str(quote.get("error", ""))
	_wire_focus()

func _wire_focus() -> void:
	# Explicit native focus neighbors keep Tab and directional navigation inside
	# the modal even when the world/book behind it contains focusable controls.
	var controls: Array[Control] = [buy_button, sell_button]
	for button in item_buttons: controls.append(button)
	if quantity.editable: controls.append(quantity.get_line_edit())
	if not trade_button.disabled: controls.append(trade_button)
	controls.append(close_button)
	for index in controls.size():
		var control := controls[index]
		var before := control.get_path_to(controls[posmod(index - 1, controls.size())])
		var after := control.get_path_to(controls[(index + 1) % controls.size()])
		control.focus_previous = before
		control.focus_next = after
		control.focus_neighbor_top = before
		control.focus_neighbor_left = before
		control.focus_neighbor_bottom = after
		control.focus_neighbor_right = after

func _try_trade() -> void:
	if not _open or _trading or selected_id.is_empty(): return
	var game: Variant = _host()
	var economy: Variant = _service()
	if not is_instance_valid(game) or not is_instance_valid(economy):
		close()
		return
	last_error = str(game.can_trade(shop_id))
	if not last_error.is_empty():
		_update_detail()
		return
	# Never execute a cached display quote: the service rechecks the fresh quote
	# too, so changes between rendering, clicking and committing cannot overspend.
	quantity.apply()
	var quote := _quote()
	if not bool(quote.get("ok", false)):
		last_error = str(quote.get("error", "当前无法交易。"))
		_update_detail()
		return
	_trading = true
	trade_button.disabled = true
	var succeeded: bool = economy.trade(quote)
	_trading = false
	if not _open: return
	last_error = "" if succeeded else str(economy.last_error)
	_refresh()
	if succeeded: status_label.text = "交易完成，愿你一路平安。"

func _input(event: InputEvent) -> void:
	if not _open or not event is InputEventKey: return
	var code: int = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	if code == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if event.pressed and not event.echo: close()
		return
	# Native GUI gets navigation and numeric editing; gameplay shortcuts cannot
	# reach the world. Unhandled navigation is consumed in _unhandled_input.
	if code in [KEY_TAB, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]: return
	if quantity.get_line_edit().has_focus() and (code in [KEY_BACKSPACE, KEY_DELETE, KEY_MINUS, KEY_PLUS, KEY_PERIOD, KEY_KP_ADD, KEY_KP_SUBTRACT, KEY_KP_PERIOD] or (code >= KEY_0 and code <= KEY_9) or (code >= KEY_KP_0 and code <= KEY_KP_9)): return
	get_viewport().set_input_as_handled()

func _unhandled_input(_event: InputEvent) -> void:
	if _open: get_viewport().set_input_as_handled()

func _plate(color: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var color := Color("e0d3b6") if state in ["hover", "pressed", "hover_pressed"] else Color("f1e5cc")
		var style := _plate(Color.TRANSPARENT if state == "focus" else color, SAGE if state in ["pressed", "focus"] else LINE)
		if state == "focus": style.set_border_width_all(2)
		button.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]: button.add_theme_color_override(state, INK)
	button.add_theme_color_override("font_disabled_color", SOFT)
	return button

func _resize() -> void:
	if surface == null: return
	var viewport := get_viewport().get_visible_rect().size
	var scale_factor := clampf(minf(viewport.x / 1280.0, viewport.y / 720.0), .70, 1.4)
	surface.size = viewport
	_theme.default_font_size = maxi(14, roundi(18 * scale_factor))
	merchant_label.add_theme_font_size_override("font_size", roundi(38 * scale_factor))
	item_name.add_theme_font_size_override("font_size", roundi(24 * scale_factor))
	_hint.add_theme_font_size_override("font_size", maxi(12, roundi(14 * scale_factor)))
	description.add_theme_font_size_override("normal_font_size", maxi(14, roundi(18 * scale_factor)))
	for side in ["left", "right", "top", "bottom"]: _margin.add_theme_constant_override("margin_" + side, roundi(20 * scale_factor))
	_column.add_theme_constant_override("separation", roundi(10 * scale_factor))
	_content.add_theme_constant_override("separation", roundi(22 * scale_factor))
	description.custom_minimum_size.y = 60 * scale_factor
	status_label.custom_minimum_size.y = 24 * scale_factor
	paper.size = Vector2(minf(1100 * scale_factor, viewport.x - 40 * scale_factor), minf(610 * scale_factor, viewport.y - 40 * scale_factor))
	paper.position = (viewport - paper.size) * .5

