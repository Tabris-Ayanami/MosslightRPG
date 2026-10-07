extends RefCounted
## Owns only traversal. Combat retains its supported states, cooldowns and HP.
const CLIMB_SPEED := 1.85
const END_REACH := .45
var actor: CharacterBody3D
var game: Node
var active := false
var active_ladder: Node3D
var phase := 0.0
var last_reason := ""
var _router_was_processing := true
var _bottom := Vector3.ZERO
var _top := Vector3.ZERO
var _distance := 0.0
var _height := 0.0

func setup(owner_actor: CharacterBody3D, owner_game: Node) -> void:
	actor = owner_actor
	game = owner_game

func try_interact(prop: Node3D) -> bool:
	if active:
		detach("manual", true)
		return true
	if not is_instance_valid(prop) or not prop.has_method("bottom_anchor"):
		return false
	if not is_instance_valid(game) or not actor.is_human_controlled() or game.paused or actor.combat.state not in ["NORMAL", "MOVE"] or actor.combat.runner.busy():
		return false
	if prop.interaction_distance(actor.global_position) > 2.15:
		return false
	active_ladder = prop
	_bottom = prop.bottom_anchor()
	_top = prop.top_anchor()
	_height = _top.distance_to(_bottom)
	if _height <= .1:
		active_ladder = null
		return false
	var enter_top: bool = actor.global_position.distance_to(prop.top_exit()) < actor.global_position.distance_to(prop.bottom_exit())
	var entry: Vector3 = _top if enter_top else _bottom
	if not actor.movement_actions.stand_for_action(): return false
	if not _clear_motion(actor.global_position, entry):
		last_reason = "entry_blocked"
		active_ladder = null
		return false
	_distance = _height if enter_top else 0.0
	actor.input_router.cancel()
	actor.combat.clear_input_intent()
	_router_was_processing = actor.input_router.is_physics_processing()
	actor.input_router.set_physics_process(false)
	actor.set_meta("traversal_locked", true)
	actor.velocity = Vector3.ZERO
	actor.move_direction = Vector3.ZERO
	actor.facing = prop.facing_direction()
	actor.combat.state = "NORMAL"
	active = true
	phase = 0.0
	last_reason = "entered_top" if enter_top else "entered_bottom"
	actor.global_position = _top if enter_top else _bottom
	_pose(false)
	return true

func tick(delta: float) -> bool:
	if not active: return false
	if not is_instance_valid(active_ladder):
		cleanup()
		return false
	if game.paused or actor.get_tree().paused:
		_pose(false)
		return true
	actor.combat.tick(delta)
	if actor.inventory: actor.inventory.tick(delta)
	if actor.combat.state not in ["NORMAL", "MOVE"]:
		detach("interrupted", false)
		return true
	var direction := Input.get_axis("move_down", "move_up")
	var movement := direction * CLIMB_SPEED * delta
	var next_distance := clampf(_distance + movement, 0.0, _height)
	var next_position := _bottom.lerp(_top, next_distance / _height)
	if not _clear_motion(actor.global_position, next_position):
		last_reason = "climb_blocked"
		_pose(false)
		return true
	var traveled := next_distance - _distance
	_distance = next_distance
	phase = fposmod(phase + traveled / 1.2, 1.0)
	actor.velocity = Vector3.ZERO
	actor.move_direction = Vector3.ZERO
	actor.global_position = _bottom.lerp(_top, _distance / _height)
	_pose(absf(traveled) > .00001)
	if direction > 0 and _distance >= _height:
		_exit_endpoint(active_ladder.top_exit(), "top")
	elif direction < 0 and _distance <= 0:
		_exit_endpoint(active_ladder.bottom_exit(), "bottom")
	return true

func stable_position() -> Vector3:
	if active and is_instance_valid(active_ladder):
		var preferred: Vector3 = active_ladder.top_exit() if _distance > _height * .5 else active_ladder.bottom_exit()
		var other: Vector3 = active_ladder.bottom_exit() if _distance > _height * .5 else active_ladder.top_exit()
		if _safe_landing(preferred): return preferred
		if _safe_landing(other): return other
		return game.checkpoint
	return actor.global_position

func detach(reason := "manual", safe_exit := true) -> void:
	if not active: return
	if safe_exit and is_instance_valid(active_ladder):
		if _distance <= END_REACH:
			_exit_endpoint(active_ladder.bottom_exit(), reason)
			return
		elif _height - _distance <= END_REACH:
			_exit_endpoint(active_ladder.top_exit(), reason)
			return
		else:
			# Release at the current height, with a swept capsule clearance away
			# from the rungs. Normal gravity resumes; F cannot skip half the climb.
			var away: Vector3 = -active_ladder.facing_direction() * .5
			if _clear_motion(actor.global_position, actor.global_position + away):
				actor.global_position += away
	last_reason = reason
	cleanup()

func cleanup() -> void:
	var was_active := active
	active = false
	active_ladder = null
	if not is_instance_valid(actor): return
	if actor.has_meta("traversal_locked"): actor.remove_meta("traversal_locked")
	if was_active:
		actor.velocity = Vector3.ZERO
		actor.move_direction = Vector3.ZERO
		actor.input_router.cancel()
		actor.input_router.set_physics_process(_router_was_processing)
	_pose(false)

func _exit_endpoint(destination: Vector3, reason: String) -> bool:
	if not _safe_landing(destination) or not _clear_motion(actor.global_position, destination):
		last_reason = "exit_blocked"
		_pose(false)
		return false
	actor.global_position = destination
	detach(reason, false)
	return true

func _shape_at(at: Vector3) -> PhysicsShapeQueryParameters3D:
	var collision := actor.get_node("CollisionShape3D") as CollisionShape3D
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = collision.shape
	query.transform = Transform3D(actor.global_basis, at + Vector3.UP * .012) * collision.transform
	query.collision_mask = actor.collision_mask
	query.exclude = [actor.get_rid()]
	query.margin = .001
	return query

func _clear_motion(from: Vector3, to: Vector3) -> bool:
	var space := actor.get_world_3d().direct_space_state
	var query := _shape_at(from)
	query.motion = to - from
	var fractions := space.cast_motion(query)
	if fractions.size() < 2 or fractions[0] < .999: return false
	query = _shape_at(to)
	return space.intersect_shape(query, 1).is_empty()

func _safe_landing(at: Vector3) -> bool:
	var space := actor.get_world_3d().direct_space_state
	if not space.intersect_shape(_shape_at(at), 1).is_empty(): return false
	# Support under the center and capsule footprint prevents a false landing
	# on an edge, steep original roof, or a removed/obstructed maintenance board.
	for offset in [Vector3.ZERO, Vector3.RIGHT * .16, Vector3.LEFT * .16, Vector3.FORWARD * .16, Vector3.BACK * .16]:
		var start: Vector3 = at + offset + Vector3.UP * .08
		var query := PhysicsRayQueryParameters3D.create(start, start + Vector3.DOWN * .4, actor.collision_mask, [actor.get_rid()])
		var hit := space.intersect_ray(query)
		if hit.is_empty() or hit.normal.y < cos(deg_to_rad(48)): return false
	return true

func _pose(moving: bool) -> void:
	if is_instance_valid(actor.animation) and actor.animation.has_method("set_climbing"):
		actor.animation.set_climbing(active, phase, moving)
