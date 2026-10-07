extends RefCounted
## Designer-authored entry points reuse the existing actor's walk-home intent.
## This is placement only: encounter generations and rewards stay in the service.
const Definition = preload("res://combat/unit_definition.gd")

static func choose(runtime: Node, definition: Dictionary, home: Vector3) -> Dictionary:
	var navigation: Node = runtime.host.world_navigation
	if not is_instance_valid(navigation) or not navigation.navigation_ready(): return {}
	var template: Dictionary = Definition.for_enemy(runtime.database, definition.enemy_id)
	if template.is_empty(): return {}
	for point: Array in definition.get("arrival_points", []):
		var at: Vector3 = runtime.host.reference_map.to_global(Vector3(point[0], point[1], point[2]))
		var support := _ground(runtime, at)
		if support.is_empty(): continue
		at = support.position
		if not runtime._safe_position(at, float(definition.safe_distance)): continue
		# The authored home is a navigation target, not another placement. Keep
		# it intact: its reachable stopping area can border a steep terrain face.
		if not navigation.is_reachable(at, home): continue
		if not _body_fits(runtime, at, template.body): continue
		return {"position": at, "home": home}
	return {}

static func _ground(runtime: Node, at: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 8, at - Vector3.UP * 16, 1)
	var hit: Dictionary = runtime.player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.normal.dot(Vector3.UP) < cos(deg_to_rad(45.0)): return {}
	var water: float = runtime.host.water_surface_at(hit.position)
	if is_finite(water) and water > float(hit.position.y) + .05: return {}
	return {"position": hit.position + Vector3.UP * .1}

static func _body_fits(runtime: Node, at: Vector3, body: Dictionary) -> bool:
	var capsule := CapsuleShape3D.new()
	capsule.radius = float(body.radius) * maxf(float(body.scale.x), float(body.scale.z))
	capsule.height = maxf(float(body.height) * float(body.scale.y), capsule.radius * 2)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * capsule.height * .5)
	query.collision_mask = 1 | 2 | 4
	query.margin = .01
	return runtime.player.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()
