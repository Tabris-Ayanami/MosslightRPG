extends Button
## Two compact circles fit exactly in the height of one combat slot.
const A = preload("res://scripts/frontend/ui_art.gd")
var kind := "jump"
var selected := false
var pulse := 0.0
var _draw_state: Array = []

func _ready() -> void:
	A.invisible_button(self)
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_force_pass_scroll_events = false
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)

func _process(delta: float) -> void:
	var state: Array = [kind, selected, disabled]
	if state != _draw_state:
		_draw_state = state
		queue_redraw()
	if pulse > 0:
		pulse = maxf(0, pulse - delta * 3.8)
		queue_redraw()

func _draw() -> void:
	var centre := size * .5
	var radius := minf(size.x, size.y) * .5 - 1
	var hot := is_hovered() and not disabled
	var ink := Color(A.PAPER, .38 if disabled else .90)
	draw_circle(centre, radius, Color(.09, .17, .14, .75 if hot else .60))
	draw_arc(centre, radius, 0, TAU, 40, Color(.20, .62, 1, .9) if selected else Color(A.PAPER, .60 if hot else .34), 1.2, true)
	if pulse > 0: draw_circle(centre, radius - 1, Color(A.MINT, pulse * .18))
	# Small movement glyph on the left; the fixed physical key stays readable.
	var x := centre.x - 5
	if kind == "jump":
		draw_polyline(PackedVector2Array([Vector2(x - 2, centre.y + 2), Vector2(x, centre.y - 3), Vector2(x + 2, centre.y + 2)]), ink, 1.2, true)
		draw_line(Vector2(x - 3, centre.y + 4), Vector2(x + 3, centre.y + 4), Color(ink, .45), 1, true)
	else:
		draw_circle(Vector2(x, centre.y - 3), 1.5, ink)
		draw_polyline(PackedVector2Array([Vector2(x, centre.y - 1), Vector2(x - 2, centre.y + 1), Vector2(x + 2, centre.y + 2), Vector2(x, centre.y + 4)]), ink, 1.3, true)
	A.centered(self, centre + Vector2(4, 3.5), "Z" if kind == "jump" else "C", 10, ink, 600)
