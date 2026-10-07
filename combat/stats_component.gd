extends Node
class_name CombatStats

signal changed

const IDS := ["STR", "DEX", "CON", "INT", "PER", "CHA"]
const CONTEXT_IDS := ["STR", "DEX", "CON", "INT", "PER", "CHA", "Armor"]
var base: Dictionary = {}
var modifiers: Dictionary = {}

func set_base(values: Dictionary) -> void:
	base = values.duplicate(true)
	changed.emit()

func get_stat(stat_id: String) -> float:
	return float(base.get(stat_id, 0.0))

func get_final_stat(stat_id: String) -> float:
	var value := get_stat(stat_id)
	for entry in modifiers.values():
		value += float(entry.get(stat_id, 0.0))
	return value

func final_values() -> Dictionary:
	# A fresh snapshot observes direct modifier edits as well as signalled ones.
	# Traverse modifier collections once when combat needs the whole stat block.
	var result: Dictionary = {}
	for id in CONTEXT_IDS: result[id] = float(base.get(id, 0.0))
	for entry in modifiers.values():
		for id in CONTEXT_IDS: result[id] += float(entry.get(id, 0.0))
	return result

func add_modifier(source: String, values: Dictionary) -> void:
	modifiers[source] = values.duplicate(true)
	changed.emit()

func remove_modifier(source: String) -> void:
	if modifiers.erase(source):
		changed.emit()
