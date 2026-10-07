extends RefCounted
## Authoring helpers shared by the region builder and the saved-road migration.
const SOIL = preload("res://shaders/earth_path.gdshader")
const A = preload("res://scripts/reference_art.gd")

static func material(plaza := false, center := Vector2.ZERO) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SOIL
	mat.set_shader_parameter("ribbon", not plaza)
	if plaza:
		mat.set_shader_parameter("plaza_center", center)
	return mat

static func upgrade_ribbon(source: Mesh) -> ArrayMesh:
	# The old strip is unindexed: two triangles [L0,R1,L1, L0,R0,R1] per span.
	# Preserve every authored vertex; only fix winding and add cross/along UVs.
	var arrays := source.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert(vertices.size() % 6 == 0)
	var uv := PackedVector2Array()
	uv.resize(vertices.size())
	var indices := PackedInt32Array()
	var distance := 0.0
	var previous := Vector3.ZERO
	for i in range(0, vertices.size(), 6):
		var start := (vertices[i] + vertices[i + 4]) * .5
		var finish := (vertices[i + 2] + vertices[i + 1]) * .5
		if i > 0: distance += previous.distance_to(start)
		var next_distance := distance + start.distance_to(finish)
		uv[i] = Vector2(0, distance)
		uv[i + 1] = Vector2(1, next_distance)
		uv[i + 2] = Vector2(0, next_distance)
		uv[i + 3] = Vector2(0, distance)
		uv[i + 4] = Vector2(1, distance)
		uv[i + 5] = Vector2(1, next_distance)
		# Godot's upward front face is clockwise, like PlaneMesh.
		indices.append_array([i, i + 2, i + 1, i + 3, i + 5, i + 4])
		distance = next_distance
		previous = finish
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func flagstones() -> Node3D:
	var group := Node3D.new()
	group.name = "RoadFlagstones"
	group.set_meta(&"footstep_surface", &"stone")
	var rng := RandomNumberGenerator.new()
	rng.seed = 297031
	# Sparse slabs set into the entrance soil; their gaps remain walkable earth.
	for i in range(10):
		var z := -26.2 - i * .77
		_add_stone(group, rng, Vector2(rng.randf_range(-.50, .50), z), 2.25)
		if i % 3 == 1:
			_add_stone(group, rng, Vector2(.78 if i % 2 else -.78, z + .14), 2.25)
	# Walking lines through the market, with ample visible soil between stones.
	for i in range(12):
		var p := Vector2(.45 + sin(i * 1.3) * .38, -34.2 - i * .95)
		_add_stone(group, rng, p, 2.26)
	for i in range(10):
		var p := Vector2(-4.8 + i * 1.02, -39.0 + sin(i * 1.8) * .28)
		_add_stone(group, rng, p, 2.26)
	return group

static func grass_clearance(map: Node3D) -> ImageTexture:
	# A separate footprint layer preserves all editable terrain height/grass data.
	# Rasterize the actual saved meshes, so curves and future road edits match.
	var image := Image.create(1024, 1024, false, Image.FORMAT_R8)
	image.fill(Color.BLACK)
	var meshes: Array[MeshInstance3D] = []
	for group_path in ["RegionConnections", "NorthernVillage/DoorstepLanes"]:
		for child in map.get_node(group_path).get_children():
			if child is MeshInstance3D: meshes.append(child)
	meshes.append(map.get_node("NorthernVillage/MarketSquare").get_child(0))
	for node in meshes:
		var transform := node.transform
		var parent := node.get_parent()
		while parent is Node3D and parent != map:
			transform = parent.transform * transform
			parent = parent.get_parent()
		var faces := node.mesh.get_faces()
		for i in range(0, faces.size(), 3):
			var a := transform * faces[i]
			var b := transform * faces[i + 1]
			var c := transform * faces[i + 2]
			_paint_clearance(image, Vector2(a.x,a.z), Vector2(b.x,b.z), Vector2(c.x,c.z))
	return ImageTexture.create_from_image(image)

static func _paint_clearance(image: Image, a: Vector2, b: Vector2, c: Vector2) -> void:
	if absf((b-a).cross(c-a)) < .000001: return
	var origin := Vector2(-32,-96)
	var low := Vector2(minf(a.x,minf(b.x,c.x)),minf(a.y,minf(b.y,c.y))) - Vector2.ONE * .36
	var high := Vector2(maxf(a.x,maxf(b.x,c.x)),maxf(a.y,maxf(b.y,c.y))) + Vector2.ONE * .36
	var from := Vector2i(((low-origin)*8).floor()).clamp(Vector2i.ZERO, Vector2i(1023,1023))
	var to := Vector2i(((high-origin)*8).ceil()).clamp(Vector2i.ZERO, Vector2i(1023,1023))
	for y in range(from.y,to.y+1):
		for x in range(from.x,to.x+1):
			if image.get_pixel(x,y).r > .999: continue
			var p := origin + (Vector2(x,y)+Vector2.ONE*.5)/8
			var u := (b-a).cross(p-a)
			var v := (c-b).cross(p-b)
			var w := (a-c).cross(p-c)
			var inside := (u>=0 and v>=0 and w>=0) or (u<=0 and v<=0 and w<=0)
			var clearance := 1.0
			if not inside:
				var d := minf(p.distance_to(Geometry2D.get_closest_point_to_segment(p,a,b)),
					minf(p.distance_to(Geometry2D.get_closest_point_to_segment(p,b,c)),p.distance_to(Geometry2D.get_closest_point_to_segment(p,c,a))))
				clearance = 1.0 - smoothstep(.12,.35,d)
			if clearance > image.get_pixel(x,y).r:
				image.set_pixel(x,y,Color(clearance,0,0))

static func _add_stone(parent: Node3D, rng: RandomNumberGenerator, at: Vector2, height: float) -> void:
	var outline: Array[Vector2] = []
	var sides := rng.randi_range(5, 7)
	var size := Vector2(rng.randf_range(.56, .86), rng.randf_range(.43, .72)) * .5
	for i in range(sides):
		var angle := TAU * i / sides + rng.randf_range(-.13, .13)
		outline.append(Vector2(cos(angle), sin(angle)) * size * rng.randf_range(.84, 1.13))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var thickness := rng.randf_range(.040, .065)
	for i in range(sides):
		var p := outline[i]
		var q := outline[(i + 1) % sides]
		var p_top := Vector3(p.x * .86, thickness, p.y * .86)
		var q_top := Vector3(q.x * .86, thickness, q.y * .86)
		var p_bottom := Vector3(p.x, 0, p.y)
		var q_bottom := Vector3(q.x, 0, q.y)
		st.set_normal(Vector3.UP)
		for v in [Vector3(0, thickness, 0), p_top, q_top]: st.add_vertex(v)
		var normal := (q_top - p_top).cross(p_bottom - p_top).normalized()
		st.set_normal(normal)
		for v in [p_top, p_bottom, q_bottom, p_top, q_bottom, q_top]: st.add_vertex(v)
	var stone := MeshInstance3D.new()
	stone.name = "Flagstone%02d" % parent.get_child_count()
	stone.mesh = st.commit()
	stone.material_override = A.material(Color("b7ac8c").lerp(Color("9b9578"), rng.randf() * .6), .06)
	stone.position = Vector3(at.x, height, at.y)
	stone.rotation.y = rng.randf_range(-.6, .6)
	stone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(stone)
	stone.owner = parent
