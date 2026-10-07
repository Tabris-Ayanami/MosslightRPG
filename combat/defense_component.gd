extends Node
class_name CombatDefense
## Resolves defense opportunities and their resource costs. The controller owns
## HP damage, exposed states, reaction actions, and forced control transitions.

var actor: Node
var guard_held := false
var guard_time := 0.0
var guard_cooldown := 0.0
var last_outcome := "none"
var _fresh_raise := false
var _shield_perfect_used := false
var _action_perfect_used := false
var _charge_perfect_used := false
var _counter_used := false

func setup(owner_actor: Node) -> void:
	actor = owner_actor
	actor.combat.runner.action_started.connect(_on_action_started)

func tick(delta: float) -> void:
	guard_cooldown = maxf(0.0, guard_cooldown - delta)
	if guard_held and actor.combat.state == "GUARD":
		guard_time += delta
	elif guard_held:
		stop_guard()

func clear() -> void:
	stop_guard()
	guard_cooldown = 0.0
	last_outcome = "none"
	_action_perfect_used = false
	_charge_perfect_used = false
	_counter_used = false

func begin_charge() -> void:
	_charge_perfect_used = false

func shield() -> Dictionary:
	return actor.shield_definition()

func start_guard(fresh := true) -> bool:
	if actor.control_mode == "none" or actor.control_input_blocked():
		return false
	if actor.combat.state == "GUARD" and guard_held:
		return true
	if (actor.combat.state != "GUARD" and not actor.combat.can_start()) or shield().is_empty():
		return false
	guard_held = true
	guard_time = 0.0
	_shield_perfect_used = false
	_fresh_raise = fresh and guard_cooldown <= 0.0
	if _fresh_raise:
		guard_cooldown = .45
	actor.combat.state = "GUARD"
	return true

func stop_guard(_release := true) -> void:
	guard_held = false
	guard_time = 0.0
	_fresh_raise = false
	_shield_perfect_used = false
	if is_instance_valid(actor) and actor.combat.state == "GUARD":
		actor.combat.state = "NORMAL"

func _on_action_started(_action: Dictionary) -> void:
	_action_perfect_used = false
	_counter_used = false

func _within(window: Dictionary) -> bool:
	var time: float = actor.combat.runner.action_time
	return time >= float(window.get("start", 0.0)) and time < float(window.get("end", 0.0))

func _in_front(direction: Vector3, angle: float) -> bool:
	if angle >= 360.0:
		return true
	var incoming := Vector3(-direction.x, 0.0, -direction.z)
	var facing: Vector3 = actor.facing
	facing.y = 0.0
	if incoming.length_squared() < .000001 or facing.length_squared() < .000001:
		return false
	return incoming.normalized().dot(facing.normalized()) >= cos(deg_to_rad(clampf(angle, 0.0, 360.0) * .5)) - .000001

func has_hyper_armor() -> bool:
	if not actor.combat.runner.busy():
		return false
	var window: Dictionary = actor.combat.runner.current_action.get("hyper_armor", {})
	return not window.is_empty() and _within(window)

func _active_guard() -> Dictionary:
	if actor.combat.state == "CHARGING":
		var charging: Dictionary = actor.combat.charge_action
		var charge_window: Dictionary = charging.get("charge_guard_window", {})
		var duration := maxf(.01, float(charging.get("charge_duration", .6)))
		var time: float = actor.combat.charge_time
		if not charge_window.is_empty() and time >= float(charge_window.get("start_ratio", 0.0)) * duration and time < float(charge_window.get("end_ratio", 1.0)) * duration:
			return {"kind": "charge", "window": charge_window}
		return {}
	var action_window: Dictionary = actor.combat.runner.current_action.get("guard_window", {})
	if not action_window.is_empty() and _within(action_window):
		return {"kind": "action", "window": action_window}
	if guard_held and actor.combat.state == "GUARD":
		var shield_window := shield()
		if not shield_window.is_empty():
			return {"kind": "shield", "window": shield_window}
	return {}

func precision_window_active() -> bool:
	var active := _active_guard()
	if active.is_empty():
		return false
	var window: Dictionary = active.window
	match active.kind:
		"charge":
			return not _charge_perfect_used
		"action":
			return not _action_perfect_used and actor.combat.runner.action_time < float(window.get("start", 0.0)) + float(window.get("perfect_window", 0.0))
		"shield":
			return _fresh_raise and not _shield_perfect_used and guard_time < float(window.get("perfect_window", .16))
	return false

func resolve(action: Dictionary, _source: Node, direction: Vector3, dot := false) -> Dictionary:
	last_outcome = "none"
	var result := {"outcome": "none", "blocked": false, "stamina_cost": 0.0, "physical_reduction": 0.0, "elemental_reduction": 0.0}
	if dot or not bool(action.get("blockable", true)) or bool(action.get("grab", false)) or str(action.get("attack_kind", action.get("attack_type", ""))).to_upper() == "GRAB" or str(action.get("presentation_type", "")).to_upper() == "GRAB":
		return result
	var running: Dictionary = actor.combat.runner.current_action
	var counter: Dictionary = running.get("counter_stance", {})
	if not _counter_used and not counter.is_empty() and _within(counter) and _in_front(direction, float(counter.get("angle", 360.0))):
		_counter_used = true
		result["counter_action"] = str(counter.get("counter_action", "fujian_counter"))
		return _outcome(result, "counter")
	var active := _active_guard()
	if active.is_empty():
		return result
	var window: Dictionary = active.window
	if window.is_empty() or not _in_front(direction, float(window.get("angle", 140.0))):
		return result
	if precision_window_active() and bool(action.get("parryable", true)):
		match active.kind:
			"charge": _charge_perfect_used = true
			"action": _action_perfect_used = true
			"shield": _shield_perfect_used = true
		return _outcome(result, "parry")
	var units := maxf(0.0, float(action.get("guard_damage", ceilf(maxf(0.0, float(action.get("poise_damage", 0.0))) / 40.0))))
	var cost := units * maxf(0.0, float(window.get("stamina_cost", 1.0)))
	var resources: Node = actor.resources
	var finite: bool = resources.pools.has("Stamina") and not bool(resources.unlimited.get("Stamina", false))
	if finite and cost > 0.0:
		var available: float = resources.current("Stamina")
		result.stamina_cost = minf(available, cost)
		resources.change("Stamina", -cost)
		if available <= cost:
			return _outcome(result, "guard_break")
	result.physical_reduction = clampf(float(window.get("physical_reduction", 1.0)), 0.0, 1.0)
	result.elemental_reduction = clampf(float(window.get("elemental_reduction", .5)), 0.0, 1.0)
	return _outcome(result, "block")

func _outcome(result: Dictionary, outcome: String) -> Dictionary:
	last_outcome = outcome
	result.outcome = outcome
	result.blocked = outcome in ["block", "parry", "counter"]
	return result
