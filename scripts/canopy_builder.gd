extends RefCounted
## Authoring-only: replace leaf cards with instanced leaf clusters around each branch.
const SHADER = preload("res://shaders/reference_canopy.gdshader")

static func rebuild(tree: Node3D, random_seed: int) -> void:
	var points: Array[Vector3] = []
	var factor := tree.scale.x
	for part in tree.get_children():
		if not part is MeshInstance3D:
			continue
		var trunk := ArrayMesh.new()
		for s in range(part.mesh.get_surface_count()):
			var mat := part.get_active_material(s) as ShaderMaterial
			var arrays: Array = part.mesh.surface_get_arrays(s)
			if mat and mat.get_shader_parameter("foliage") == true:
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for v in range(0, verts.size(), 3):
					points.append(part.transform * verts[v])
			else:
				trunk.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				if mat:
					mat = mat.duplicate()
					mat.set_shader_parameter("base_color", Color("796345"))
				trunk.surface_set_material(trunk.get_surface_count()-1, mat)
		part.mesh = trunk
		for s in range(trunk.get_surface_count()):
			part.set_surface_override_material(s, null)
	if points.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	# Farthest-point seeds followed by k-means keep the clumps attached to existing branches.
	var centers: Array[Vector3] = [points[points.size()/2]]
	for i in range(7):
		var far := 0.0
		var next := points[0]
		for p in points:
			var nearest := INF
			for center in centers:
				nearest = minf(nearest, p.distance_squared_to(center))
			if nearest > far:
				far = nearest
				next = p
		centers.append(next)
	var groups: Array = []
	for iteration in range(8):
		groups.clear()
		for center in centers:
			groups.append([])
		for p in points:
			var nearest := INF
			var best := 0
			for i in range(centers.size()):
				var distance := p.distance_squared_to(centers[i])
				if distance < nearest:
					nearest = distance
					best = i
			groups[best].append(p)
		for i in range(centers.size()):
			if groups[i].is_empty():
				continue
			var sum := Vector3.ZERO
			for p: Vector3 in groups[i]:
				sum += p
			centers[i] = sum / groups[i].size()
	var positions: Array[Vector3] = []
	var normals: Array[Vector3] = []
	for i in range(centers.size()):
		if groups[i].is_empty():
			continue
		var variance := Vector3.ZERO
		for p: Vector3 in groups[i]:
			var offset := p - centers[i]
			variance += offset * offset
		variance /= groups[i].size()
		var radius := Vector3(sqrt(variance.x)*1.9, sqrt(variance.y)*1.55, sqrt(variance.z)*1.9)
		radius = radius.max(Vector3(.42,.38,.42) / factor)
		var count := clampi(int(radius.x*radius.z*factor*factor*170), 95, 360)
		for j in range(count):
			var direction := Vector3(rng.randfn(),rng.randfn(),rng.randfn()).normalized()
			var pos := centers[i] + direction*radius*rng.randf_range(.55,1.0)
			positions.append(pos)
			normals.append((direction*Vector3(1,.8,1)+Vector3.UP*.35).normalized())
	var leaves := MultiMeshInstance3D.new()
	leaves.name = "ClusteredLeaves"
	leaves.multimesh = MultiMesh.new()
	leaves.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	leaves.multimesh.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	quad.material = mat
	leaves.multimesh.mesh = quad
	leaves.multimesh.instance_count = positions.size()
	for i in range(positions.size()):
		var size := rng.randf_range(.45,.72) / factor
		leaves.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*size), positions[i]))
		var n: Vector3 = normals[i]*.5+Vector3.ONE*.5
		leaves.multimesh.set_instance_custom_data(i,Color(n.x,n.y,n.z,rng.randf()))
	leaves.extra_cull_margin = .3
	tree.add_child(leaves)
	print("CANOPY ", tree.name, " leaf clusters=", positions.size())
