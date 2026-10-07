extends RefCounted
class_name CombatTargeting
## Reach follows XZ on slopes, within a bounded vertical contact envelope.

static func shape_for(action: Dictionary) -> String:
	var shape: String = str(action.get("targeting", "CONE")).to_upper()
	return "POINT/LINE" if shape == "POINT" and action.get("shape", "CIRCLE") == "LINE" else shape

static func projectile_radius(action: Dictionary) -> float:
	return maxf(.01, float(action.get("projectile_radius", .6)))

static func contains(shape: String, origin: Vector3, direction: Vector3, point: Vector3, action: Dictionary, aim_point: Vector3) -> bool:
	var kind := shape.to_upper()
	if kind == "POINT" and action.get("shape", "CIRCLE") == "LINE": kind = "POINT/LINE"
	var centered_on_aim := kind in ["POINT", "POINT/CIRCLE", "TARGET", "POINT/LINE"] or bool(action.get("center_on_point", action.get("point_origin", false)))
	var height_center := aim_point.y if centered_on_aim else origin.y
	# Compare feet at the same relative body height. Remote ground spells use
	# their impact surface; a sword swung below a roof cannot hit through it.
	if absf(point.y - height_center) > maxf(0.0, float(action.get("vertical_reach", 1.25))) + .00001:
		return false
	var reach := maxf(0.0, float(action.get("length", action.get("range", 3.0)))) if kind == "POINT/LINE" else maxf(0.0, float(action.get("range", 3.0)))
	var radius := maxf(0.0, float(action.get("radius", reach)))
	var forward := _ground(direction)
	var offset := _ground(point - origin)
	match kind:
		"SELF", "CIRCLE", "SELF/CIRCLE":
			var center := aim_point if bool(action.get("center_on_point", false)) else origin
			return _ground(point - center).length_squared() <= radius * radius + 0.00001
		"POINT", "POINT/CIRCLE":
			return _ground(point - aim_point).length_squared() <= radius * radius + 0.00001
		"TARGET":
			var target_radius := maxf(0.0, float(action.get("target_radius", 0.65)))
			return _ground(point - aim_point).length_squared() <= target_radius * target_radius + 0.00001
		"CONE":
			if offset.length_squared() > reach * reach + 0.00001:
				return false
			if offset.is_zero_approx():
				return true
			if forward.is_zero_approx():
				return false
			var angle := clampf(float(action.get("angle_degrees", action.get("angle", 90.0))), 0.0, 360.0)
			return forward.normalized().dot(offset.normalized()) >= cos(deg_to_rad(angle * 0.5)) - 0.00001
		"DIRECTION", "LINE", "POINT/LINE":
			if forward.is_zero_approx():
				return false
			forward = forward.normalized()
			var half_width := maxf(0.0, float(action.get("width", 1.2))) * 0.5
			var at_point := kind == "POINT/LINE" or bool(action.get("center_on_point", action.get("point_origin", false)))
			if at_point:
				offset = _ground(point - aim_point)
			var along := offset.dot(forward)
			var lateral := offset - forward * along
			var inside_length := absf(along) <= reach * 0.5 + 0.00001 if at_point else along >= -0.00001 and along <= reach + 0.00001
			return inside_length and lateral.length_squared() <= half_width * half_width + 0.00001
	return false

static func is_behind(attacker_position: Vector3, target_position: Vector3, target_forward: Vector3) -> bool:
	var toward_attacker := _ground(attacker_position - target_position)
	var forward := _ground(target_forward)
	if toward_attacker.is_zero_approx() or forward.is_zero_approx():
		return false
	# The 120-degree rear sector is 60 degrees either side of the reverse facing.
	return toward_attacker.normalized().dot(forward.normalized()) <= -0.5 + 0.00001

static func _ground(value: Vector3) -> Vector3:
	return Vector3(value.x, 0.0, value.z)
