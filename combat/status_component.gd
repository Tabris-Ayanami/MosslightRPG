extends Node

signal status_added(id: String)
signal status_removed(id: String)

var actor: Node
var entries: Dictionary = {}

func add_status(id: String, definition: Dictionary, source: Node = null) -> void:
	var data := definition.duplicate(true)
	data["remaining"] = float(data.get("duration", 3.0))
	data["permanent"] = float(data.get("duration", 3.0)) < 0.0
	data["clock"] = 0.0
	data["source"] = weakref(source) if is_instance_valid(source) else null
	data["stacks"] = 1
	if entries.has(id):
		if data.get("stack_rule", "refresh") == "stack":
			data.stacks = mini(int(entries[id].stacks) + 1, int(data.get("max_stacks", 1)))
		elif data.get("stack_rule", "refresh") == "ignore":
			return
	entries[id] = data
	if data.has("stats"):
		actor.stats.add_modifier("status_" + id, data.stats)
	status_added.emit(id)

func remove_status(id: String) -> void:
	if entries.erase(id):
		actor.stats.remove_modifier("status_" + id)
		if id == "shield":
			actor.health.shield = 0.0
		status_removed.emit(id)

func has_status(id: String) -> bool:
	return entries.has(id)

func tick(delta: float) -> void:
	for id in entries.keys():
		var data: Dictionary = entries[id]
		var step := delta if data.permanent else minf(delta, maxf(0.0, float(data.remaining)))
		data.remaining -= delta
		data.clock += step
		var interval := float(data.get("tick_interval", 0.0))
		while interval > 0.0 and float(data.clock) + 0.00001 >= interval:
			data.clock -= interval
			var source: Node = data.source.get_ref() if data.source != null else null
			var ctx: Dictionary = source.combat.context(actor) if is_instance_valid(source) else actor.combat.context()
			if not CombatConditions.check_all(data.get("conditions", []), ctx).is_empty():
				continue
			if data.has("tick_damage"):
				var packet: Dictionary = data.tick_damage.duplicate(true)
				for stat in packet.get("formula", {}):
					packet.formula[stat] *= int(data.get("stacks", 1))
				actor.combat.receive_damage(packet, source, Vector3.ZERO, true)
			for effect in data.get("tick_effects", []):
				actor.combat.apply_effect(effect, source)
		if not data.permanent and float(data.remaining) <= 0.0:
			remove_status(id)

func modifiers() -> Dictionary:
	var result: Dictionary = {}
	for data in entries.values():
		var source: Node = data.source.get_ref() if data.source != null else null
		var ctx: Dictionary = source.combat.context(actor) if is_instance_valid(source) else actor.combat.context()
		if not CombatConditions.check_all(data.get("conditions", []), ctx).is_empty():
			continue
		for effect in data.get("effects", []):
			if effect.get("type", "") == "modifier" and CombatConditions.check_all(effect.get("conditions", []), ctx).is_empty():
				var stat: String = effect.get("stat", "")
				result[stat] = float(result.get(stat, 0.0)) + float(effect.get("value", 0.0)) * int(data.get("stacks", 1))
	return result

func consume_for(action: Dictionary) -> void:
	for id in entries.keys():
		var rule: Variant = entries[id].get("consume_on", "")
		if entries[id].get("skill_only", false) and not action.get("is_skill", false):
			continue
		var damaging := false
		for coefficient in action.get("formula", {}).values():
			if float(coefficient) > 0.0:
				damaging = true
		if rule in ["attack", "damage", "damage_attack"] and damaging or rule == action.get("presentation_type", "") or entries[id].get("break_on_attack", false) and damaging:
			remove_status(id)

func clear() -> void:
	for id in entries.keys():
		remove_status(id)
