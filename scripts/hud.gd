extends Control
## Optional debug overlay. The production HUD remains the original frontend.
var game: Node
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
func _draw() -> void:
	if not game or not game.player:
		return
	var font := ThemeDB.fallback_font
	var p: Node = game.player
	draw_string(font, Vector2(24, 32), "%s · Lv%d · HP %d/%d" % [p.display_name, p.loadout.level, p.resources.current("HP"), p.resources.max_value("HP")], HORIZONTAL_ALIGNMENT_LEFT, -1, 20)
	if game.toast_time > 0:
		draw_string(font, Vector2(24, 60), game.toast_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, game.toast_color)
