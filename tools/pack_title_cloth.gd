extends SceneTree
const WORK := "res://.work/title-story/"
const OUT := "res://assets/ui/title/"
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var data: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(WORK+"cloth.json"))
	var actor=load("res://tools/title_performance_rig.gd").new()
	root.add_child(actor)
	var garment: MeshInstance3D=actor.find_child("polySurface84",true,false)
	var upper := ArrayMesh.new()
	var shell := ArrayMesh.new()
	for surface in range(garment.mesh.get_surface_count()):
		var original := garment.mesh.surface_get_arrays(surface)
		var partition: Dictionary=data.surfaces[surface]
		var upper_arrays: Array=original.duplicate()
		upper_arrays[Mesh.ARRAY_INDEX]=PackedInt32Array(partition.upper_indices)
		upper.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,upper_arrays)
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var uv := PackedVector2Array()
		var uv2 := PackedVector2Array()
		var indices := PackedInt32Array()
		var offset := int(partition.offset)
		for i in range(partition.ids.size()):
			var id := offset+i
			var p: Array=data.initial_positions[id]
			vertices.append(Vector3(p[0],p[1],p[2]))
			normals.append(Vector3.UP)
			uv.append(Vector2(data.uv[id][0],data.uv[id][1]))
			uv2.append(Vector2(id,0))
		for triangle: Array in partition.triangles:
			for id: float in triangle: indices.append(int(id)-offset)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX]=vertices
		arrays[Mesh.ARRAY_NORMAL]=normals
		arrays[Mesh.ARRAY_TEX_UV]=uv
		arrays[Mesh.ARRAY_TEX_UV2]=uv2
		arrays[Mesh.ARRAY_INDEX]=indices
		shell.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var lo: Array=data.bounds_min
	var hi: Array=data.bounds_max
	shell.custom_aabb=AABB(Vector3(lo[0],lo[1],lo[2])-Vector3.ONE*.2,Vector3(hi[0]-lo[0],hi[1]-lo[1],hi[2]-lo[2])+Vector3.ONE*.4)
	ResourceSaver.save(upper,OUT+"upper-garment.res",ResourceSaver.FLAG_COMPRESS)
	ResourceSaver.save(shell,OUT+"cloth-shell.res",ResourceSaver.FLAG_COMPRESS)
	for label in ["positions","normals"]:
		var image := Image.create_from_data(int(data.width),int(data.height),false,Image.FORMAT_RGBF,FileAccess.get_file_as_bytes(WORK+"cloth-"+label+".bin"))
		ResourceSaver.save(ImageTexture.create_from_image(image),OUT+"cloth-"+label+".res",ResourceSaver.FLAG_COMPRESS)
	print("TITLE_CLOTH_PACKED ",data.width," x ",data.height," vertices x frames; actual lower coat surface min y=",data.floor_min)
	actor.queue_free()
	await process_frame
	quit()
