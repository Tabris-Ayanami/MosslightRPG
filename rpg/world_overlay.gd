extends Control
## Contextual battle feedback, using the existing palette; no exploration panels.
const GOLD := Color("e8c480")
const TEXT := Color("f1e7ce")
const Art = preload("res://scripts/frontend/ui_art.gd")
var arena: Node
var interaction_text := ""
var stamina_ring = preload("res://combat/stamina_ring.gd").new()
var battle_hud = preload("res://combat/battle_hud.gd").new()
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stamina_ring.attach(self)
	battle_hud.attach(self)
func _process(delta: float) -> void:
	var hidden: bool = not is_instance_valid(arena) or (is_instance_valid(arena.host) and arena.host.paused)
	stamina_ring.update(arena, 0.0 if hidden else delta, hidden and not (is_instance_valid(arena.host) and arena.host.dialogue_open()))
	battle_hud.update(arena, delta, size, hidden)
	queue_redraw()
func _draw() -> void:
	if not is_instance_valid(arena) or not is_instance_valid(arena.player) or (arena.host.paused and not arena.host.dialogue_open()):
		return
	stamina_ring.draw(self)
	if not arena.host.paused: battle_hud.draw(self)

func _exit_tree() -> void:
	battle_hud.clear()
