extends Node
## Auditory footprints follow the visible meshes, independently of walkable collision.
const QUERY_LAYER := 1 << 10
const SURFACE_META := &"footstep_surface"
var map: Node3D
var lake: MeshInstance3D
var query_body_count := 0

func setup(reference_map: Node3D) -> void:
	map = reference_map
	lake = map.get_node("Lake")
	var shrine := map.get_node("WaterShrine")
	shrine.set_meta(SURFACE_META, &"stone")
	map.get_node("ShoreRocks").set_meta(SURFACE_META, &"stone")
	_mark_rocks(map)
	_add_mesh_footprints(shrine, &"stone")
	var connections := map.get_node("RegionConnections")
	for child in connections.get_children():
		if child is MeshInstance3D:
			_add_footprint(child, &"dirt")
		elif child.name in [&"EastWoodenBridge", &"NorthVillageBridge"]:
			child.set_meta(SURFACE_META, &"wood")
	_add_mesh_footprints(map.get_node("NorthernVillage/DoorstepLanes"), &"dirt")
	# Only the plaza's direct meshes are paving; the nested stalls/well are props.
	for child in map.get_node("NorthernVillage/MarketSquare").get_children():
		if child is MeshInstance3D:
			_add_footprint(child, StringName(child.get_meta(SURFACE_META, &"stone")))
	if map.has_node("RoadFlagstones"):
		_add_mesh_footprints(map.get_node("RoadFlagstones"), &"stone")

func _mark_rocks(node: Node) -> void:
	if String(node.name).begins_with("Rock") or String(node.name).begins_with("Column"):
		node.set_meta(SURFACE_META, &"stone")
	for child in node.get_children():
		_mark_rocks(child)

func _add_mesh_footprints(node: Node, surface: StringName) -> void:
	# Snapshot children before adding the query body, so recursion cannot include it.
	for child in node.get_children():
		_add_mesh_footprints(child, surface)
	if node is MeshInstance3D:
		_add_footprint(node, surface)

func _add_footprint(mesh_instance: MeshInstance3D, surface: StringName) -> void:
	mesh_instance.set_meta(SURFACE_META, surface)
	for child in mesh_instance.get_children():
		if child is StaticBody3D:
			return
	if mesh_instance.mesh == null:
		return
	var shape := mesh_instance.mesh.create_trimesh_shape()
	if shape == null:
		return
	# Back faces allow a thin paving layer slightly above the physical ground.
	shape.backface_collision = true
	var body := StaticBody3D.new()
	body.name = "AudioFootprint"
	body.collision_layer = QUERY_LAYER
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	mesh_instance.add_child(body)
	query_body_count += 1

func surface_at(feet: Vector3) -> StringName:
	var space := map.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(feet + Vector3.UP * .36, feet - Vector3.UP * .5, 1)
	var physical_hit := space.intersect_ray(query)
	# The water plane also extends below bridges; only a submerged contact splashes.
	# Thin decorative stair treads must not conceal the actual submerged floor.
	if not physical_hit.is_empty() and _inside_water(physical_hit.position) and physical_hit.position.y < lake.global_position.y - .025 and feet.y < lake.global_position.y - .015:
		return &"water"
	query.collision_mask |= QUERY_LAYER
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return &"grass"
	var surface := _surface_of(hit.collider)
	return surface if not surface.is_empty() else &"grass"

func _surface_of(node: Node) -> StringName:
	while node != null and node != map:
		if node.has_meta(SURFACE_META):
			return StringName(node.get_meta(SURFACE_META))
		node = node.get_parent()
	return &""

func _inside_water(at: Vector3) -> bool:
	var p := lake.to_local(at)
	var half_size: Vector2 = lake.mesh.size * .5
	return absf(p.x) < half_size.x and absf(p.z) < half_size.y

func water_distance(feet: Vector3) -> float:
	# Low-frequency physical probes also follow sculpted shores and the excavated pool.
	# Camera zoom/orbit never changes this listener distance.
	for radius in [0.0, 2.0, 5.0, 9.0, 14.0]:
		for i in range(1 if radius == 0 else 12):
			var angle := TAU * i / 12.0
			var at: Vector3 = feet + Vector3(cos(angle), 0, sin(angle)) * radius
			if not _inside_water(at):
				continue
			var query := PhysicsRayQueryParameters3D.create(Vector3(at.x, 20, at.z), Vector3(at.x, -8, at.z), 1)
			var hit := map.get_world_3d().direct_space_state.intersect_ray(query)
			# A wooden deck can cover audible water. Ignore it and probe the bed.
			if not hit.is_empty() and _surface_of(hit.collider) == &"wood":
				query.exclude = [hit.rid]
				hit = map.get_world_3d().direct_space_state.intersect_ray(query)
			if not hit.is_empty() and hit.position.y < lake.global_position.y - .04:
				return radius
	return 24.0
