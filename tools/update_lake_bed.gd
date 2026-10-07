extends SceneTree
const LAKE=preload("res://scripts/lake_art.gd")
var map: Node3D
func _initialize(): call_deferred("run")
func run():
	if DisplayServer.get_name()=="headless":
		push_error("Lake authoring needs GPU MultiMesh serialization.")
		quit(1)
		return
	map=load("res://scenes/reference_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	await process_frame
	var stone_count: int = LAKE.build(map)
	await process_frame
	await RenderingServer.frame_post_draw
	var terrain: MarchingSquaresTerrain=map.get_node("SculptableTerrain")
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		chunk.mesh=null
		chunk.height_map=[]
		chunk._data_dirty=false
		for child in chunk.get_children(): child.free()
	owners(map)
	var packed:=PackedScene.new()
	var err:=packed.pack(map)
	if err==OK: err=ResourceSaver.save(packed,"res://scenes/reference_map.tscn")
	print("LAKE_BED_SAVED ",stone_count," stones; ",error_string(err))
	map.free()
	quit(err)
func owners(node: Node):
	for child in node.get_children():
		child.owner=map
		owners(child)
