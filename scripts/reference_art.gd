extends RefCounted
## Authoring helpers. Imported geometry remains linked to the original assets.
const PROP = preload("res://shaders/reference_prop.gdshader")

static func material(color: Color, moss := 0.0) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = PROP
	mat.set_shader_parameter("base_color", color)
	mat.set_shader_parameter("moss", moss)
	return mat

static func meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(meshes(child))
	return out

static func bake_import_transform(part: MeshInstance3D) -> void:
	# These GLBs store centimetre-sized vertices behind a 100x node transform.
	# Keep a full-detail, metre-sized mesh for both the visible and shadow passes.
	if part.transform.is_equal_approx(Transform3D.IDENTITY): return
	var source := part.mesh
	var xf := part.transform
	var normal_basis := xf.basis.inverse().transposed()
	var baked := ArrayMesh.new()
	var overrides: Array[Material] = []
	for surface in range(source.get_surface_count()):
		overrides.append(part.get_surface_override_material(surface))
		var arrays := source.surface_get_arrays(surface)
		for i in range(arrays[Mesh.ARRAY_VERTEX].size()):
			arrays[Mesh.ARRAY_VERTEX][i] = xf*arrays[Mesh.ARRAY_VERTEX][i]
			arrays[Mesh.ARRAY_NORMAL][i] = (normal_basis*arrays[Mesh.ARRAY_NORMAL][i]).normalized()
		if arrays[Mesh.ARRAY_TANGENT] != null:
			for i in range(0,arrays[Mesh.ARRAY_TANGENT].size(),4):
				var t := (xf.basis*Vector3(arrays[2][i],arrays[2][i+1],arrays[2][i+2])).normalized()
				arrays[2][i]=t.x
				arrays[2][i+1]=t.y
				arrays[2][i+2]=t.z
		baked.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		baked.surface_set_material(surface,source.surface_get_material(surface))
	part.mesh=baked
	# Children (including collision bodies) must retain their previous position.
	for child in part.get_children():
		if child is Node3D: child.transform=xf*child.transform
	part.transform=Transform3D.IDENTITY
	for i in range(overrides.size()):
		part.set_surface_override_material(i,overrides[i])
	part.set_meta("normalized_import_transform",true)

static func model(parent: Node3D, file: String, at: Vector3, height: float, yaw := 0.0, color := Color("b6bab0"), solid := false) -> Node3D:
	var source: Node3D = load(file).instantiate()
	var root := Node3D.new()
	root.name = file.get_file().get_basename()
	parent.add_child(root)
	var bounds := AABB()
	var first := true
	# Read authored transforms without depending on a running scene tree.
	var copied: Array[MeshInstance3D] = []
	for part in meshes(source):
		var transform := part.transform
		var ancestor := part.get_parent()
		while ancestor is Node3D and ancestor != source:
			transform = ancestor.transform * transform
			ancestor = ancestor.get_parent()
		var copy := MeshInstance3D.new()
		copy.name = part.name
		copy.mesh = part.mesh
		copy.transform = transform
		root.add_child(copy)
		copied.append(copy)
		var b: AABB = transform * part.get_aabb()
		bounds = b if first else bounds.merge(b)
		first = false
	var factor := height / maxf(bounds.size.y, 0.01)
	for part in copied:
		part.position.y -= bounds.position.y
		for surface in range(part.mesh.get_surface_count()):
			var original := part.mesh.surface_get_material(surface) as StandardMaterial3D
			var label := original.resource_name.to_lower() if original else ""
			var leafy := "leav" in label or "bush" in label or "fern" in label or "flower" in label
			var bark := "bark" in label or "trunk" in label
			var tint := Color("76a85d") if leafy else (Color("8a8572") if bark else color)
			if "flower" in file.to_lower():
				tint = Color("c7d9aa") if "petal" in label or "flower" in label else Color("648454")
			var mat := material(tint, 0.0 if leafy or bark else 0.20)
			mat.set_shader_parameter("foliage", leafy)
			mat.set_shader_parameter("crown_height", bounds.size.y * 0.65)
			if leafy and original and original.albedo_texture:
				mat.set_shader_parameter("source_texture", original.albedo_texture)
				mat.set_shader_parameter("use_texture", true)
			part.set_surface_override_material(surface, mat)
		if solid:
			part.create_trimesh_collision()
	root.position = at
	root.scale = Vector3.ONE * factor
	root.rotation.y = yaw
	source.free()
	return root

static func block(parent: Node3D, at: Vector3, size: Vector3, mat: Material, solid := true) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = mat
	node.position = at
	parent.add_child(node)
	if solid:
		var body := StaticBody3D.new()
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		collision.shape = shape
		body.add_child(collision)
		node.add_child(body)
	return node

static func village_model(parent: Node3D, file: String, at: Vector3, height: float, yaw := 0.0, roof := Color("4d8180")) -> Node3D:
	var node := model(parent,"res://assets/village/"+file+".glb",at,height,yaw)
	var palette := {"Wood":Color("826043"),"Wood_Side":Color("b49569"),"Wood_Light":Color("a38259"),"Plaster":Color("dccba5"),"Beige":Color("dfcfa8"),"Windows":Color("354b53"),"Stone_Light":Color("acb5a6"),"Stone_Dark":Color("81918a"),"Stone":Color("6c807c"),"RoofTiles":roof,"RoofTiles_Red":roof,"Bell":Color("c0a05e")}
	var bounds := AABB()
	var first := true
	for part in meshes(node):
		var b := part.transform*part.get_aabb()
		bounds=b if first else bounds.merge(b)
		first=false
		for surface in range(part.mesh.get_surface_count()):
			var original := part.mesh.surface_get_material(surface) as StandardMaterial3D
			var label := original.resource_name if original else ""
			var color: Color=palette.get(label,original.albedo_color if original else Color("a4a184"))
			var mat := material(color,.035 if "Stone" in label else 0.0)
			if "RoofTiles" in label:
				mat.set_shader_parameter("roof_tiles",true)
				mat.set_shader_parameter("roof_axis",Vector2(cos(yaw),-sin(yaw)))
			part.set_surface_override_material(surface,mat)
	for part in node.get_children():
		part.position-=Vector3(bounds.get_center().x,0,bounds.get_center().z)
		if part is MeshInstance3D: bake_import_transform(part)
	# A simple building footprint keeps the path clear of decorative roof overhangs.
	if file in ["House_1","House_2","House_3","Inn","Blacksmith","Bell_Tower","Well"]:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size=Vector3(bounds.size.x*.76,bounds.size.y*.6,bounds.size.z*.72)
		shape.shape=box
		shape.position.y=box.size.y*.5
		body.add_child(shape)
		node.add_child(body)
	return node

static func cylinder(parent: Node3D, at: Vector3, radius: float, height: float, mat: Material, solid := true) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 32
	node.mesh = mesh
	node.material_override = mat
	node.position = at
	parent.add_child(node)
	if solid:
		node.create_trimesh_collision()
	return node

static func annulus(parent: Node3D, center: Vector3, radius: float, width: float, height: float, mat: Material, segments := 32) -> Node3D:
	var group := Node3D.new()
	group.name = "MasonryRing"
	parent.add_child(group)
	group.position = center
	for i in range(segments):
		var a := float(i) * TAU / segments
		var pos := Vector3(sin(a) * radius, 0, cos(a) * radius)
		var stone := block(group, pos, Vector3(TAU * radius / segments * 0.98, height, width), mat)
		stone.rotation.y = a
	return group
