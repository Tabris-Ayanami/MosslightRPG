extends RefCounted
## Shared step/shore planning and continuous, swept movement in world space.
## Finding a reachable landing never assigns the actor directly to that point.
const LAND_STEP := .40
const SHORE_STEP := .95
const DODGE_LAND_STEP := .65
const DODGE_SHORE_STEP := 1.35
const LAND_REACH := .50
const SHORE_REACH := 1.05
const DODGE_REACH := 1.65
const WALK_SLOPE := 65.0
const DODGE_SLOPE := 70.0
const SKIN := .018
var cooldown := 0.0
var steps := 0
var last_step: Dictionary = {}
var last_reason := ""
var active := false
var _path: Array[Vector3] = []
var _forward := Vector3.ZERO
var _last_position := Vector3.ZERO
var _slope := WALK_SLOPE
var _release_to_gravity := false
var _path_vertical_speed := 0.0

func clear() -> void:
	cooldown = 0.0
	active = false
	_path.clear()
	_release_to_gravity = false
	_path_vertical_speed = 0.0
	last_step.clear()
	last_reason = ""

func _allowed(actor: CharacterBody3D) -> bool:
	return actor.combat.state in ["NORMAL", "MOVE", "DODGE"] and not actor.control_input_blocked()

func consume_gravity_release() -> bool:
	var released := _release_to_gravity
	_release_to_gravity = false
	return released

func advance(actor: CharacterBody3D, desired: Vector3, delta: float) -> bool:
	if not active:
		return false
	var horizontal := Vector3(desired.x, 0, desired.z)
	# Release/turn/control effects cancel traversal instead of pulling the player
	# to an old endpoint. A teleport/restore also invalidates this path.
	if not _allowed(actor) or horizontal.length_squared() < .01 or horizontal.normalized().dot(_forward) < .5 or actor.global_position.distance_to(_last_position) > .06:
		active = false
		_path.clear()
		# Preserve a newly applied launch impulse, but remove our own lifting
		# velocity. The next regular movement pass must not use a stale floor snap.
		if actor.velocity.y <= _path_vertical_speed + .1:
			actor.velocity.y = minf(0, actor.velocity.y)
		_release_to_gravity = true
		last_reason = "interrupted"
		return false
	var before := actor.global_position
	var budget := maxf(3.0, horizontal.length()) * delta
	while budget > .00001 and not _path.is_empty():
		var offset := _path[0] - actor.global_position
		if offset.length() < .001:
			_path.pop_front()
			continue
		var motion := offset.limit_length(budget)
		var hit: KinematicCollision3D = actor.move_and_collide(motion)
		budget -= motion.length()
		if hit != null:
			active = false
			_path.clear()
			actor.velocity = Vector3.ZERO
			_release_to_gravity = true
			last_reason = "path_blocked"
			return true
		if actor.global_position.distance_to(_path[0]) < .001:
			_path.pop_front()
	_last_position = actor.global_position
	actor.velocity = (actor.global_position - before) / maxf(delta, .00001)
	_path_vertical_speed = actor.velocity.y
	if _path.is_empty():
		active = false
		actor.velocity.y = 0
		cooldown = .08
		steps += 1
		last_reason = "stepped"
	return true

func try_step(actor: CharacterBody3D, previous: Vector3, desired: Vector3, delta: float, at_water: bool) -> bool:
	cooldown = maxf(0, cooldown - delta)
	last_reason = ""
	if active or cooldown > 0 or not _allowed(actor):
		return false
	var horizontal := Vector3(desired.x, 0, desired.z)
	if horizontal.length_squared() < .01 or (not actor.is_on_floor() and not at_water):
		return false
	var forward := horizontal.normalized()
	var progress := (actor.global_position - previous).dot(forward)
	var dodging: bool = actor.combat.state == "DODGE"
	_slope = DODGE_SLOPE if dodging else WALK_SLOPE
	var wall := false
	for i in range(actor.get_slide_collision_count()):
		var hit := actor.get_slide_collision(i)
		if hit.get_normal().y < cos(deg_to_rad(_slope)) and hit.get_normal().dot(forward) < -.2:
			wall = true
	if not wall or progress > maxf(.025, horizontal.length() * delta * .8):
		return false
	var collision := actor.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision == null or collision.disabled or collision.shape == null:
		return false
	var space := actor.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = collision.shape
	query.collision_mask = actor.collision_mask
	query.exclude = [actor.get_rid()]
	query.margin = .002
	var origin := actor.global_position
	var max_step: float = SHORE_STEP if at_water else LAND_STEP
	var reach: float = SHORE_REACH if at_water else LAND_REACH
	if dodging:
		max_step = DODGE_SHORE_STEP if at_water else DODGE_LAND_STEP
		reach = DODGE_REACH if at_water else .85
	var raised := origin + Vector3.UP * (max_step + SKIN * 2)
	if not _clear_motion(space, query, actor, collision, origin, raised):
		last_reason = "overhead"
		return false
	for portion in [.45, .7, 1.0]:
		var across := raised + forward * reach * float(portion)
		if not _clear_motion(space, query, actor, collision, raised, across):
			last_reason = "forward"
			continue
		_set_transform(query, actor, collision, across)
		query.motion = Vector3.DOWN * (max_step + SKIN * 2 + .12)
		var fractions := space.cast_motion(query)
		if fractions.size() < 2 or fractions[0] >= .999:
			last_reason = "no_support"
			continue
		var landing := across + query.motion * fractions[0] + Vector3.UP * SKIN
		var rise := landing.y - origin.y
		if rise < .045 or rise > max_step + SKIN * 2:
			last_reason = "height"
			continue
		if not _supported(space, actor, landing, forward):
			last_reason = "slope_or_edge"
			continue
		_set_transform(query, actor, collision, landing)
		query.motion = Vector3.ZERO
		if not space.intersect_shape(query, 1).is_empty():
			last_reason = "landing_clearance"
			continue
		# Find the lowest clear horizontal sweep above the landing so shallow
		# steps do not lift the body to the full maximum permitted step height.
		var low := maxf(origin.y, landing.y)
		var high := raised.y
		for iteration in range(6):
			var middle := (low + high) * .5
			var a := Vector3(origin.x, middle, origin.z)
			var b := Vector3(across.x, middle, across.z)
			if _clear_motion(space, query, actor, collision, a, b): high = middle
			else: low = middle
		raised.y = high
		across.y = high
		_path.assign([raised, across, landing])
		_forward = forward
		_last_position = origin
		_path_vertical_speed = 0.0
		active = true
		last_step = {"from": origin, "raised": raised, "across": across, "landing": landing, "rise": rise, "reach": reach * float(portion), "shore": at_water, "dodge": dodging}
		last_reason = "planned"
		return true
	return false

func _set_transform(query: PhysicsShapeQueryParameters3D, actor: CharacterBody3D, collision: CollisionShape3D, at: Vector3) -> void:
	query.transform = Transform3D(actor.global_basis, at) * collision.transform

func _clear_motion(space: PhysicsDirectSpaceState3D, query: PhysicsShapeQueryParameters3D, actor: CharacterBody3D, collision: CollisionShape3D, from: Vector3, to: Vector3) -> bool:
	_set_transform(query, actor, collision, from)
	query.motion = to - from
	var fractions := space.cast_motion(query)
	if fractions.size() < 2 or fractions[0] < .999: return false
	_set_transform(query, actor, collision, to)
	query.motion = Vector3.ZERO
	return space.intersect_shape(query, 1).is_empty()

func _supported(space: PhysicsDirectSpaceState3D, actor: CharacterBody3D, at: Vector3, forward: Vector3) -> bool:
	var side := Vector3(-forward.z, 0, forward.x)
	# Start above all five points of a walkable slope, not below its uphill
	# sample. Otherwise the ray origin silently defeats floor_max_angle.
	var probe_up := .16 * tan(deg_to_rad(_slope)) + .12
	for offset in [Vector3.ZERO, side * .16, -side * .16, forward * .12, -forward * .12]:
		var start: Vector3 = at + offset + Vector3.UP * probe_up
		var ray := PhysicsRayQueryParameters3D.create(start, start + Vector3.DOWN * (probe_up + .45), actor.collision_mask, [actor.get_rid()])
		var hit := space.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y < cos(deg_to_rad(_slope)): return false
	return true
