extends SceneTree
## Writes only road resources; the companion patcher updates their scene references.
const Roads = preload("res://scripts/road_art.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/roads")
	var map: Node3D = load("res://scenes/reference_map.tscn").instantiate()
	var material := Roads.material()
	var error := ResourceSaver.save(material, "res://assets/roads/earth.tres")
	assert(error == OK)
	var records: Array[Dictionary] = []
	for group_path in ["RegionConnections", "NorthernVillage/DoorstepLanes"]:
		for node in map.get_node(group_path).get_children():
			if not node is MeshInstance3D: continue
			var arrays: Array = node.mesh.surface_get_arrays(0)
			var mesh: Mesh = node.mesh
			if arrays[Mesh.ARRAY_TEX_UV] == null or arrays[Mesh.ARRAY_TEX_UV].is_empty():
				mesh = Roads.upgrade_ribbon(node.mesh)
			assert(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == arrays[Mesh.ARRAY_VERTEX])
			var faces := mesh.get_faces()
			for i in range(0, faces.size(), 3):
				assert((faces[i + 1] - faces[i]).cross(faces[i + 2] - faces[i]).y <= 0.00001)
			var path := "res://assets/roads/road_%02d.res" % records.size()
			error = ResourceSaver.save(mesh, path)
			assert(error == OK)
			records.append({"node": group_path + "/" + String(node.name), "mesh": path, "triangles": faces.size() / 3})
	assert(records.size() == 9)
	error = ResourceSaver.save(Roads.grass_clearance(map), "res://assets/roads/grass_clearance.res")
	assert(error == OK)
	var plaza: MeshInstance3D = map.get_node("NorthernVillage/MarketSquare").get_child(0)
	var center := plaza.mesh.get_aabb().get_center()
	assert(plaza.mesh.get_aabb().size.x > 12)
	error = ResourceSaver.save(Roads.material(true, Vector2(center.x, center.z)), "res://assets/roads/plaza_earth.tres")
	assert(error == OK)
	var stones := Roads.flagstones()
	var packed := PackedScene.new()
	error = packed.pack(stones)
	assert(error == OK)
	error = ResourceSaver.save(packed, "res://assets/roads/flagstones.tscn")
	assert(error == OK)
	var report := FileAccess.open("res://assets/roads/layout.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"roads": records, "plaza": "NorthernVillage/MarketSquare/" + String(plaza.name), "flagstones": stones.get_child_count()}, "\t"))
	report.close()
	print("EARTH_ROADS_BAKED ", records.size(), " ribbons; ", stones.get_child_count(), " slabs. All source vertices preserved; clockwise top faces verified.")
	stones.free()
	map.free()
	quit()
