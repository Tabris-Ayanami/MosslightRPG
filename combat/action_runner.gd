extends Node
class_name CombatActionRunner

signal action_started(action: Dictionary)
signal action_phase_changed(phase: String)
signal action_finished(action: Dictionary)
signal action_cancelled(action: Dictionary)

var current_action: Dictionary = {}
var action_time := 0.0
var action_phase := "NONE"
var active_fired := false

func busy() -> bool:
	return not current_action.is_empty()

func start_action(action: Dictionary) -> bool:
	if busy():
		return false
	current_action = action.duplicate(true)
	action_time = 0.0
	action_phase = "STARTUP"
	active_fired = false
	action_started.emit(current_action)
	action_phase_changed.emit(action_phase)
	return true

func tick(delta: float) -> bool:
	if not busy():
		return false
	action_time += delta
	var startup := float(current_action.get("startup", 0.10))
	var active := float(current_action.get("active", 0.10))
	var recovery := float(current_action.get("recovery", 0.20))
	var phase := "STARTUP" if action_time < startup else ("ACTIVE" if action_time < startup + active else "RECOVERY")
	if phase != action_phase:
		action_phase = phase
		action_phase_changed.emit(phase)
	if phase == "ACTIVE" and not active_fired:
		active_fired = true
		return true
	if action_time >= startup + active + recovery:
		finish_action()
	return false

func cancel_action() -> void:
	if busy():
		var old := current_action
		current_action = {}
		action_phase = "NONE"
		action_cancelled.emit(old)

func finish_action() -> void:
	if busy():
		var old := current_action
		current_action = {}
		action_phase = "NONE"
		action_finished.emit(old)
