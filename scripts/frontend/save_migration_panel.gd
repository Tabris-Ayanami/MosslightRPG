extends Control
## Copies an adventure through the migration service without changing live content.
signal closed
signal copied(result: Dictionary)
const A = preload("res://scripts/frontend/ui_art.gd")
const SAVE_SLOT = preload("res://scripts/frontend/save_slot.gd")
enum Step { SOURCE, REVIEW, TARGET }
var repository: RefCounted
var service: RefCounted
var step := Step.SOURCE
var busy := false
var checked: Dictionary = {}
var selected_slot := -1
var records: Array = []
var slot_buttons: Array[Button] = []
var page: Control
var source_input: LineEdit
var release_input: LineEdit
var name_input: LineEdit
var source_dialog: FileDialog
var release_dialog: FileDialog
var error_label: RichTextLabel
var next_button: Button
var back_button: Button
var cancel_button: Button
var source_path := ""
var release_path := ""
var adventure_name := ""
## Picker starting point is injectable so UI tests never browse player folders.
var user_data_directory := OS.get_user_data_dir()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var palette := Theme.new()
	palette.default_font = A.font(550)
	palette.default_font_size = 20
	theme = palette
	get_viewport().size_changed.connect(_resize)
	_resize()
	hide()

func _resize() -> void:
	var window := get_viewport().get_visible_rect().size
	var factor := minf(window.x / 1280.0, window.y / 720.0)
	scale = Vector2.ONE * factor
	position = Vector2((window.x - 1280.0 * factor) * .5, 0)
	size = Vector2(1280, 720)

func open(target: RefCounted, migration: RefCounted = null) -> void:
	repository = target
	service = migration if migration != null else load("res://rpg/save_migration.gd").new(repository)
	step = Step.SOURCE
	busy = false
	checked.clear()
	selected_slot = -1
	source_path = ""
	release_path = ""
	adventure_name = ""
	show()
	_present()

func dismiss() -> void:
	if is_instance_valid(source_dialog): source_dialog.hide()
	if is_instance_valid(release_dialog): release_dialog.hide()
	hide()
	service = null
	checked.clear()

func request_close() -> void:
	if busy: return
	dismiss()
	closed.emit()

func handle_input(event: InputEvent) -> void:
	# Native fields and buttons keep their normal keyboard behavior. App returns
	# before its sky-slot shortcuts; the hidden sky controls cannot receive clicks.
	if (is_instance_valid(source_dialog) and source_dialog.visible) or (is_instance_valid(release_dialog) and release_dialog.visible): return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if step == Step.SOURCE: request_close()
		else: _back()
		get_viewport().set_input_as_handled()

func _label(value: String, at: Vector2, extent: Vector2, pixels := 20) -> Label:
	var label := Label.new()
	label.text = value
	label.position = at
	label.size = extent
	label.add_theme_font_size_override("font_size", pixels)
	label.add_theme_color_override("font_color", A.PAPER)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(label)
	return label

func _button(value: String, at: Vector2, extent: Vector2, action: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.position = at
	button.size = extent
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(action)
	page.add_child(button)
	return button

func _field(value: String, at: Vector2, extent: Vector2) -> LineEdit:
	var field := LineEdit.new()
	field.text = value
	field.position = at
	field.size = extent
	field.select_all_on_focus = true
	page.add_child(field)
	return field

func _present() -> void:
	if is_instance_valid(page):
		remove_child(page)
		page.queue_free()
	page = Control.new()
	page.size = size
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(page)
	slot_buttons.clear()
	source_input = null
	release_input = null
	name_input = null
	source_dialog = null
	release_dialog = null
	_label("从旧版本复制冒险", Vector2(120, 43), Vector2(1020, 45), 32)
	var headings := ["1 / 3  选择旧冒险与旧版本游戏文件夹", "2 / 3  查看复制前的检查结果", "3 / 3  选择空槽，为副本命名"]
	_label(headings[step], Vector2(122, 94), Vector2(1020, 34), 20)
	back_button = _button("上一步", Vector2(120, 616), Vector2(160, 44), _back)
	back_button.visible = step != Step.SOURCE
	cancel_button = _button("取消", Vector2(725, 616), Vector2(155, 44), request_close)
	next_button = _button(["检查是否可以复制", "选择空槽与名字", "复制冒险"][step], Vector2(900, 616), Vector2(260, 44), _next)
	error_label = RichTextLabel.new()
	error_label.position = Vector2(122, 548)
	error_label.size = Vector2(1030, 58)
	error_label.add_theme_font_size_override("normal_font_size", 18)
	error_label.add_theme_color_override("default_color", Color("f7c7a9"))
	error_label.scroll_active = true
	error_label.selection_enabled = true
	page.add_child(error_label)
	match step:
		Step.SOURCE: _source_page()
		Step.REVIEW: _review_page()
		Step.TARGET: _target_page()
	queue_redraw()

func _source_page() -> void:
	_label("旧冒险记录", Vector2(122, 144), Vector2(1000, 32))
	source_input = _field(source_path, Vector2(122, 181), Vector2(860, 44))
	source_input.placeholder_text = "选择记录文件，或输入完整路径"
	source_input.text_changed.connect(func(value: String) -> void: source_path = value)
	_button("选择文件", Vector2(999, 181), Vector2(161, 44), _choose_source)
	_label("冒险记录保存在本机游戏数据目录，通常不在游戏安装文件夹。", Vector2(122, 231), Vector2(1030, 25), 18)
	_label("对应的旧版本游戏文件夹", Vector2(122, 256), Vector2(1000, 32))
	release_input = _field(release_path, Vector2(122, 293), Vector2(860, 44))
	release_input.placeholder_text = "选择旧版本的完整游戏文件夹，或输入完整路径"
	release_input.text_changed.connect(func(value: String) -> void: release_path = value)
	_button("选择文件夹", Vector2(999, 293), Vector2(161, 44), _choose_release)
	_label("请保留旧版本的完整游戏文件夹。选择存档所使用的版本，不要只选择其中的图片或内容文件夹。\n\n复制会保留原冒险。想返回原来的进度时，仍可打开旧版本游戏继续旧档；新副本的进度不会写回旧档。", Vector2(122, 373), Vector2(1030, 158), 21)
	source_input.grab_focus()

func _choose_source() -> void:
	if busy: return
	if not is_instance_valid(source_dialog):
		source_dialog = FileDialog.new()
		source_dialog.title = "选择旧冒险记录"
		source_dialog.access = FileDialog.ACCESS_FILESYSTEM
		source_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		source_dialog.filters = PackedStringArray(["*.json,*.bak ; 冒险记录"])
		source_dialog.current_dir = _source_start_directory()
		source_dialog.file_selected.connect(func(path: String) -> void: source_input.text = path; source_path = path)
		page.add_child(source_dialog)
	source_dialog.popup_centered(Vector2i(880, 500))

func _source_start_directory() -> String:
	var releases := user_data_directory.path_join("releases")
	return releases if DirAccess.dir_exists_absolute(releases) else user_data_directory

func _choose_release() -> void:
	if busy: return
	if not is_instance_valid(release_dialog):
		release_dialog = FileDialog.new()
		release_dialog.title = "选择完整的旧版本游戏文件夹"
		release_dialog.access = FileDialog.ACCESS_FILESYSTEM
		release_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		release_dialog.dir_selected.connect(func(path: String) -> void: release_input.text = path; release_path = path)
		page.add_child(release_dialog)
	release_dialog.popup_centered(Vector2i(880, 500))

func _review_page() -> void:
	var info: Dictionary = checked.get("metadata", {})
	var text := "冒险：%s  ·  Lv. %d  ·  %s\n保存时间：%s\n\n原版本：%s\n当前版本：%s\n\n" % [info.get("name", ""), int(info.get("level", 0)), info.get("location", ""), info.get("display_time", ""), checked.get("source_label", ""), checked.get("target_label", "")]
	text += "检查结果\n"
	for change in checked.get("changes", []): text += "• " + str(change) + "\n"
	text += "\n原冒险会完整保留。仅在检查通过后复制到空槽，不会覆盖已有旅途。\n支持追加内容及经过版本校验的商店改价；删除、改名或改变原有战斗与成长规则的版本暂不能复制。"
	var summary := RichTextLabel.new()
	summary.position = Vector2(122, 148)
	summary.size = Vector2(1038, 391)
	summary.text = text
	summary.add_theme_color_override("default_color", A.PAPER)
	summary.add_theme_font_size_override("normal_font_size", 21)
	summary.scroll_active = true
	summary.selection_enabled = true
	page.add_child(summary)
	next_button.grab_focus()

func _target_page() -> void:
	records = repository.list_slots()
	if selected_slot < 0 or selected_slot >= records.size() or records[selected_slot].get("occupied", true):
		selected_slot = -1
		for record in records:
			if not record.get("occupied", true):
				selected_slot = int(record.slot)
				break
	for index in range(records.size()):
		var card := SAVE_SLOT.new()
		card.record = records[index]
		card.position = Vector2(122 + (index % 4) * 264, 138 + (index / 4) * 68)
		card.size = Vector2(246, 66)
		card.disabled = records[index].get("occupied", true)
		card.modulate.a = .42 if card.disabled else 1.0
		card.selected = index == selected_slot
		card.tooltip_text = "已有记录，不能覆盖" if card.disabled else "复制到第 %02d 槽" % (index + 1)
		card.pressed.connect(_select_slot.bind(index))
		card.focus_entered.connect(_select_slot.bind(index))
		page.add_child(card)
		slot_buttons.append(card)
	_label("副本的名字", Vector2(122, 488), Vector2(183, 34))
	name_input = _field(adventure_name, Vector2(315, 485), Vector2(530, 44))
	name_input.max_length = 32
	name_input.text_changed.connect(func(value: String) -> void: adventure_name = value)
	# Enter in a name field does not bypass the explicit final copy button.
	_label("已有记录不能覆盖", Vector2(875, 491), Vector2(285, 32), 18)
	if selected_slot == -1:
		next_button.disabled = true
		_error("20 个存档槽已满。请返回；旧冒险没有改变。")
	else:
		name_input.grab_focus()

func _select_slot(index: int) -> void:
	if busy or index < 0 or index >= records.size() or records[index].get("occupied", true): return
	selected_slot = index
	for i in range(slot_buttons.size()):
		slot_buttons[i].selected = i == selected_slot
		slot_buttons[i].queue_redraw()
	error_label.text = ""

func _next() -> void:
	if busy or not visible: return
	match step:
		Step.SOURCE: _preflight()
		Step.REVIEW:
			step = Step.TARGET
			_present()
		Step.TARGET: _commit()

func _preflight() -> void:
	source_path = source_input.text.strip_edges()
	release_path = release_input.text.strip_edges()
	if not source_path.is_absolute_path() or not release_path.is_absolute_path():
		_error("请选择旧冒险记录和对应的完整游戏文件夹，或输入完整路径。")
		return
	_set_busy(true)
	checked = service.preflight(source_path, release_path)
	_set_busy(false)
	if not checked.get("ok", false):
		_error(str(checked.get("error", "无法检查这份冒险，请重新选择。")))
		return
	adventure_name = str(checked.get("metadata", {}).get("name", "冒险")).left(29) + "副本"
	step = Step.REVIEW
	_present()

func _commit() -> void:
	if busy or checked.is_empty() or not checked.get("ok", false) or selected_slot < 0: return
	adventure_name = name_input.text.strip_edges()
	var reason: String = repository.validate_name(adventure_name)
	if not reason.is_empty():
		_error(reason)
		return
	_set_busy(true)
	var result: Dictionary = service.commit(adventure_name, selected_slot)
	_set_busy(false)
	if not result.get("ok", false):
		checked.clear()
		step = Step.SOURCE
		_present()
		_error(str(result.get("error", "复制未完成。")) + " 请重新检查后再试；原冒险已保留。")
		return
	dismiss()
	copied.emit(result)

func _back() -> void:
	if busy: return
	if step == Step.SOURCE:
		request_close()
		return
	if step == Step.TARGET and is_instance_valid(name_input): adventure_name = name_input.text
	step = Step.REVIEW if step == Step.TARGET else Step.SOURCE
	if step == Step.SOURCE: checked.clear()
	_present()

func _set_busy(value: bool) -> void:
	busy = value
	next_button.disabled = value
	cancel_button.disabled = value
	back_button.disabled = value

func _error(message: String) -> void:
	error_label.text = message

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(.025, .065, .06, .93))
	A.plate(self, Rect2(90, 26, 1100, 656), Color("183a35"), Color(A.MINT, .28), 16)
