extends RefCounted
## Visual picking, separate from movement collision (signs and ladder rungs
## deliberately have much smaller/no physical bodies). Coordinates use the same
## pixel viewport and camera snap conversion as aiming and the anchored labels.

static func pointed_at(game: Node, pointer: Vector2) -> Node3D:
	var actor: Node3D=game.controlled_actor()
	var camera: Camera3D=game.camera
	var pixel: Vector2=game.screen_to_viewport(pointer)
	var origin:=camera.project_ray_origin(pixel)
	var direction:=camera.project_ray_normal(pixel)
	var closest:=camera.far
	var result: Node3D
	for prop: Node3D in game.get_tree().get_nodes_in_group("interactables"):
		if not game.interactions.within_reach(prop,actor): continue
		var distance:=_visual_distance(prop,origin,direction)
		if distance>=0 and distance<closest:
			closest=distance
			result=prop
	if not is_instance_valid(result): return null
	# Do not select through walls, terrain, or another actor. The target's own
	# movement collider may be larger than its visible mesh and is still a hit.
	var query:=PhysicsRayQueryParameters3D.create(origin,origin+direction*(closest+.02),1|2|4)
	var hit:=actor.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var collider: Node=hit.collider
		if collider!=result and not result.is_ancestor_of(collider): return null
	return result

static func _visual_distance(prop: Node3D, origin: Vector3, direction: Vector3) -> float:
	if prop.has_method("interaction_hover_bounds"):
		return _bounds_distance(prop,prop.interaction_hover_bounds(),origin,direction)
	var closest:=INF
	for child: Node in prop.find_children("*","MeshInstance3D",true,false):
		var mesh:=child as MeshInstance3D
		if mesh.mesh==null or not mesh.is_visible_in_tree(): continue
		var distance:=_bounds_distance(mesh,mesh.get_aabb().grow(.025),origin,direction)
		if distance>=0: closest=minf(closest,distance)
	return closest

static func _bounds_distance(node: Node3D, bounds: AABB, origin: Vector3, direction: Vector3) -> float:
	var inverse:=node.global_transform.affine_inverse()
	var hit: Variant=bounds.intersects_ray(inverse*origin,inverse.basis*direction)
	if hit==null: return INF
	return (node.global_transform*Vector3(hit)-origin).dot(direction)
