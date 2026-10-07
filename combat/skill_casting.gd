extends Node
## Human selection has no combat cost. Confirmation snapshots the intent and
## delegates validation, payment and legal animation handoff to the controller.
const Preferences = preload("res://rpg/game_preferences.gd")
const Indicator = preload("res://combat/cast_indicator.gd")
var actor: Node
var slot := -1
var mode := Preferences.CAST_QUICK
var source := "key"
var action: Dictionary = {}
var preview: Dictionary = {}
var invalid_reason := ""
var indicator: Node3D

func setup(owner_actor: Node) -> void:
	actor = owner_actor
	indicator = Indicator.new()
	actor.add_child(indicator)
	indicator.actor = actor
	indicator.visible = false

func active() -> bool: return slot >= 0

func pending() -> bool:
	return actor.combat.queued_command.get("action", {}).has("cast_intent")

func press(index: int, origin := "key") -> bool:
	if index < 0 or index > 2 or not actor.is_human_controlled() or actor.control_input_blocked(): return false
	if active() and slot == index and mode == Preferences.CAST_PRECISE: return confirm()
	var candidate: Dictionary = actor.skill_at(index).duplicate(true)
	if candidate.is_empty(): return actor.combat.fail("此槽位尚未备战技能")
	candidate["skill_set"] = actor.loadout.current_set
	candidate["innate_action"] = actor.is_innate_action(candidate)
	var failure: String = actor.combat.skill_input_failure(candidate, true)
	if not failure.is_empty(): return actor.combat.fail(failure)
	# Discard a held weapon wind-up before starting selection. Existing attack
	# animations continue and retain their original skill/dodge cancel gates.
	actor.input_router.cancel_pointer()
	slot = index
	action = candidate
	source = origin
	mode = Preferences.get_cast_mode(Preferences.SKILL_ACTIONS[index]) if origin == "key" else Preferences.CAST_PRECISE
	update_selection()
	return true

func release(index: int) -> bool:
	if not active() or slot != index or source != "key" or mode != Preferences.CAST_QUICK: return false
	return confirm()

func cancel() -> void:
	slot = -1
	action.clear()
	preview.clear()
	invalid_reason = ""
	if is_instance_valid(indicator): indicator.visible = false
	if is_instance_valid(actor) and pending(): actor.combat.queued_command.clear()

func confirm() -> bool:
	if not active(): return false
	update_selection()
	if not invalid_reason.is_empty():
		actor.combat.fail(invalid_reason)
		if mode == Preferences.CAST_QUICK: cancel()
		return false
	var chosen := action.duplicate(true)
	chosen["cast_intent"] = preview.intent.duplicate()
	var index := slot
	# Controller transition cancels inputs; close selection before it can reenter
	# this component. The chosen action retains its independent target snapshot.
	cancel()
	return actor.combat.request_skill(index, chosen)

func _physics_process(_delta: float) -> void:
	if not active(): return
	if not actor.is_human_controlled() or actor.control_input_blocked() or actor.combat.state in ["HITSTUN", "KNOCKDOWN", "DEAD", "GRABBED", "GRABBING", "EXPOSED", "GUARD_BROKEN"]:
		cancel()
		return
	if actor.loadout.current_set != int(action.skill_set) or actor.skill_at(slot).get("id", "") != action.get("id", ""):
		cancel()
		return
	update_selection()

func update_selection() -> void:
	if not active(): return
	var point: Vector3 = actor.arena.action_aim_point(actor, action)
	var origin: Vector3 = actor.global_position
	var target: Node = actor.arena.target_for_selection(actor, str(action.get("target_relation", "hostile"))) if action.get("targeting", "") == "TARGET" else null
	if is_instance_valid(target): point = target.global_position
	var direction := Vector3(point.x - origin.x, 0, point.z - origin.z)
	direction = direction.normalized() if direction.length_squared() > .0001 else actor.facing
	var reach: float = actor.combat._action_reach(action, target)
	if action.get("targeting", "") != "TARGET": point = actor.arena.clamp_aim_point(origin, point, reach)
	var intent := {"point": point, "direction": direction, "target": weakref(target) if is_instance_valid(target) else null}
	var selected := action.duplicate(true)
	selected["cast_intent"] = intent
	invalid_reason = actor.combat.skill_input_failure(selected)
	if actor.arena.pointer_blocked: invalid_reason = "请将鼠标移到战斗场景中"
	selected["range"] = reach
	var modifiers: Dictionary = actor.combat.passives.modifiers("damage_before", actor.combat.context(null, selected), actor.combat._action_weapon(selected))
	var area_scale := 1.0 + float(modifiers.get("area_multiplier", 0.0))
	for dimension in ["radius", "width", "length", "explosion_radius"]:
		if selected.has(dimension): selected[dimension] *= area_scale
	preview = {"action": selected, "origin": origin, "intent": intent, "valid": invalid_reason.is_empty()}
	indicator.show_preview(preview)

func _exit_tree() -> void:
	if is_instance_valid(indicator): indicator.queue_free()
