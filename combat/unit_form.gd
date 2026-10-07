extends RefCounted
## A reversible definition overlay on the same unit, never a new controller.
const Definitions = preload("res://combat/unit_definition.gd")
const RESOURCE_IDS := ["HP", "Stamina", "Energy"]
const STAT_IDS := ["STR", "DEX", "CON", "INT", "PER", "CHA"]
signal changed
var actor: Node
var active := false
var form_id := ""
var remaining := 0.0
var last_error := ""
var _snapshot: Dictionary = {}
var _ratios: Dictionary = {}
var _transitioning := false

func setup(owner_actor: Node) -> void:
	actor = owner_actor
	if actor.combat != null and not actor.combat.died.is_connected(_on_death):
		actor.combat.died.connect(_on_death)

func apply_enemy_form(id: String, duration: float = 10.0) -> bool:
	last_error = ""
	if not is_instance_valid(actor) or _transitioning:
		last_error = "单位尚未就绪"
		return false
	if actor.combat.state == "DEAD" or actor.resources.current("HP") <= 0.0:
		last_error = "死亡时不能变身"
		return false
	if not is_finite(duration) or duration <= 0.0:
		last_error = "变身持续时间必须大于零"
		return false
	var next: Dictionary = Definitions.for_enemy(actor.arena.database, id)
	if next.is_empty():
		last_error = "变身形态不存在"
		return false
	_transitioning = true
	if not active:
		_snapshot = {"definition": actor.definition.duplicate(true), "race_id": actor.race_id,
			"stats_base": actor.stats.base.duplicate(true), "loadout": actor.loadout.export_state(),
			"max_resources": canonical_max_resources()}
		_ratios.clear()
	_ratios = _current_ratios()
	var poise_ratio := _poise_ratio()
	_cancel_action()
	active = true
	form_id = id
	remaining = duration
	actor.apply_definition(next, false, true)
	_apply_ratios(_ratios)
	actor.combat.current_poise = actor.combat.max_poise() * poise_ratio
	_transitioning = false
	changed.emit()
	return true

func tick(delta: float) -> void:
	if not active or _transitioning:
		return
	if actor.combat.state == "DEAD" or actor.resources.current("HP") <= 0.0:
		restore("death")
		return
	remaining = maxf(0.0, remaining - maxf(0.0, delta))
	if remaining <= 0.0:
		restore("expired")

func restore(_reason: String = "manual") -> bool:
	if not active or _transitioning or not is_instance_valid(actor):
		return false
	_transitioning = true
	var ratios := _current_ratios()
	var poise_ratio := _poise_ratio()
	var original := canonical_definition()
	var original_base := canonical_attributes()
	var dead: bool = actor.combat.state == "DEAD" or actor.resources.current("HP") <= 0.0
	_cancel_action()
	# Real loadout/inventory/progression remain live throughout transformation.
	# In particular, do not import the old loadout and erase XP, learned skills,
	# or newly obtained/equipped items acquired while the temporary form existed.
	active = false
	form_id = ""
	remaining = 0.0
	actor.apply_definition(original, false, true)
	actor.stats.set_base(original_base)
	actor.loadout._rebuild(false)
	_apply_ratios(ratios)
	actor.combat.current_poise = actor.combat.max_poise() * poise_ratio
	if dead:
		actor.combat.state = "DEAD"
		actor.collision_layer = 0
		actor.animation.play_hit("DEAD")
	_snapshot.clear()
	_ratios.clear()
	_transitioning = false
	changed.emit()
	return true

func clear_for_load() -> void:
	# Called only after a save has been fully validated, before its values replace
	# live state. The save loader subsequently restores HP and controller state.
	restore("load")

func _on_death() -> void:
	restore("death")

func _cancel_action() -> void:
	var combat: Node = actor.combat
	var dead: bool = combat.state == "DEAD"
	combat._release_grab(false)
	if actor.input_router != null:
		actor.input_router.cancel()
	combat.clear_input_intent()
	combat.clear_hitstop()
	combat.runner.cancel_action()
	combat.defense.clear()
	combat.guard_counter_time = 0.0
	combat.combo = 0
	combat.combo_timeout = 0.0
	combat.knockback = Vector3.ZERO
	combat.state = "DEAD" if dead else "NORMAL"
	actor.velocity = Vector3.ZERO
	var ladder: Variant = actor.get("ladder")
	if ladder != null:
		ladder.cleanup()
	var surface: Variant = actor.get("surface_traversal")
	if surface != null:
		surface.clear()

func _poise_ratio() -> float:
	return clampf(actor.combat.current_poise / maxf(.001, actor.combat.max_poise()), 0.0, 1.0)

func _current_ratios() -> Dictionary:
	var result := _ratios.duplicate()
	for id: String in RESOURCE_IDS:
		var maximum: float = actor.resources.max_value(id)
		if maximum > 0.0:
			result[id] = clampf(actor.resources.current(id) / maximum, 0.0, 1.0)
		elif not result.has(id):
			result[id] = 0.0
	return result

func _apply_ratios(ratios: Dictionary) -> void:
	for id: String in RESOURCE_IDS:
		var value: float = actor.resources.max_value(id) * float(ratios.get(id, 0.0))
		# A change of units preserves a resource ratio; it is not a paid action.
		actor.resources.change(id, value - actor.resources.current(id), false)

func canonical_race_id() -> String:
	return str(_snapshot.race_id) if active else str(actor.race_id)

func canonical_attributes() -> Dictionary:
	return _snapshot.stats_base.duplicate(true) if active else actor.stats.base.duplicate(true)

func canonical_final_stat(id: String) -> float:
	var value: float = float(canonical_attributes().get(id, 0.0))
	for modifier: Dictionary in actor.stats.modifiers.values():
		value += float(modifier.get(id, 0.0))
	return value

func canonical_definition() -> Dictionary:
	var result: Dictionary = _snapshot.definition.duplicate(true) if active else actor.definition.duplicate(true)
	result["race_id"] = canonical_race_id()
	result["stats"] = canonical_attributes()
	return result

func canonical_loadout() -> Dictionary:
	return actor.loadout.export_state()

func canonical_max_resources() -> Dictionary:
	var result: Dictionary = {}
	if not active:
		for id: String in RESOURCE_IDS:
			result[id] = actor.resources.max_value(id)
		return result
	var definition: Dictionary = _snapshot.definition
	var formulas: Dictionary = {"HP": 100, "Stamina": 3}
	if not actor.loadout.career_ids.is_empty():
		formulas = actor.loadout.database.careers[actor.loadout.career_ids[0]].get("formulas", {})
	var profile: Dictionary = definition.get("resource_profile", {})
	for id: String in RESOURCE_IDS:
		result[id] = maxf(0.0, _canonical_formula(profile.get(id, formulas.get(id, 0))))
	if not profile.has("Energy") and (profile.has("Qi") or profile.has("SpellSlot")):
		result.Energy = _legacy_energy_maximum(profile)
	elif not profile.has("Energy") and not formulas.has("Energy"):
		result.Energy = _legacy_energy_maximum(formulas)
	return result

func _legacy_energy_maximum(formulas: Dictionary) -> float:
	return maxf(_canonical_formula(formulas.get("Qi", 0)), _canonical_formula(formulas.get("SpellSlot", 0))) * CombatResources.LEGACY_ENERGY_SCALE

func canonical_resources() -> Dictionary:
	if not active:
		var actual: Dictionary = {}
		for id: String in RESOURCE_IDS:
			actual[id] = actor.resources.current(id)
		return actual
	var result := canonical_max_resources()
	var ratios := _current_ratios()
	for id: String in result:
		result[id] *= float(ratios.get(id, 0.0))
	return result

func _canonical_formula(formula: Variant) -> float:
	if formula is float or formula is int:
		return float(formula)
	# Evaluate trusted catalog formulas against the original body and current
	# growth/equipment without temporarily mutating the live transformed actor.
	var expression := Expression.new()
	var names := PackedStringArray(STAT_IDS + ["level"])
	if expression.parse(str(formula), names) != OK:
		return 0.0
	var values: Array = []
	var base: Dictionary = _snapshot.stats_base
	for id: String in STAT_IDS:
		var value: float = float(base.get(id, 0.0))
		for modifier: Dictionary in actor.stats.modifiers.values():
			value += float(modifier.get(id, 0.0))
		values.append(value)
	values.append(actor.loadout.level)
	var result: Variant = expression.execute(values, null, false)
	return 0.0 if expression.has_execute_failed() else float(result)
