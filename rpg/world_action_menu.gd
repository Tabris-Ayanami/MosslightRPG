extends Control
## A three-row wheel. The selected entry always rests beside the wooden key.
signal activated(id: String)
signal selection_changed(index: int)
const ART = preload("res://scripts/frontend/ui_art.gd")
const BADGE := Vector2(22, 78)
const BADGE_RADIUS := 14.0
const BADGE_HIT_RADIUS := 18.0
const ROW := 32.0
var entries: Array[Dictionary] = []
var selected := 0
var expanded := 0.0
var hovered := false
var force_open := false
var expand_on_hover := true
var show_selected_when_closed := false
var title := ""
var key_text := "F"
var busy := false
var pixel_font: Font
var text_color := Color("fff1cf")
var secondary_color := Color("dddcca")
var text_outline := true
var _scroll_slide := 0.0
var _appearance := 0.0

func _ready() -> void:
	size = Vector2(304, 156)
	mouse_filter = MOUSE_FILTER_STOP
	mouse_default_cursor_shape = CURSOR_POINTING_HAND

func set_entries(values: Array, reset := false) -> void:
	entries.assign(values.duplicate(true))
	selected = 0 if reset else clampi(selected, 0, maxi(0, entries.size() - 1))
	if reset:
		expanded = 0.0
		_scroll_slide = 0.0
		_appearance = 0.0
	queue_redraw()

func tick(delta: float, pointer: Vector2) -> void:
	hovered = hit_test(pointer)
	# A world menu is first opened by its 3D object. Once open, the pointer
	# can cross into its rows without closing it. Dialogue choices open normally.
	var keep_open := hovered and (expand_on_hover or expanded > .08)
	expanded = move_toward(expanded, 1.0 if keep_open or force_open else 0.0, delta / .24)
	_appearance = move_toward(_appearance, 1.0, delta / .18)
	_scroll_slide *= exp(-delta * 19)
	queue_redraw()

func visible_indices() -> Array[int]:
	var result: Array[int] = []
	for index in range(maxi(0, selected - 1), mini(entries.size(), selected + 2)):
		result.append(index)
	return result

func hit_test(point: Vector2) -> bool:
	return is_visible_in_tree() and _has_point(get_global_transform().affine_inverse() * point)

func _has_point(point: Vector2) -> bool:
	if entries.is_empty(): return false
	if point.distance_to(BADGE) <= BADGE_HIT_RADIUS: return true
	if show_selected_when_closed:
		var font: Font=pixel_font if pixel_font else ART.font(600)
		var width:=font.get_string_size(str(entries[selected].label).left(16),HORIZONTAL_ALIGNMENT_LEFT,-1,16).x+12
		if Rect2(BADGE+Vector2(24,-14),Vector2(width,28)).has_point(point): return true
	# A continuous corridor prevents flicker while moving from F to a row.
	return expanded > .08 and Rect2(2, 30, 296, 98).has_point(point)

func scroll_by(direction: int) -> void:
	if busy or entries.size() < 2: return
	var before := selected
	selected = clampi(selected + direction, 0, entries.size() - 1)
	if selected != before:
		_scroll_slide += signf(float(selected - before)) * ROW
		selection_changed.emit(selected)
	queue_redraw()

func activate_selected() -> void:
	if busy or entries.is_empty() or not entries[selected].get("enabled", true): return
	activated.emit(str(entries[selected].id))

func handle_pointer(event: InputEventMouseButton) -> bool:
	if not hit_test(event.position): return false
	if event.pressed:
		if event.button_index in [MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_UP]:
			scroll_by(1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			var point := get_global_transform().affine_inverse() * event.position
			if point.distance_to(BADGE) <= BADGE_HIT_RADIUS: activate_selected()
			else:
				var offset := roundi((point.y - BADGE.y) / ROW)
				var index := selected + offset
				if absi(offset)<=1 and index>=0 and index<entries.size() and absf(point.y-BADGE.y-offset*ROW)<14:
					if offset!=0: scroll_by(offset)
					activate_selected()
	return true

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		# GUI coordinates are local; the public handler accepts root coordinates.
		var root_event := event.duplicate() as InputEventMouseButton
		root_event.position = get_global_transform() * event.position
		if handle_pointer(root_event): accept_event()

func _text(at: Vector2, value: String, fs: int, color: Color) -> void:
	var font: Font = pixel_font if pixel_font else ART.font(600)
	if pixel_font and fs>=15: fs=16
	if text_outline: draw_string_outline(font, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(.13, .18, .12, color.a * .65))
	draw_string(font, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)

func _draw() -> void:
	if entries.is_empty(): return
	var reveal := smoothstep(0, 1, expanded)
	var alpha := smoothstep(0, 1, _appearance)
	# A small 28px wooden seal; text and the invisible pointer target stay legible.
	var outline := PackedVector2Array([Vector2(-10,-20),Vector2(10,-20),Vector2(10,-17),Vector2(17,-17),Vector2(17,-10),Vector2(20,-10),Vector2(20,10),Vector2(17,10),Vector2(17,17),Vector2(10,17),Vector2(10,20),Vector2(-10,20),Vector2(-10,17),Vector2(-17,17),Vector2(-17,10),Vector2(-20,10),Vector2(-20,-10),Vector2(-17,-10),Vector2(-17,-17),Vector2(-10,-17)])
	var points := PackedVector2Array()
	for p in outline: points.append(BADGE + (p * BADGE_RADIUS / 20.0).round() + Vector2(0, 2))
	draw_colored_polygon(points, Color("302c20", alpha * .65))
	points.clear()
	for p in outline: points.append(BADGE + (p * BADGE_RADIUS / 20.0).round())
	draw_colored_polygon(points, Color("715337", alpha))
	points.clear()
	for p in outline: points.append(BADGE + (p * BADGE_RADIUS / 20.0 * .86).round())
	draw_colored_polygon(points, Color("b79864" if hovered else "a98a5c", alpha))
	for grain in [[-8,-7,6],[-10,-3,3],[-6,7,8]]:
		draw_line(BADGE + Vector2(grain[0],grain[1]), BADGE + Vector2(grain[2],grain[1]), Color("6a523a",alpha*.24),1)
	var key_size := 16 if key_text.length() < 3 else 12
	var font: Font = pixel_font if pixel_font else ART.font(600)
	var width := font.get_string_size(key_text,HORIZONTAL_ALIGNMENT_LEFT,-1,key_size).x
	_text(BADGE + Vector2(roundf(-width*.5),6), key_text, key_size, Color("fff0ca",alpha))
	if not title.is_empty():
		_text(Vector2(47,lerpf(52,22,reveal)), title, 14, Color("fff1cf", alpha))
	for index in visible_indices():
		var active := index == selected
		var opacity := alpha * (1.0 if active and show_selected_when_closed else reveal * (1.0 if active else .80))
		if opacity <= .01: continue
		var offset := (float(index-selected)*ROW + _scroll_slide) * reveal
		var at := BADGE + Vector2(25 + 9*reveal, offset + 6)
		# Adjacent choices visibly fold into the badge; the selected verb remains.
		if not active or not show_selected_when_closed: at.x = lerpf(BADGE.x,at.x,reveal)
		var color := Color(text_color if active else secondary_color,opacity)
		if not entries[index].get("enabled",true): color = Color("b2aa92",opacity*.7)
		var text := str(entries[index].label)
		if text.length()>16: text=text.left(15)+"…"
		_text(at,text,17 if active else 15,color)
	if entries.size()>1 and reveal>.01:
		var y := 124.0 if selected < entries.size()-1 else 33.0
		draw_circle(Vector2(59,y),1.5,Color("eed9b2",alpha*reveal*.65))
