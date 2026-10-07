extends SceneTree
## Validate saved render/collision geometry and rebuilding from editable sources.
const F = preload("res://scripts/terrain_features.gd")
const L = preload("res://scripts/world_layout.gd")
var game: Node
var checks := 0
var failures := 0
func _initialize(): call_deferred("run")
func ticks(n: int):
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool, label: String):
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", label)
func ray(a: Vector3, b: Vector3) -> Dictionary:
	return game.viewport.find_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(game.GARDEN_ORIGIN+a,game.GARDEN_ORIGIN+b,256))
func height_at(p: Vector2) -> float:
	var hit := ray(Vector3(p.x,15,p.y),Vector3(p.x,-5,p.y))
	return hit.position.y if not hit.is_empty() else -999.0
func basin_error() -> float:
	var worst := 0.0
	for ring in range(1, 13):
		for angle in range(360):
			var p := F.SHRINE_CENTER + Vector2.from_angle(deg_to_rad(angle)) * (3.40 * ring / 12.0)
			worst = maxf(worst,absf(height_at(p)-F.SHRINE_FLOOR))
	return worst
func mesh_matches_collision(terrain: MarchingSquaresTerrain) -> bool:
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		var shapes := chunk.find_children("*", "CollisionShape3D", true, false)
		if shapes.size() != 1: return false
		if shapes[0].shape.get_faces() != chunk.mesh.get_faces(): return false
	return true
func floor_seam_edges(chunk: MarchingSquaresTerrainChunk, terrain: MarchingSquaresTerrain) -> Array[String]:
	var result: Array[String]=[]
	var faces:=chunk.mesh.get_faces()
	var offset:=chunk.position+terrain.position
	for i in range(0,faces.size(),3):
		for j in range(3):
			var a:=faces[i+j]+offset
			var b:=faces[i+(j+1)%3]+offset
			if absf(a.z)>.000001 or absf(b.z)>.000001: continue
			if absf(a.y-F.SHRINE_FLOOR)>.000001 or absf(b.y-F.SHRINE_FLOOR)>.000001: continue
			if absf(a.x-b.x)<.000001: continue
			result.append("%.6f:%.6f"%[minf(a.x,b.x),maxf(a.x,b.x)])
	result.sort()
	return result
func run():
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted=true
	await ticks(20)
	var terrain: MarchingSquaresTerrain=game.reference_map.get_node("SculptableTerrain")
	check(game.reference_map.get_meta("terrain_excavation_revision",0)==1,"saved map uses editable base heights plus structural cuts")
	var modes_ok:=true
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		modes_ok=modes_ok and is_equal_approx(chunk.merge_threshold,chunk.MERGE_MODE[chunk.merge_mode])
	check(modes_ok,"all sixteen loaded chunks restore the correct smoothing threshold before regeneration")
	var rings:=0
	var dimensions_ok:=true
	for ring in game.reference_map.get_node("WaterShrine").get_children():
		if ring.get_child_count()!=F.SHRINE_WALL_SEGMENTS: continue
		var stone: MeshInstance3D=ring.get_child(0)
		if not stone.mesh is BoxMesh: continue
		rings+=1
		dimensions_ok=dimensions_ok and Vector2(ring.position.x,ring.position.z).distance_to(F.SHRINE_CENTER)<.0001
		var radius:=Vector2(stone.position.x,stone.position.z).length()
		dimensions_ok=dimensions_ok and absf(radius-F.SHRINE_WALL_RADIUS)<.011
	check(rings==4 and dimensions_ok,"existing masonry and structural footprint share a center and wall radius")
	var error:=basin_error()
	print("BASIN_SAMPLES count=4320 max_floor_error=",error)
	check(error<.001,"4320 basin points remain on the submerged floor, including the entire inner wall")
	var exterior_ok:=true
	for angle in range(360):
		var p:=F.SHRINE_CENTER+Vector2.from_angle(deg_to_rad(angle))*4.1
		exterior_ok=exterior_ok and absf(height_at(p)-2.2)<.001
	check(exterior_ok,"360 exterior points retain the original lawn with no moat outside the pool")
	var sides_ok:=true
	for angle in range(72):
		var direction:=Vector2.from_angle(TAU*angle/72.0)
		var a:=Vector3(F.SHRINE_CENTER.x,1.0,F.SHRINE_CENTER.y)
		var hit:=ray(a,a+Vector3(direction.x,0,direction.y)*5.0)
		if hit.is_empty(): sides_ok=false
		else:
			var local: Vector3=hit.position-game.GARDEN_ORIGIN
			var radius:=Vector2(local.x,local.z).distance_to(F.SHRINE_CENTER)
			sides_ok=sides_ok and absf(radius-F.SHRINE_WALL_RADIUS)<.01
	check(sides_ok,"72 horizontal rays hit continuous excavation sides behind the masonry")
	var seam_a:=floor_seam_edges(terrain.chunks[Vector2i(0,2)],terrain)
	var seam_b:=floor_seam_edges(terrain.chunks[Vector2i(0,3)],terrain)
	var seam_ok:=not seam_a.is_empty() and seam_a==seam_b
	for i in range(51):
		# Jolt ray/triangle boundary tests have float rounding ambiguity exactly
		# on a shared edge; compare those vertices directly and raycast both sides.
		for z in [-.0001,.0001]:
			var p:=Vector2(-7.4+i*.095,z)
			seam_ok=seam_ok and absf(height_at(p)-F.SHRINE_FLOOR)<.001
	check(seam_ok,"pool floor is continuous on both sides of the z=0 terrain chunk seam")
	check(mesh_matches_collision(terrain),"saved collision triangles match visible terrain in all sixteen chunks")
	var foundations_ok:=true
	var foundation_samples:=0
	for p in [Vector2(-10,-31.5),Vector2(9.8,-31.5),Vector2(-12,-43),Vector2(12,-48),Vector2(-6,-54),Vector2(16,-39),Vector2(3.7,-53)]:
		for x in [-1.5,0.0,1.5]:
			for z in [-1.5,0.0,1.5]:
				foundations_ok=foundations_ok and absf(height_at(p+Vector2(x,z))-2.2)<.001
				foundation_samples+=1
	print("FOUNDATION_SAMPLES ",foundation_samples)
	check(foundations_ok,"seven village building sites retain level terrain across 63 footprint samples")
	var channels_ok:=true
	for p in [Vector2(17.2,1.7),Vector2(18,1.7),Vector2(18.8,1.7),Vector2(0,-16),Vector2(0,-17),Vector2(0,-18)]:
		channels_ok=channels_ok and absf(height_at(p)+1.5)<.001
	check(channels_ok,"both bridge channels remain excavated below the water")
	# Capture samples outside the footprint before reconstructing the entire
	# affected chunks. This catches smoothing-mode loss on save/load.
	var exterior_samples: Dictionary={}
	for chunk_coord in [Vector2i(0,2),Vector2i(0,3)]:
		var chunk: MarchingSquaresTerrainChunk=terrain.chunks[chunk_coord]
		for z in range(32):
			for x in range(32):
				var offset:=chunk.position+terrain.position
				var p:=Vector2(offset.x+x+.23,offset.z+z+.37)
				if p.distance_to(F.SHRINE_CENTER)>4.1: exterior_samples[p]=height_at(p)
	var source_preserved:=true
	for chunk_coord in [Vector2i(0,2),Vector2i(0,3)]:
		var chunk: MarchingSquaresTerrainChunk=terrain.chunks[chunk_coord]
		var heights:=chunk.height_map.duplicate(true)
		var paint:=chunk.color_map_0.duplicate()
		var mask:=chunk.grass_mask_map.duplicate()
		chunk.regenerate_all_cells(true)
		source_preserved=source_preserved and heights==chunk.height_map and paint==chunk.color_map_0 and mask==chunk.grass_mask_map
	await ticks(3)
	check(source_preserved,"threaded reconstruction preserves sculpt heights, painting and grass masks")
	check(basin_error()<.001 and mesh_matches_collision(terrain),"rebuilding from editable data reproduces the clear basin and matching collision")
	var outside_error:=0.0
	for p: Vector2 in exterior_samples: outside_error=maxf(outside_error,absf(height_at(p)-exterior_samples[p]))
	print("REBUILD_EXTERIOR_SAMPLES ",exterior_samples.size()," max_error=",outside_error)
	check(outside_error<.001,"reloading and rebuilding keeps surrounding slopes and shore collision unchanged")
	# Move an excavation across a chunk edge in memory: no pool-coordinate
	# special cases, no change to the base height map, no files saved.
	var shifted_center:=F.SHRINE_CENTER+Vector2(4.8,0)
	var shifted: Array[Dictionary]=F.excavations()
	var outline: PackedVector2Array=shifted[0].outline
	for i in range(outline.size()): outline[i]+=Vector2(4.8,0)
	shifted[0].outline=outline
	terrain._structural_cuts=shifted
	for coordinate in [Vector2i(0,2),Vector2i(0,3),Vector2i(1,2),Vector2i(1,3)]:
		terrain.chunks[coordinate].regenerate_all_cells(true)
	await ticks(3)
	var shifted_ok:=absf(height_at(F.SHRINE_CENTER)-2.2)<.001
	for angle in range(72):
		var p:=shifted_center+Vector2.from_angle(TAU*angle/72.0)*3.2
		shifted_ok=shifted_ok and absf(height_at(p)-F.SHRINE_FLOOR)<.001
	check(shifted_ok,"a relocated cut crosses four chunks cleanly and releases the old footprint")
	print("TERRAIN_EXCAVATION_RESULT ",checks-failures,"/",checks)
	game.queue_free()
	await ticks(2)
	quit(1 if failures else 0)
