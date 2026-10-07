extends SceneTree
## Regrades existing editable height maps, preserving painting and placed scenery.
const L = preload("res://scripts/world_layout.gd")
const PREVIOUS = preload("res://tools/legacy_terrace_layout.gd")
var map: Node3D
func _initialize(): call_deferred("run")
func run():
	if DisplayServer.get_name()=="headless":
		push_error("Bank baking needs a GPU for grass serialization.")
		quit(1)
		return
	map=load("res://scenes/reference_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	await process_frame
	if map.get_meta("bank_revision",0)>=1:
		print("BANKS_ALREADY_UPDATED")
		quit()
		return
	var terrain: MarchingSquaresTerrain=map.get_node("SculptableTerrain")
	var changed:=0
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		for z in range(33):
			for x in range(33):
				var p:=Vector2(chunk.chunk_coords.x*32+x-32,chunk.chunk_coords.y*32+z-96)
				var previous:=PREVIOUS.ground(p.x,p.y)
				var next:=L.ground(p.x,p.y)
				# Retain any manually sculpted offsets from the original layout.
				chunk.height_map[z][x]+=next-previous
				if absf(next-previous)>.0001: changed+=1
				if next<.9: chunk.grass_mask_map[z*33+x].r=0.0
		chunk.merge_mode=MarchingSquaresTerrainChunk.Mode.SEMI_ROUND
		chunk.mark_dirty()
		await process_frame
		await RenderingServer.frame_post_draw
		MSTDataHandler.save_chunk_resources(terrain,chunk)
		chunk._data_dirty=false
		print("BANK_CHUNK ",chunk.chunk_coords)
	# Move natural props with their underlying soil. Buildings and bridges retain
	# their authored foundations; core plateaus remain at the original height.
	for group_name in ["AncientTrees","ShoreRocks","Understory","GardenWildflowers","EasternForest/Trees","EasternForest/FernsFlowersAndRocks","NorthernVillage/VillageGardens"]:
		var group:=map.get_node_or_null(group_name)
		if group==null: continue
		for child in group.get_children():
			if child is Node3D:
				var p: Vector3=child.position
				child.position.y+=L.ground(p.x,p.z)-PREVIOUS.ground(p.x,p.z)
	terrain.apply_pixel_materials()
	map.set_meta("bank_revision",1)
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		chunk.mesh=null
		chunk.height_map=[]
		for child in chunk.get_children(): child.free()
	owners(map)
	var packed:=PackedScene.new()
	var err:=packed.pack(map)
	if err==OK: err=ResourceSaver.save(packed,"res://scenes/reference_map.tscn")
	print("BANKS_SAVED ",changed," vertices; ",error_string(err))
	map.free()
	quit(err)
func owners(node: Node):
	for child in node.get_children():
		child.owner=map
		owners(child)
