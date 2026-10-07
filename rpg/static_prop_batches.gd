extends RefCounted
## Runtime-only batches for the authored map's static masonry/wood shader.
## Keep the original nodes and physics bodies for paths, ownership and collision.
const PROP_SHADER = preload("res://shaders/reference_prop.gdshader")
const CELL_SIZE := 16.0

static func build(map: Node3D) -> Dictionary:
	var groups: Dictionary = {}
	var inverse := map.global_transform.affine_inverse()
	for node: Node in map.find_children("*", "MeshInstance3D", true, false):
		var source := node as MeshInstance3D
		if not _eligible(source, map): continue
		var transform: Transform3D = inverse * source.global_transform
		var cell := Vector2i(floori(transform.origin.x / CELL_SIZE), floori(transform.origin.z / CELL_SIZE))
		var material := source.get_active_material(0)
		var key: Array = [cell, material.get_instance_id(), source.layers, source.cast_shadow, source.gi_mode]
		if not groups.has(key): groups[key] = []
		groups[key].append({"source":source, "transform":transform})
	var container := Node3D.new()
	container.name = "StaticPropBatches"
	map.add_child(container)
	var count := 0
	for group: Array in groups.values():
		if group.size() < 4: continue
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		var margin := 0.0
		for entry: Dictionary in group:
			surface.append_from(entry.source.mesh, 0, entry.transform)
			margin = maxf(margin, entry.source.extra_cull_margin)
		var mesh := surface.commit()
		if mesh == null: continue
		var first: MeshInstance3D = group[0].source
		mesh.surface_set_material(0, first.get_active_material(0))
		var batch := MeshInstance3D.new()
		batch.name = "Batch%d" % container.get_child_count()
		batch.mesh = mesh
		batch.layers = first.layers
		batch.cast_shadow = first.cast_shadow
		batch.gi_mode = first.gi_mode
		batch.extra_cull_margin = margin
		container.add_child(batch)
		for entry: Dictionary in group:
			entry.source.hide()
			count += 1
	return {"source_meshes":count, "batches":container.get_child_count()}

static func _eligible(source: MeshInstance3D, map: Node3D) -> bool:
	if source.mesh == null or source.mesh.get_surface_count() != 1 or not source.is_visible_in_tree(): return false
	if source.mesh is ArrayMesh:
		if source.mesh.surface_get_primitive_type(0) != Mesh.PRIMITIVE_TRIANGLES: return false
	elif not source.mesh is PrimitiveMesh or source.mesh is PointMesh: return false
	if source.skin != null or source.material_overlay != null or source.transparency > 0: return false
	if source.mesh is ArrayMesh and source.mesh.get_blend_shape_count() > 0: return false
	if source.visibility_range_begin > 0 or source.visibility_range_end > 0: return false
	if source.global_basis.determinant() <= 0: return false
	var scale := source.global_basis.get_scale()
	if not is_equal_approx(scale.x, scale.y) or not is_equal_approx(scale.y, scale.z): return false
	var ancestor: Node = source
	while ancestor != map:
		if ancestor.get_script() != null or ancestor.is_in_group("interactables") or ancestor.has_meta("tree_seed") or ancestor.has_node("ClusteredLeaves"): return false
		ancestor = ancestor.get_parent()
	var material := source.get_active_material(0) as ShaderMaterial
	if material == null or material.shader != PROP_SHADER or material.next_pass != null: return false
	# Roof tile coordinates and foliage normals depend on the original model's
	# local origin. They deliberately retain their original draw calls.
	return not material.get_shader_parameter("roof_tiles") and not material.get_shader_parameter("foliage")
