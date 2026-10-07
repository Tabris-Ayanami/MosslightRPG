extends Control
## Shared continuous energy meter for the world HUD and the combat laboratory.
const ART = preload("res://scripts/frontend/ui_art.gd")
const FILL := Color("79add6")
const BACKGROUND := Color("293e4d")
var current := 0.0
var maximum := 0.0
var text: String:
	get: return "能量 %s / %s" % [number(current), number(maximum)]

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_values(amount: float, capacity: float) -> void:
	if maximum == maxf(0.0, capacity) and current == clampf(amount, 0.0, maxf(0.0, capacity)): return
	maximum = maxf(0.0, capacity)
	current = clampf(amount, 0.0, maximum)
	tooltip_text = text
	queue_redraw()

func _draw() -> void:
	draw_bar(self, Rect2(Vector2.ZERO, size), current, maximum)

static func number(value: float) -> String:
	return str(int(round(value))) if is_equal_approx(value, round(value)) else "%.1f" % value

static func ratio(amount: float, capacity: float) -> float:
	return clampf(amount / capacity, 0.0, 1.0) if capacity > 0.0 else 0.0

static func draw_bar(canvas: CanvasItem, rect: Rect2, amount: float, capacity: float) -> void:
	var p := rect.position
	var end := rect.end
	var bevel := 4.5
	var outline := PackedVector2Array([p + Vector2(bevel, 0), Vector2(end.x, p.y), end - Vector2(bevel, 0), Vector2(p.x, end.y)])
	canvas.draw_colored_polygon(outline, BACKGROUND)
	var inner := PackedVector2Array([p + Vector2(bevel + 1, 2), Vector2(end.x - 3, p.y + 2), end - Vector2(bevel + 1, 2), Vector2(p.x + 3, end.y - 2)])
	var fraction := ratio(amount, capacity)
	if fraction > 0.0:
		var right := p.x + 3 + (rect.size.x - 6) * fraction
		var clip := PackedVector2Array([p + Vector2(3, 2), Vector2(right, p.y + 2), Vector2(right, end.y - 2), Vector2(p.x + 3, end.y - 2)])
		for filled in Geometry2D.intersect_polygons(inner, clip):
			if filled.size() >= 3: canvas.draw_colored_polygon(filled, FILL)
	outline.append(outline[0])
	canvas.draw_polyline(outline, Color(ART.PAPER, .55), 1.0, true)
	var baseline := p.y + rect.size.y * .5 + 3.5
	ART.text(canvas, Vector2(p.x + 9, baseline), "能量", 9, Color("eef3e9"), 600)
	var label := "%s / %s" % [number(amount), number(capacity)]
	var width := ART.font(600).get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
	ART.text(canvas, Vector2(end.x - 11 - width, baseline), label, 9, Color("eef3e9"), 600)
