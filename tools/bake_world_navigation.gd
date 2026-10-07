extends SceneTree
## Offline only. Uses the real map's collision geometry; never opens an adventure.
const OUTPUT := "res://assets/navigation/garden_navigation.tres"
var map: Node3D
var navigation_mesh: NavigationMesh
var started := 0

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	started = Time.get_ticks_msec()
	map = load("res://scenes/reference_map.tscn").instantiate()
	root.add_child(map)
	var terrain := map.get_node("SculptableTerrain")
	await terrain.load_finished
	await physics_frame
	print("NAV BAKE: terrain loaded; parsing static collision geometry")
	navigation_mesh = NavigationMesh.new()
	navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navigation_mesh.geometry_collision_mask = 1
	navigation_mesh.cell_size = .2
	navigation_mesh.cell_height = .1
	navigation_mesh.agent_radius = .6
	navigation_mesh.agent_height = 2.0
	navigation_mesh.agent_max_climb = .3
	navigation_mesh.agent_max_slope = 60.0
	navigation_mesh.filter_low_hanging_obstacles = true
	navigation_mesh.filter_ledge_spans = true
	navigation_mesh.filter_walkable_low_height_spans = true
	# The 0.6m lake is swimming space, not walkable land. Clip submerged floors.
	navigation_mesh.filter_baking_aabb = AABB(Vector3(-32, .7, -72), Vector3(106, 18, 90))
	navigation_mesh.region_min_size = 1.0
	navigation_mesh.region_merge_size = 8.0
	navigation_mesh.edge_max_error = 1.0
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(navigation_mesh, source, map)
	print("NAV BAKE: ", source.get_vertices().size() / 3, " source vertices; baking")
	NavigationServer3D.bake_from_source_geometry_data_async(navigation_mesh, source, finish)

func finish() -> void:
	var polygons := navigation_mesh.get_polygon_count()
	if polygons == 0:
		push_error("Navigation bake produced no polygons")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/navigation"))
	var error := ResourceSaver.save(navigation_mesh, OUTPUT)
	print("NAV BAKE: ", polygons, " polygons; ", navigation_mesh.vertices.size(), " vertices; ", (Time.get_ticks_msec() - started) / 1000.0, " seconds; save error ", error)
	map.queue_free()
	await process_frame
	quit(0 if error == OK else 1)
