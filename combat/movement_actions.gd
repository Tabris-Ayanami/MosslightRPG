extends Node
## Shared movement selection, swept jumps and physical crouching for every unit.
## Selection snapshots the landing only on confirmation; movement never teleports.
const Preferences = preload("res://rpg/game_preferences.gd")
const DISTANCE_PER_PIP := 2.0
const CROUCH_SPEED := .50
const SKIN := .022
const MAX_DROP := 6.0
var actor: CharacterBody3D
var indicator: Node3D
var selection := ""
var mode := Preferences.CAST_QUICK
var source := "key"
var preview: Dictionary = {}
var invalid_reason := ""
var crouching := false
var crouch_blend := 0.0
var airborne := false
var flight_progress := 0.0
var jumps_started := 0
var last_jump: Dictionary = {}
var last_reason := ""
var _flight: Dictionary = {}
var _standing_height := 0.0
var _standing_radius := 0.0
var _last_position := Vector3.ZERO
var _plan_key := ""
var _plan: Dictionary = {}
var _grounding_required := false

func setup(owner_actor: CharacterBody3D) -> void:
	actor = owner_actor
	indicator = preload("res://combat/jump_indicator.gd").new()
	indicator.actor = actor
	actor.add_child(indicator)
	indicator.hide()

func active() -> bool:
	return not selection.is_empty()

func available_pips() -> int:
	var value: float = actor.resources.max_value("Stamina") if actor.resources.unlimited.get("Stamina", false) else actor.resources.current("Stamina")
	return maxi(0, floori(value + .00001))

func radius_for_cost(cost: int) -> float:
	return DISTANCE_PER_PIP * (maxi(0, cost) + 1)

func maximum_range() -> float:
	return radius_for_cost(available_pips())

func cost_for_distance(distance: float) -> int:
	return maxi(0, ceili(maxf(0, distance - .0001) / DISTANCE_PER_PIP) - 1)

func press(kind: String, origin := "key") -> bool:
	if kind not in ["jump", "crouch"] or not actor.is_human_controlled(): return false
	if selection == kind and mode == Preferences.CAST_PRECISE: return confirm()
	var failure := _start_failure()
	if not failure.is_empty(): return actor.combat.fail(failure)
	actor.input_router.cancel_pointer()
	selection = kind
	source = origin
	mode = Preferences.get_cast_mode("move_" + kind)
	# Clicking a jump icon needs a subsequent world click to choose a landing.
	if origin == "hud" and kind == "jump": mode = Preferences.CAST_PRECISE
	_plan_key = ""
	update_selection()
	if origin == "hud" and kind == "crouch" and mode == Preferences.CAST_QUICK: return confirm()
	return true

func release(kind: String) -> void:
	if selection == kind and source == "key" and mode == Preferences.CAST_QUICK: confirm()

func cancel() -> void:
	selection = ""
	preview.clear()
	invalid_reason = ""
	_plan_key = ""
	if is_instance_valid(indicator): indicator.hide()

func confirm() -> bool:
	if not active(): return false
	# Do not trust a cached path: terrain, stamina and headroom can change.
	_plan_key = ""
	update_selection()
	if not invalid_reason.is_empty():
		var reason := invalid_reason
		if mode == Preferences.CAST_QUICK: cancel()
		return actor.combat.fail(reason)
	if selection == "crouch":
		cancel()
		return toggle_crouch()
	var chosen: Dictionary = preview.plan.duplicate(true)
	cancel()
	if not stand_for_action(): return false
	if not actor.resources.pay({"Stamina": chosen.cost}): return actor.combat.fail("体力不足，无法跳到该落点")
	actor.input_router.cancel()
	actor.surface_traversal.clear()
	actor.combat.stamina_clock = 0.0
	actor.combat.state = "JUMP"
	actor.velocity = Vector3.ZERO
	_grounding_required = true
	var direction: Vector3 = chosen.to - chosen.from
	direction.y = 0
	if direction.length_squared() > .001: actor.facing = direction.normalized()
	_flight = chosen
	flight_progress = 0.0
	_last_position = actor.global_position
	airborne = true
	jumps_started += 1
	last_jump = chosen.duplicate(true)
	last_reason = "takeoff"
	actor.arena.sound.play_tone("jump")
	return true

func _start_failure() -> String:
	if actor.control_input_blocked(): return "当前无法使用移动动作"
	if not actor.combat.can_start() or airborne: return "请等待当前动作结束"
	if not actor.swimming and not actor.wading:
		var grounded := actor.is_on_floor()
		if _grounding_required:
			var support := KinematicCollision3D.new()
			grounded = actor.test_move(actor.global_transform, Vector3.DOWN * .10, support) and support.get_normal().y >= cos(deg_to_rad(actor.surface_traversal.WALK_SLOPE))
		if not grounded: return "需要站稳后再使用移动动作"
	return ""

func _physics_process(_delta: float) -> void:
	if not active(): return
	if not actor.is_human_controlled() or not _start_failure().is_empty():
		cancel()
		return
	update_selection()

func update_selection() -> void:
	if not active(): return
	invalid_reason = _start_failure()
	var origin := actor.global_position
	if selection == "crouch":
		if crouching and not can_stand(): invalid_reason = "上方空间不足，无法站起"
		preview = {"kind": "crouch", "origin": origin, "point": origin, "valid": invalid_reason.is_empty(), "cost": 0, "pips": 0, "step": DISTANCE_PER_PIP}
	else:
		if crouching and not can_stand(): invalid_reason = "上方空间不足，无法站起跳跃"
		var aim := _pointer_ground()
		var offset := Vector3(aim.x - origin.x, 0, aim.z - origin.z).limit_length(maximum_range())
		var point := origin + offset
		var cost := cost_for_distance(offset.length())
		var key := str([origin.snapped(Vector3.ONE * .01), point.snapped(Vector3.ONE * .01), cost, _standing_height, crouching])
		if key != _plan_key:
			_plan_key = key
			_plan = plan_jump(point)
		if invalid_reason.is_empty(): invalid_reason = str(_plan.get("reason", ""))
		if actor.arena.pointer_blocked: invalid_reason = "请将落点移到场景中"
		point = _plan.get("to", point)
		preview = {"kind": "jump", "origin": origin, "point": point, "valid": invalid_reason.is_empty(), "cost": cost, "pips": available_pips(), "step": DISTANCE_PER_PIP, "plan": _plan}
	indicator.show_preview(preview)

func _pointer_ground() -> Vector3:
	return actor.arena.refresh_aim()

func _standing_shape() -> CapsuleShape3D:
	var collider: CollisionShape3D = actor.get_node("CollisionShape3D")
	var capsule := collider.shape as CapsuleShape3D
	if _standing_height <= 0:
		_standing_height = capsule.height
		_standing_radius = capsule.radius
	var shape := CapsuleShape3D.new()
	shape.height = _standing_height
	shape.radius = _standing_radius
	return shape

func _body_query(at: Vector3) -> PhysicsShapeQueryParameters3D:
	var shape := _standing_shape()
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = actor.collision_mask
	query.exclude = [actor.get_rid()]
	query.margin = .001
	query.transform = Transform3D(actor.global_basis, at + Vector3.UP * shape.height * .5)
	return query

func can_stand() -> bool:
	if not crouching: return true
	return actor.get_world_3d().direct_space_state.intersect_shape(_body_query(actor.global_position + Vector3.UP * SKIN), 1).is_empty()

func stand_for_action() -> bool:
	if not crouching: return true
	if not can_stand(): return actor.combat.fail("上方空间不足，无法站起")
	_set_crouching(false)
	return true

func toggle_crouch() -> bool:
	var reason := _start_failure()
	if not reason.is_empty(): return actor.combat.fail(reason)
	if crouching and not can_stand(): return actor.combat.fail("上方空间不足，无法站起")
	_set_crouching(not crouching)
	return true

func _set_crouching(value: bool) -> void:
	var standing := _standing_shape()
	crouching = value
	var collider: CollisionShape3D = actor.get_node("CollisionShape3D")
	var capsule := CapsuleShape3D.new()
	capsule.radius = standing.radius
	capsule.height = maxf(standing.radius * 2 + .03, standing.height * .58) if value else standing.height
	collider.shape = capsule
	collider.position.y = capsule.height * .5

func speed_multiplier() -> float:
	return CROUCH_SPEED if crouching else 1.0

func tick_pose(delta: float) -> void:
	# Combat starts by standing up; control reactions also release a crouch.
	if crouching and actor.combat.state not in ["NORMAL", "MOVE"]: _set_crouching(false)
	crouch_blend = move_toward(crouch_blend, 1.0 if crouching else 0.0, delta * 7.0)
	actor.animation.crouch_blend = crouch_blend if actor.combat.state in ["NORMAL", "MOVE"] else 0.0

func plan_jump(point: Vector3) -> Dictionary:
	var origin := actor.global_position
	var distance := Vector2(point.x - origin.x, point.z - origin.z).length()
	var cost := cost_for_distance(distance)
	var result := {"from": origin, "to": point, "cost": cost, "reason": ""}
	if distance < .25:
		result.reason = "落点距离太近"
		return result
	if cost > available_pips():
		result.reason = "体力不足，落点超出跳跃范围"
		return result
	var rise_limit := 1.0 + cost * .7
	var space := actor.get_world_3d().direct_space_state
	var ray_start := Vector3(point.x, origin.y + rise_limit + .2, point.z)
	var ray := PhysicsRayQueryParameters3D.create(ray_start, ray_start + Vector3.DOWN * (rise_limit + MAX_DROP + .2), actor.collision_mask, [actor.get_rid()])
	var hit := space.intersect_ray(ray)
	if hit.is_empty():
		result.reason = "该位置没有可落脚的地面"
		return result
	var landing: Vector3 = hit.position + Vector3.UP * SKIN
	result.to = landing
	if landing.y - origin.y > rise_limit + SKIN or hit.normal.y < cos(deg_to_rad(actor.surface_traversal.WALK_SLOPE)):
		result.reason = "落点过高或坡面太陡"
		return result
	var water_landing := false
	if is_instance_valid(actor.arena.host) and actor.arena.host.has_method("water_surface_at"):
		var water: float = actor.arena.host.water_surface_at(landing)
		if is_finite(water) and water - .70 > landing.y:
			landing.y = water - .70
			water_landing = true
	result.to = landing
	var query := _body_query(landing)
	if not water_landing:
		# A foot ray alone embeds a capsule in a slope. Resolve the actual body
		# resting height with a vertical sweep, exactly as physics would land it.
		var lift := _standing_radius * (1.0 / cos(deg_to_rad(actor.surface_traversal.WALK_SLOPE)) - 1.0) + .10
		var raised := 0.0
		# Start at the lowest clear body position. A flat landing underneath a
		# beam must not require the spare headroom of the maximum slope lift.
		while not space.intersect_shape(query, 1).is_empty() and raised < lift:
			var increment := minf(.04, lift - raised)
			raised += increment
			query.transform.origin += Vector3.UP * increment
		if not space.intersect_shape(query, 1).is_empty():
			result.reason = "落点没有容纳角色的空间"
			return result
		query.motion = Vector3.DOWN * (raised + .12)
		var support := space.cast_motion(query)
		if support.size() < 2 or support[0] >= .999:
			result.reason = "落点缺少支撑"
			return result
		landing += Vector3.UP * raised + query.motion * support[0] + Vector3.UP * SKIN
		result.to = landing
		if landing.y - origin.y > rise_limit + SKIN:
			result.reason = "落点过高"
			return result
		query = _body_query(landing)
	if not space.intersect_shape(query, 1).is_empty():
		result.reason = "落点没有容纳角色的空间"
		return result
	# Require support under the footprint, rather than balancing a whole capsule
	# on the centre of a stair/roof edge. Water uses the shared buoyancy surface.
	if not water_landing:
		var probe_up := _standing_radius * .65 * tan(deg_to_rad(actor.surface_traversal.WALK_SLOPE)) + .15
		var probe_depth := probe_up + _standing_radius * (1.0 / cos(deg_to_rad(actor.surface_traversal.WALK_SLOPE)) - 1.0) + .45
		for offset in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
			var probe: Vector3 = landing + offset * _standing_radius * .65 + Vector3.UP * probe_up
			var support := space.intersect_ray(PhysicsRayQueryParameters3D.create(probe, probe + Vector3.DOWN * probe_depth, actor.collision_mask, [actor.get_rid()]))
			if support.is_empty() or support.normal.y < cos(deg_to_rad(actor.surface_traversal.WALK_SLOPE)):
				result.reason = "落点位于不可站立的边缘"
				return result
	result["height"] = .65 + distance * .16
	result["duration"] = clampf(.50 + distance * .045, .50, 1.10)
	var previous := origin + Vector3.UP * .012
	var segments := maxi(24, ceili((distance + absf(landing.y - origin.y)) / .20))
	for i in range(1, segments + 1):
		var next := _arc_point(result, float(i) / segments)
		query.transform.origin = previous + Vector3.UP * _standing_height * .5
		query.motion = next - previous
		var fractions := space.cast_motion(query)
		if fractions.size() < 2 or fractions[0] < .999:
			result.reason = "跳跃轨迹被障碍物挡住"
			return result
		previous = next
	return result

func _arc_point(plan: Dictionary, progress: float) -> Vector3:
	return plan.from.lerp(plan.to, progress) + Vector3.UP * float(plan.height) * 4.0 * progress * (1.0 - progress)

func advance_jump(delta: float) -> bool:
	if not airborne: return false
	# Hits, grabs, death, possession changes and external relocation release the
	# path immediately. Keep the controller's knockback/launch velocity intact.
	if actor.combat.state != "JUMP" or actor.global_position.distance_to(_last_position) > .10:
		airborne = false
		if actor.combat.state == "JUMP": actor.combat.state = "NORMAL"
		last_reason = "interrupted"
		return false
	flight_progress = minf(1.0, flight_progress + delta / float(_flight.duration))
	var before := actor.global_position
	var desired := _arc_point(_flight, flight_progress)
	var collision: KinematicCollision3D = actor.move_and_collide(desired - before)
	_last_position = actor.global_position
	actor.velocity = (actor.global_position - before) / maxf(.00001, delta)
	if collision != null or flight_progress >= 1.0:
		airborne = false
		actor.combat.state = "NORMAL"
		actor.velocity = Vector3.ZERO
		last_reason = "landed" if collision == null or collision.get_normal().y > .5 and actor.global_position.distance_to(_flight.to) < .12 else "path_blocked"
	actor.animation.play_locomotion(false)
	actor.animation.update_pose(delta, actor.facing, "JUMP", "NONE", flight_progress)
	actor.combat.sync_precision_glow()
	return true

func reset() -> void:
	cancel()
	if crouching: _set_crouching(false)
	crouch_blend = 0.0
	if airborne and actor.combat.state == "JUMP":
		actor.combat.state = "NORMAL"
		actor.velocity = Vector3.ZERO
	airborne = false
	flight_progress = 0.0
	_standing_height = 0.0
	_standing_radius = 0.0
	_flight.clear()
	_grounding_required = false

func _exit_tree() -> void:
	if is_instance_valid(indicator): indicator.queue_free()
