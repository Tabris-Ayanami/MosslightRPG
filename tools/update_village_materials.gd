extends SceneTree
## Refreshes village materials and lighting without rebuilding terrain or placements.
var map: Node3D
const A = preload("res://scripts/reference_art.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Use a GPU session to preserve MultiMesh buffers when saving.")
		quit(1)
		return
	map=load("res://scenes/reference_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	var sun: DirectionalLight3D=map.get_node("GardenSun")
	sun.rotation_degrees=Vector3(-65,-33,0)
	sun.shadow_bias=.08
	sun.shadow_normal_bias=1.5
	var changed:=0
	for m: MeshInstance3D in map.get_node("NorthernVillage").find_children("*","MeshInstance3D",true,false):
		for s in m.mesh.get_surface_count():
			var source=m.mesh.surface_get_material(s)
			var mat=m.get_active_material(s)
			if source and "RoofTiles" in source.resource_name and mat is ShaderMaterial:
				var axis: Vector3=m.global_basis.x.normalized()
				mat.set_shader_parameter("roof_tiles",true)
				mat.set_shader_parameter("roof_axis",Vector2(axis.x,axis.z))
				changed+=1
		A.bake_import_transform(m)
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
	print("VILLAGE_MATERIALS_SAVED ",changed," roof surfaces; ",error_string(err))
	map.queue_free()
	await process_frame
	quit(err)
func owners(node: Node) -> void:
	for child in node.get_children():
		child.owner=map
		owners(child)
