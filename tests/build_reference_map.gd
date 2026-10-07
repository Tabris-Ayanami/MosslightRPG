extends SceneTree
## Explicit authoring command. Rebuilds only reference_map.tscn and its terrain data.
## Run with a GPU, never --headless (MultiMesh data must be serialized).
const A = preload("res://scripts/reference_art.gd")
const TERRAIN = preload("res://scripts/reference_terrain.gd")
const NATURE := "res://assets/nature/"
const RUINS := "res://assets/ruins/"
const L = preload("res://scripts/world_layout.gd")
const FEATURES = preload("res://scripts/terrain_features.gd")
const W = preload("res://scripts/woodland_art.gd")
const LAKE = preload("res://scripts/lake_art.gd")
const REGIONS = preload("res://scripts/region_builder.gd")
var map: Node3D
var terrain: MarchingSquaresTerrain
var rng := RandomNumberGenerator.new()

func _initialize() -> void:
	call_deferred("_build")

func ground(x: float, z: float) -> float:
	return L.ground(x,z)

func grass_allowed(x: float, z: float) -> bool:
	return L.grass_allowed(x,z)

func _build() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Use a rendering device when baking reference terrain.")
		quit(1)
		return
	seed(29)
	rng.seed = 29
	map = Node3D.new()
	map.name = "WaterGarden"
	map.set_meta("bank_revision",1)
	map.set_meta("terrain_excavation_revision",1)
	root.add_child(map)
	terrain = TERRAIN.new()
	terrain.name = "SculptableTerrain"
	terrain.data_directory = "res://scenes/reference_terrain_data"
	terrain.enable_runtime_texture_baking = false
	terrain.dimensions = Vector3i(33, 32, 33)
	terrain.cell_size = Vector2.ONE
	terrain.grass_subdivisions = 4
	terrain.grass_size = Vector2(1.35, 1.20)
	terrain.position = Vector3(-32, 0, -96)
	map.add_child(terrain)
	await process_frame
	await process_frame
	for cz in range(4):
		for cx in range(4):
			var chunk := MarchingSquaresTerrainChunk.new()
			chunk.name = "Terrain_%d_%d" % [cx, cz]
			chunk.terrain_system = terrain
			chunk.merge_mode = MarchingSquaresTerrainChunk.Mode.SEMI_ROUND
			chunk.merge_threshold = 5.0
			chunk.generate_color_maps()
			chunk.generate_wall_color_maps()
			chunk.generate_grass_mask_map()
			for z in range(33):
				var row := PackedFloat32Array()
				for x in range(33):
					var wx := float(cx * 32 + x - 32)
					var wz := float(cz * 32 + z - 96)
					# Editable base heights; precise structural cuts run on triangles.
					row.append(L.base_ground(wx, wz))
					var density := L.grass_density(wx,wz)
					chunk.grass_mask_map[z * 33 + x] = Color(density,1,0,1)
				chunk.height_map.append(row)
			terrain.add_chunk(Vector2i(cx, cz), chunk, null, true)
			chunk.grass_planter.regenerate_all_cells()
			chunk.mark_dirty()
			print("BUILT_CHUNK ", cx, " ", cz)
			await process_frame
	terrain.grass_size = terrain.grass_size
	terrain.apply_pixel_materials()
	_build_water()
	_build_ruins()
	_build_nature()
	REGIONS.build(map)
	LAKE.build(map)
	_build_light()
	await process_frame
	await RenderingServer.frame_post_draw
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		MSTDataHandler.save_chunk_resources(terrain, chunk)
		chunk._data_dirty = false
	terrain._storage_initialized = true
	# Pack chunk headers only: the plugin reloads baked geometry and source maps.
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		chunk.mesh = null
		chunk.height_map = []
		for child in chunk.get_children():
			child.free()
	_owners(map)
	var packed := PackedScene.new()
	var err := packed.pack(map)
	if err == OK:
		err = ResourceSaver.save(packed, "res://scenes/reference_map.tscn")
	print("REFERENCE_MAP_SAVED ", error_string(err))
	map.queue_free()
	await process_frame
	quit(err)

func _owners(node: Node) -> void:
	for child in node.get_children():
		child.owner = map
		_owners(child)

func _group(label: String) -> Node3D:
	var node := Node3D.new()
	node.name = label
	map.add_child(node)
	return node

func _build_water() -> void:
	var water := MeshInstance3D.new()
	water.name = "Lake"
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(220, 220)
	water.mesh = mesh
	water.position.y = 0.6
	water.layers = 2
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/reference_water.gdshader")
	mat.set_shader_parameter("surface_normals", preload("res://assets/water/surface_normals.tres"))
	water.material_override = mat
	map.add_child(water)

func _build_ruins() -> void:
	var ruins := _group("WaterShrine")
	var stone := A.material(Color("b1b8a5"), 0.22)
	var light_stone := A.material(Color("c6c9b1"), 0.1)
	var dark_stone := A.material(Color("7c9189"), 0.18)
	var center := Vector3(FEATURES.SHRINE_CENTER.x, 1.1, FEATURES.SHRINE_CENTER.y)
	# Three courses of masonry expose their thickness in the pool.
	for course in range(3):
		var ring := A.annulus(ruins, center + Vector3(0, course * 0.43, 0), FEATURES.SHRINE_WALL_RADIUS, FEATURES.SHRINE_WALL_WIDTH, 0.4, stone, FEATURES.SHRINE_WALL_SEGMENTS)
		ring.rotation.y = 0.0 if course % 2 == 0 else PI / FEATURES.SHRINE_WALL_SEGMENTS
	A.annulus(ruins, center + Vector3(0, 1.19, 0), FEATURES.SHRINE_WALL_RADIUS + .01, 0.7, 0.23, light_stone, FEATURES.SHRINE_WALL_SEGMENTS)
	# Small central altar, with a submerged foundation.
	A.cylinder(ruins, Vector3(-5, 0.32, -2.5), 1.35, 0.65, dark_stone)
	A.cylinder(ruins, Vector3(-5, 0.85, -2.5), 0.95, 0.48, stone)
	A.cylinder(ruins, Vector3(-5, 1.13, -2.5), 1.08, 0.16, light_stone)
	A.model(ruins, RUINS + "Column_Round_Short.fbx", Vector3(-5, 1.2, -2.5), 1.15, 0, Color("b5c2b0"), true)
	# An arched colonnade behind the water court, with a broken right bay.
	A.model(ruins, RUINS + "Arch_Round_RoundColumn.fbx", Vector3(-6.8, 2.2, -7.2), 4.45, 0, Color("bcc3ad"), true)
	A.model(ruins, RUINS + "Arch_Gothic.fbx", Vector3(-1.9, 2.2, -7.2), 4.15, 0, Color("aab5a6"), true)
	A.model(ruins, RUINS + "Column_Round.fbx", Vector3(-9.5, 2.2, -3.0), 3.5, 0.05, Color("bcc3b0"), true)
	A.model(ruins, RUINS + "Column_Round_Short.fbx", Vector3(-8.4, 2.2, 1.8), 1.65, -0.12, Color("aab7a6"), true)
	var fallen := A.model(ruins, RUINS + "Column_Round.fbx", Vector3(-10.2, 2.5, 0.4), 2.4, 0.7, Color("abb8aa"), true)
	fallen.rotation.z = PI * 0.5
	# Hand placed worn paving avoids a uniform tiled lawn.
	for i in range(12):
		var z := 7.4 - i * 1.17
		var x := 1.6 + sin(z * 0.43) * 1.2
		for side in range(2):
			if rng.randf() < 0.16:
				continue
			var slab := A.block(ruins, Vector3(x + (side - 0.5) * 1.0, 2.24, z), Vector3(rng.randf_range(.72,.94), .10, rng.randf_range(.65,.97)), stone, false)
			slab.rotation.y = rng.randf_range(-0.15, 0.15)
	# Broad shallow steps link the two elevations; a hidden ramp gives smooth movement.
	for i in range(7):
		A.block(ruins, Vector3(5.4, 2.23 + i * .22, -.6 - i * .43), Vector3(2.8, .23, .48), light_stone, false)
	var ramp := A.block(ruins, Vector3(5.4, 2.79, -2.15), Vector3(2.8,.14,2.9), stone)
	ramp.rotation.x = deg_to_rad(31)
	ramp.visible = false
	for i in range(9):
		A.block(ruins, Vector3(2.5, 2.12 - i * .20, 8.1 + i * .32), Vector3(2.7, .25, .36), stone, false)
	# The sculpted shore already supplies a continuous collision slope.
	# A second box ramp would introduce a lip where the two surfaces meet.
	for i in range(17):
		var at := Vector3(rng.randf_range(-10.3,-.5), 2.21, rng.randf_range(-8.2,-6.7))
		A.model(ruins, RUINS + "Bricks.fbx", at, rng.randf_range(.18,.42), rng.randf()*TAU, Color("9fae9c"), true)

func _build_nature() -> void:
	var trees := _group("AncientTrees")
	W.tree(trees,Vector3(6.5,3.7,-5),8.7,180,true)
	W.tree(trees,Vector3(11,3.7,-6),6.0,181)
	W.tree(trees,Vector3(1.5,2.2,-10),6.4,182)
	W.tree(trees,Vector3(-12,2.2,-4.5),6.2,183)
	W.tree(trees,Vector3(11.1,2.2,4.5),6.2,184)
	var rocks := _group("ShoreRocks")
	for i in range(25):
		var a := rng.randf() * TAU
		var p := Vector2(cos(a) * rng.randf_range(12.5,15.5), sin(a) * rng.randf_range(8.7,11.6) - 1)
		if p.x > -.2 and p.x < 5.2 and p.y > 6.3:
			continue
		if L.road_distance(p.x,p.y)<3.2: continue
		var y := ground(p.x,p.y)
		A.model(rocks, NATURE + "Rock_Medium_%d.gltf" % (1 + i % 3), Vector3(p.x,maxf(y,0.0)-.22,p.y), rng.randf_range(.7,2.1), a, Color("7f9687"), true)
	for at in [Vector3(7,2.2,2),Vector3(8.6,3.7,-3.5),Vector3(-11,2.2,-6.8)]:
		A.model(rocks, NATURE + "Rock_Medium_1.gltf", at, 1.4, rng.randf()*TAU, Color("8ba18e"), true)
	var plants := _group("Understory")
	for i in range(55):
		var x := rng.randf_range(-13,13)
		var z := rng.randf_range(-9,8)
		if not grass_allowed(x,z):
			continue
		var file := "Fern_1.gltf" if i % 3 == 0 else ("Flower_3_Group.gltf" if i % 4 == 0 else "Bush_Common.gltf")
		var h := rng.randf_range(.35,.8) if "Bush" in file else rng.randf_range(.25,.5)
		A.model(plants, NATURE + file, Vector3(x,ground(x,z),z), h, rng.randf()*TAU)

func _build_light() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "GardenSun"
	sun.rotation_degrees = Vector3(-65, -33, 0)
	sun.light_color = Color("fff2d6")
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 70
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.shadow_bias = .08
	sun.shadow_normal_bias = 1.5
	map.add_child(sun)
	var env := WorldEnvironment.new()
	env.name = "GardenEnvironment"
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("638f91")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("859eac")
	env.environment.ambient_light_energy = .35
	env.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment.ssao_enabled = true
	env.environment.ssao_radius = 1.0
	env.environment.ssao_intensity = 1.0
	env.environment.ssao_light_affect = .5
	map.add_child(env)

