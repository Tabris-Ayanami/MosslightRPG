extends Control
## Per-entry lifetimes; scrolling can never resurrect an already expired event.
const ART = preload("res://scripts/frontend/ui_art.gd")
const LIFETIME := 10.0
const HOVER_GRACE := 7.0
const CAPACITY := 64
const VISIBLE_ROWS := 5
const ROW_HEIGHT := 44.0
var entries: Array[Dictionary] = []
var scroll_offset := 0
var hovered := false
var _serial := 0
var _arrival := 0.0

func _ready() -> void:
	size = Vector2(294, 236)
	mouse_filter = MOUSE_FILTER_STOP

func push(message: String, color := Color("e6dfc7")) -> void:
	if message.strip_edges().is_empty(): return
	_serial += 1
	entries.append({"id":_serial,"text":message,"color":color,"remaining":LIFETIME})
	if entries.size() > CAPACITY: entries.pop_front()
	if hovered and scroll_offset > 0: scroll_offset += 1
	else: scroll_offset=0
	_clamp_scroll()
	_arrival=1.0
	queue_redraw()

func tick(delta: float, pointer: Vector2, suspended := false) -> void:
	hovered=hit_test(pointer)
	if not suspended:
		for entry in entries:
			if hovered: entry.remaining=maxf(entry.remaining,HOVER_GRACE)
			else: entry.remaining-=maxf(0,delta)
		for i in range(entries.size()-1,-1,-1):
			if entries[i].remaining<=0: entries.remove_at(i)
	_clamp_scroll()
	_arrival=move_toward(_arrival,0,delta*4)
	queue_redraw()

func _clamp_scroll() -> void:
	scroll_offset=clampi(scroll_offset,0,maxi(0,entries.size()-VISIBLE_ROWS))

func hit_test(point: Vector2) -> bool:
	return is_visible_in_tree() and not entries.is_empty() and _has_point(get_global_transform().affine_inverse()*point)

func _has_point(point: Vector2) -> bool:
	return not entries.is_empty() and Rect2(0,0,size.x,minf(size.y,entries.size()*ROW_HEIGHT+12)).has_point(point)

func handle_pointer(event: InputEventMouseButton) -> bool:
	if not hit_test(event.position): return false
	if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
		scroll_offset+=1 if event.button_index==MOUSE_BUTTON_WHEEL_UP else -1
		_clamp_scroll()
		for entry in entries: entry.remaining=maxf(entry.remaining,HOVER_GRACE)
		queue_redraw()
	return true

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var copy:=event.duplicate() as InputEventMouseButton
		copy.position=get_global_transform()*event.position
		if handle_pointer(copy): accept_event()

func _draw() -> void:
	var end:=entries.size()-scroll_offset
	var start:=maxi(0,end-VISIBLE_ROWS)
	var font:=ART.font(500)
	for i in range(start,end):
		var entry: Dictionary=entries[i]
		var alpha:=smoothstep(0,1.3,float(entry.remaining))
		var text:=str(entry.text)
		var lines: Array[String]=[]
		while not text.is_empty() and lines.size()<2:
			var count:=mini(21,text.length())
			lines.append(text.left(count))
			text=text.substr(count)
		if not text.is_empty(): lines[-1]=lines[-1].left(20)+"…"
		var y:=18.0+float(i-start)*ROW_HEIGHT
		var shift:=_arrival*8 if i==entries.size()-1 and scroll_offset==0 else 0.0
		for j in range(lines.size()):
			var at:=Vector2(14+shift,y+j*19)
			draw_string_outline(font,at,lines[j],HORIZONTAL_ALIGNMENT_LEFT,-1,13,3,Color(.1,.16,.12,alpha*.75))
			draw_string(font,at,lines[j],HORIZONTAL_ALIGNMENT_LEFT,-1,13,Color(entry.color,alpha*.95))
		draw_circle(Vector2(3+shift,y-5),2,Color(entry.color,alpha*.75))
	if hovered and entries.size()>VISIBLE_ROWS:
		var y:=size.y-7
		draw_line(Vector2(14,y),Vector2(54,y),Color("d0c4a3",.3),1)
		var ratio:=float(scroll_offset)/maxf(1,entries.size()-VISIBLE_ROWS)
		draw_circle(Vector2(54-40*ratio,y),2,Color("e9dcb8",.8))
