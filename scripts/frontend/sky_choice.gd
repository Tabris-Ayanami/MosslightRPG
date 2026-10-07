extends Control
signal confirmed(kind: String, value: String)
signal cancelled
const A=preload("res://scripts/frontend/ui_art.gd")
const WORDS=preload("res://scripts/frontend/cloud_words.gd")
const SAVE_SLOT=preload("res://scripts/frontend/save_slot.gd")
var kind := "continue"
var selected_slot := 0
var words: Array[Control]=[]
var buttons: Array[Button]=[]
var name_input: LineEdit
var name_word: Control
var error_word: Control
var age := 0.0
var leaving := false
var pending_name := ""
var save_slots: Array[Dictionary]=[]
var slot_buttons: Array[Button]=[]
var preferred_slot := -1
var notice_panel: Panel
func set_save_slots(records: Array) -> void:
	save_slots.clear()
	for entry in records: save_slots.append(entry)
func slot_record(index: int) -> Dictionary:
	return save_slots[index] if index>=0 and index<save_slots.size() else {"slot":index,"occupied":false,"valid":false}
func show_error(message: String) -> void:
	if is_instance_valid(error_word):
		words.erase(error_word)
		remove_child(error_word)
		error_word.queue_free()
	error_word=_word(message,Vector2(640,640 if kind=="continue" else 455),15)
func show_notice(message: String) -> void:
	if is_instance_valid(notice_panel):
		remove_child(notice_panel)
		notice_panel.queue_free()
	notice_panel=Panel.new()
	notice_panel.position=Vector2(160,634)
	notice_panel.size=Vector2(960,28)
	notice_panel.mouse_filter=Control.MOUSE_FILTER_IGNORE
	var background := StyleBoxFlat.new()
	background.bg_color=Color("183a35",.94)
	background.set_corner_radius_all(5)
	notice_panel.add_theme_stylebox_override("panel",background)
	add_child(notice_panel)
	var label := Label.new()
	label.text=message
	label.position=Vector2(8,0)
	label.size=Vector2(944,28)
	label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment=VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font",A.font(600))
	label.add_theme_font_size_override("font_size",18)
	label.add_theme_color_override("font_color",A.PAPER)
	label.mouse_filter=Control.MOUSE_FILTER_IGNORE
	notice_panel.add_child(label)
func _ready() -> void:
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR
	get_viewport().size_changed.connect(_resize)
	_resize()
	hide()
func _resize() -> void:
	var window := get_viewport().get_visible_rect().size
	var factor := minf(window.x/1280.0,window.y/720.0)
	scale=Vector2.ONE*factor
	position=Vector2((window.x-1280*factor)*.5,0)
	size=Vector2(1280,720)
func _word(value: String, at: Vector2, pixels: int, wait: float=0, backdrop: bool=false) -> Control:
	var word := WORDS.new()
	word.backdrop=backdrop
	add_child(word)
	word.configure(value,at,pixels,wait)
	words.append(word)
	return word
func _button(at: Vector2, extent: Vector2, action: Callable) -> Button:
	var button := Button.new()
	button.position=at
	button.size=extent
	button.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	A.invisible_button(button)
	add_child(button)
	button.pressed.connect(action)
	buttons.append(button)
	return button
func present(mode: String) -> void:
	for node in get_children():
		remove_child(node)
		node.queue_free()
	words.clear()
	buttons.clear()
	slot_buttons.clear()
	name_input=null
	name_word=null
	error_word=null
	notice_panel=null
	kind=mode
	age=0
	leaving=false
	show()
	_word("选择你的旅途" if mode=="continue" else "风该如何称呼你",Vector2(640,65 if mode=="continue" else 135),42 if mode=="continue" else 51)
	_word("二十段旅途 · 名字 / 地点 / 现实保存时间" if mode=="continue" else "每段冒险，都有一个独一无二的名字。",Vector2(640,121 if mode=="continue" else 220),15 if mode=="continue" else 17,.18)
	if mode=="continue":
		selected_slot=clampi(selected_slot,0,19)
		for i in range(20):
			var b := SAVE_SLOT.new()
			b.record=slot_record(i)
			b.position=Vector2(132+(i%4)*258,153+(i/4)*84)
			b.size=Vector2(242,74)
			b.selected=i==selected_slot
			add_child(b)
			buttons.append(b)
			slot_buttons.append(b)
			b.pressed.connect(_select.bind(i))
			b.focus_entered.connect(_select.bind(i))
		buttons[selected_slot].grab_focus()
	else:
		name_input=LineEdit.new()
		name_input.position=Vector2(395,330)
		name_input.size=Vector2(490,92)
		name_input.alignment=HORIZONTAL_ALIGNMENT_CENTER
		name_input.max_length=32
		name_input.text=pending_name
		name_input.placeholder_text="输入你的名字"
		name_input.add_theme_font_override("font",A.font(650))
		name_input.add_theme_font_size_override("font_size",40)
		for part in ["normal","focus","read_only"]: name_input.add_theme_stylebox_override(part,StyleBoxEmpty.new())
		var ink := ShaderMaterial.new()
		ink.shader=preload("res://shaders/frontend/cloud_glyph.gdshader")
		ink.set_shader_parameter("formation",1.0)
		name_input.material=ink
		name_input.add_theme_color_override("font_color",Color("fffdf4"))
		name_input.add_theme_color_override("font_placeholder_color",Color(1,1,1,.45))
		add_child(name_input)
		name_input.text_changed.connect(_name_changed)
		name_input.text_submitted.connect(_submit_name)
		name_input.grab_focus()
	_word("继续 / 开启旅途" if mode=="continue" else "以此为名 · 出发",Vector2(640,585 if mode=="continue" else 520),25 if mode=="continue" else 27,.52)
	_button(Vector2(475,578 if mode=="continue" else 505),Vector2(330,56 if mode=="continue" else 65),_confirm)
	_word("Esc  乘风返回",Vector2(640,674),16,.7)
	_button(Vector2(520,662),Vector2(240,42),_cancel)
	queue_redraw()
func _select(index: int) -> void:
	if leaving: return
	selected_slot=clampi(index,0,19)
	for i in range(slot_buttons.size()):
		slot_buttons[i].selected=i==selected_slot
		slot_buttons[i].queue_redraw()
	if is_instance_valid(error_word): error_word.hide()
	queue_redraw()
func _name_changed(value: String) -> void:
	pending_name=value
	if is_instance_valid(error_word): error_word.hide()
func _submit_name(_value: String) -> void: _confirm()
func _confirm() -> void:
	if leaving or age<.9: return
	var value := str(selected_slot)
	if kind=="continue":
		var record := slot_record(selected_slot)
		if not record.get("occupied",false):
			preferred_slot=selected_slot
			present("new")
			return
		if not record.get("valid",false):
			show_error("这份记录暂不可读，未覆盖原文件。")
			return
	if kind=="new":
		value=name_input.text.strip_edges()
		if value.is_empty():
			show_error("名字还没有随风而来")
			return
		pending_name=value
	confirmed.emit(kind,value)
func _cancel() -> void:
	if not leaving: cancelled.emit()
func dissolve() -> void:
	leaving=true
	if is_instance_valid(notice_panel): notice_panel.hide()
	for card in slot_buttons: card.set_meta("leave_age",age)
	for word in words: word.dissolve()
	for button in buttons:
		button.disabled=true
		button.mouse_filter=Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(name_input):
		name_input.release_focus()
		name_input.editable=false
		name_word=_word(name_input.text,Vector2(640,340),40,-10)
		name_word.age=20
		name_word.dissolve()
		name_input.hide()
func _process(delta: float) -> void:
	if not visible: return
	age+=delta
	for card in slot_buttons: card.modulate.a=smoothstep(.15,.85,age)*(maxf(0.0,1.0-(age-card.get_meta("leave_age",age))) if leaving else 1.0)
	if is_instance_valid(name_input) and not leaving:
		name_input.modulate.a=smoothstep(.25,1.25,age)
		name_input.material.set_shader_parameter("clock",age)
		name_input.material.set_shader_parameter("formation",smoothstep(.25,1.25,age))
	queue_redraw()
func _draw() -> void:
	if not visible: return
	var alpha := smoothstep(.6,1.5,age)*(.12 if leaving else .6)
	if kind!="continue":
		draw_line(Vector2(415,427),Vector2(865,427),Color(1,1,1,alpha*.6),1,true)
