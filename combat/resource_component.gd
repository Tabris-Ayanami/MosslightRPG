extends Node
class_name CombatResources

signal resource_changed(id: String, current: float, maximum: float)
signal resource_spent(id: String, amount: float)
signal died

const IDS := ["HP", "Stamina", "Energy"]
const LEGACY_ENERGY_SCALE := 20.0

var pools: Dictionary = {}
var unlimited: Dictionary = {}

static func migrated_values(values: Dictionary) -> Dictionary:
	var result := values.duplicate(true)
	if not result.has("Energy") and (result.has("Qi") or result.has("SpellSlot")):
		result["Energy"] = maxf(float(result.get("Qi", 0)), float(result.get("SpellSlot", 0))) * LEGACY_ENERGY_SCALE
	result.erase("Qi")
	result.erase("SpellSlot")
	return result

func configure(id: String, maximum: float, fill := true, preserve_ratio := false) -> void:
	if id not in IDS: return
	var previous := current(id)
	var previous_max := max_value(id)
	if preserve_ratio and not fill and previous_max > 0.0:
		previous = maximum * clampf(previous / previous_max, 0.0, 1.0)
	pools[id] = {"max": maxf(0.0, maximum), "current": maximum if fill else minf(previous, maximum)}
	resource_changed.emit(id, current(id), max_value(id))

func current(id: String) -> float:
	return float(pools.get(id, {}).get("current", 0.0))

func max_value(id: String) -> float:
	return float(pools.get(id, {}).get("max", 0.0))

func can_pay(costs: Dictionary) -> bool:
	for id in costs:
		if not unlimited.get(id, false) and current(id) < float(costs[id]):
			return false
	return true

func pay(costs: Dictionary) -> bool:
	if not can_pay(costs):
		return false
	for id in costs:
		if not unlimited.get(id, false):
			change(id, -float(costs[id]))
	return true

func change(id: String, amount: float, spending := true) -> void:
	if not pools.has(id):
		return
	var old := current(id)
	pools[id]["current"] = clampf(old + amount, 0.0, max_value(id))
	if old != current(id):
		if spending and current(id) < old:
			resource_spent.emit(id, old - current(id))
		resource_changed.emit(id, current(id), max_value(id))
		if id == "HP" and current(id) <= 0.0:
			died.emit()

func restore_all() -> void:
	for id in pools:
		pools[id]["current"] = max_value(id)
		resource_changed.emit(id, current(id), max_value(id))
