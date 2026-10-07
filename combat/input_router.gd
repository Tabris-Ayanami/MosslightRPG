extends Node
class_name CombatInputRouter

signal command(kind: String)
signal hold_started(button: String)
signal input_cancelled
signal pointer_cancelled

var buffer := CombatInputBuffer.new()
var hold_threshold := 0.25
var held: Dictionary = {}
var clock := 0.0
var is_blocked: Callable
var is_pointer_blocked: Callable
var is_secondary_guard: Callable
var shield_held := false
var skill_casting: Node
var movement_actions: Node
var _cast_primary := false
var _cast_secondary := false

func _physics_process(delta: float) -> void:
	clock += delta
	buffer.prune(clock)
	if is_blocked.is_valid() and is_blocked.call():
		cancel()
		return
	if is_instance_valid(movement_actions) and movement_actions.airborne:
		cancel()
		return
	var pointer_blocked: bool = is_pointer_blocked.is_valid() and is_pointer_blocked.call()
	if pointer_blocked and (not held.is_empty() or shield_held or Input.is_action_pressed("attack_secondary") and is_secondary_guard.is_valid() and is_secondary_guard.call()):
		if not selection_active(): cancel_pointer()
	if is_instance_valid(skill_casting):
		for index in range(3):
			var skill_key: String = ["skill_q", "skill_e", "skill_r"][index]
			if Input.is_action_just_pressed(skill_key): skill_casting.press(index)
	if is_instance_valid(movement_actions):
		for kind in ["jump", "crouch"]:
			if Input.is_action_just_pressed("move_" + kind): movement_actions.press(kind)
	# Cancellation takes priority over releasing any quick-cast key in the
	# same frame. Capture the whole right-click, including its release.
	if Input.is_action_just_pressed("attack_secondary"): cancel_cast_from_pointer()
	if is_instance_valid(skill_casting):
		for index in range(3):
			if Input.is_action_just_released(["skill_q", "skill_e", "skill_r"][index]): skill_casting.release(index)
	if is_instance_valid(movement_actions):
		for kind in ["jump", "crouch"]:
			if Input.is_action_just_released("move_" + kind): movement_actions.release(kind)
	if Input.is_action_just_pressed("attack_primary") and selection_active():
		_cast_primary = true
		held.erase("attack_primary")
		var selector: Node = movement_actions if is_instance_valid(movement_actions) and movement_actions.active() else skill_casting
		if not pointer_blocked and selector.mode == "precise": selector.confirm()
	if Input.is_action_just_pressed("guard"):
		command.emit("guard_pressed")
	if Input.is_action_just_released("guard"):
		command.emit("guard_released")
	for action in ["attack_primary", "attack_secondary"]:
		var captured: bool = _cast_primary if action == "attack_primary" else _cast_secondary
		if captured:
			if Input.is_action_just_released(action):
				if action == "attack_primary": _cast_primary = false
				else: _cast_secondary = false
			continue
		if selection_active() or is_instance_valid(movement_actions) and movement_actions.airborne: continue
		if pointer_blocked:
			continue
		if action == "attack_secondary" and is_secondary_guard.is_valid() and is_secondary_guard.call():
			if Input.is_action_just_pressed(action):
				command.emit("shield_pressed")
				shield_held = true
			if Input.is_action_just_released(action):
				shield_held = false
				command.emit("shield_released")
			continue
		if Input.is_action_just_pressed(action):
			held[action] = clock
			hold_started.emit("PRIMARY" if action == "attack_primary" else "SECONDARY")
		if Input.is_action_just_released(action) and held.has(action):
			var prefix := "PRIMARY" if action == "attack_primary" else "SECONDARY"
			var kind := prefix + ("_CHARGE" if clock - float(held[action]) >= hold_threshold else "_TAP")
			held.erase(action)
			buffer.push(kind, clock)
			command.emit(kind)
	for action in ["dodge_dash", "switch_combat_set", "lock_target", "quick_item_1", "quick_item_2", "quick_item_3", "quick_item_4"]:
		if Input.is_action_just_pressed(action, action.begins_with("quick_item_")):
			command.emit(action)

func cancel_cast_from_pointer() -> bool:
	if _cast_secondary: return true
	if not selection_active() and not cast_pending(): return false
	if is_instance_valid(skill_casting): skill_casting.cancel()
	if is_instance_valid(movement_actions): movement_actions.cancel()
	_cast_secondary = true
	held.erase("attack_secondary")
	return true

func selection_active() -> bool:
	return is_instance_valid(skill_casting) and skill_casting.active() or is_instance_valid(movement_actions) and movement_actions.active()

func cast_pending() -> bool:
	return is_instance_valid(skill_casting) and skill_casting.pending()

func cancel() -> void:
	if not Input.is_action_pressed("attack_primary"): _cast_primary = false
	if not Input.is_action_pressed("attack_secondary"): _cast_secondary = false
	shield_held = false
	held.clear()
	buffer.clear()
	input_cancelled.emit()

func cancel_pointer() -> void:
	if not Input.is_action_pressed("attack_primary"): _cast_primary = false
	if not Input.is_action_pressed("attack_secondary"): _cast_secondary = false
	shield_held = false
	held.clear()
	buffer.clear()
	pointer_cancelled.emit()
