extends SceneTree
## One-time upgrade from sampled basin heights to non-destructive surface cuts.
## Keeps the authored scene, painting, grass outside the cut and sculpt offsets.
const L = preload("res://scripts/world_layout.gd")
const F = preload("res://scripts/terrain_features.gd")
const SCENE := "res://scenes/reference_map.tscn"
const STAGING := "res://.work/terrain-clearance/staged"
const BACKUP := "res://.work/terrain-clearance/migration-backup"
func _initialize(): call_deferred("run")

func run():
	if DisplayServer.get_name() == "headless":
		push_error("Use a GPU to preserve the baked grass buffers.")
		quit(1)
		return
	var map: Node3D = load(SCENE).instantiate()
	root.add_child(map)
	await process_frame
	await process_frame
	if map.get_meta("terrain_excavation_revision", 0) >= 1:
		print("EXCAVATIONS_ALREADY_UPDATED")
		map.free()
		quit()
		return
	assert(map.get_meta("bank_revision", 0) == 1, "Run the bank migration first.")
	var terrain: MarchingSquaresTerrain = map.get_node("SculptableTerrain")
	var original_directory := terrain.data_directory
	var scene_text := FileAccess.get_file_as_string(SCENE)
	assert(scene_text.count("metadata/bank_revision = 1") == 1)
	assert(not scene_text.contains("metadata/terrain_excavation_revision"))
	DirAccess.make_dir_recursive_absolute(BACKUP)
	assert(DirAccess.copy_absolute(SCENE, BACKUP.path_join("reference_map.tscn")) == OK)
	var changed_chunks: Array[String] = []
	var changed_vertices := 0
	terrain.data_directory = STAGING
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		var changed := false
		var offset := chunk.position + terrain.position
		for z in range(terrain.dimensions.z):
			for x in range(terrain.dimensions.x):
				var p := Vector2(offset.x, offset.z) + Vector2(x,z) * terrain.cell_size
				# In revision 0 the basin was an independent 3.45 m sample test.
				if p.distance_to(F.SHRINE_CENTER) < 3.45:
					chunk.height_map[z][x] += L.base_ground(p.x, p.y) - .1
					changed = true
					changed_vertices += 1
		if not changed: continue
		var name := "chunk_%d_%d" % [chunk.chunk_coords.x, chunk.chunk_coords.y]
		changed_chunks.append(name)
		assert(DirAccess.copy_absolute(original_directory.path_join(name).path_join("metadata.res"), BACKUP.path_join(name + ".res")) == OK)
		var old_grass := chunk.grass_planter.multimesh.buffer
		chunk.regenerate_all_cells(false)
		# Retain original instances outside cells touched by the excavation.
		chunk.grass_planter.multimesh.buffer = old_grass
		for z in range(terrain.dimensions.z - 1):
			for x in range(terrain.dimensions.x - 1):
				var p := Vector2(offset.x, offset.z) + Vector2(x,z) * terrain.cell_size
				var nearest := F.SHRINE_CENTER.clamp(p, p + terrain.cell_size)
				if nearest.distance_to(F.SHRINE_CENTER) <= F.SHRINE_WALL_RADIUS:
					chunk.grass_planter.generate_grass_on_cell(Vector2i(x,z))
		await process_frame
		await RenderingServer.frame_post_draw
		MSTDataHandler.save_chunk_resources(terrain, chunk)
		chunk._data_dirty = false
		var staged: MSTChunkData = ResourceLoader.load(STAGING.path_join(name).path_join("metadata.res"), "", ResourceLoader.CACHE_MODE_IGNORE)
		var original: MSTChunkData = ResourceLoader.load(BACKUP.path_join(name + ".res"), "", ResourceLoader.CACHE_MODE_IGNORE)
		assert(staged.mesh != null and staged.grass_multimesh != null)
		assert(staged.mesh.get_faces() == staged.collision_faces)
		assert(staged.grass_mask == original.grass_mask and staged.ground_texture_idx == original.ground_texture_idx and staged.wall_texture_idx == original.wall_texture_idx)
		print("EXCAVATION_STAGED ", name, " triangles=", staged.collision_faces.size()/3)
	# Only commit once every staged chunk has passed source/collision checks.
	for name in changed_chunks:
		var err := DirAccess.copy_absolute(STAGING.path_join(name).path_join("metadata.res"), original_directory.path_join(name).path_join("metadata.res"))
		if err != OK:
			rollback(changed_chunks, original_directory)
			map.free()
			quit(err)
			return
	var file := FileAccess.open(SCENE, FileAccess.WRITE)
	if file == null:
		rollback(changed_chunks, original_directory)
		map.free()
		quit(1)
		return
	file.store_string(scene_text.replace("metadata/bank_revision = 1", "metadata/bank_revision = 1\nmetadata/terrain_excavation_revision = 1"))
	file.close()
	terrain.data_directory = original_directory
	print("EXCAVATIONS_SAVED chunks=", changed_chunks, " source_vertices=", changed_vertices)
	map.free()
	quit()

func rollback(chunks: Array[String], directory: String):
	for name in chunks:
		DirAccess.copy_absolute(BACKUP.path_join(name + ".res"), directory.path_join(name).path_join("metadata.res"))
	DirAccess.copy_absolute(BACKUP.path_join("reference_map.tscn"), SCENE)
	push_error("Could not commit terrain; restored the original scene and chunks.")
