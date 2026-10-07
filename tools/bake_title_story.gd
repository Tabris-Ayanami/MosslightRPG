extends SceneTree
const RIG=preload("res://tools/title_performance_rig.gd")
const STORY=preload("res://scripts/frontend/title_story.gd")
const FPS := 60.0
const WORK := "res://.work/title-story/"
func _initialize() -> void: call_deferred("run")
func xyz(v: Vector3) -> Array: return [v.x,v.y,v.z]
func matrix(t: Transform3D) -> Array:
	return [t.basis.x.x,t.basis.y.x,t.basis.z.x,t.origin.x,t.basis.x.y,t.basis.y.y,t.basis.z.y,t.origin.y,t.basis.x.z,t.basis.y.z,t.basis.z.z,t.origin.z]
func run() -> void:
	DirAccess.make_dir_recursive_absolute(WORK)
	var actor := RIG.new()
	root.add_child(actor)
	var sk: Skeleton3D=actor.skeleton
	var garment: MeshInstance3D=actor.find_child("polySurface84",true,false)
	var source: Mesh=garment.mesh
	var skin: Skin=garment.skin
	var bindings := []
	for i in range(skin.get_bind_count()):
		var name := skin.get_bind_name(i)
		var bone := sk.find_bone(name) if not name.is_empty() else skin.get_bind_bone(i)
		bindings.append(bone)
	var geometry := {"surfaces":[],"bindings":bindings,"fps":FPS,"duration":STORY.END,"rest_time":STORY.RISE_END,"names":[],"colliders":{}}
	for bone in range(sk.get_bone_count()): geometry.names.append(sk.get_bone_name(bone))
	for surface in range(source.get_surface_count()):
		var arrays := source.surface_get_arrays(surface)
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array=arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
		var influences := weights.size()/vertices.size()
		var cloth_weight := PackedFloat32Array()
		for vertex in range(vertices.size()):
			var weight := 0.0
			for j in range(influences):
				var bind := bones[vertex*influences+j]
				if sk.get_bone_name(bindings[bind]).begins_with("dayi"): weight+=weights[vertex*influences+j]
			cloth_weight.append(weight)
		var cloth_indices := []
		var upper_indices := []
		for i in range(0,indices.size(),3):
			var is_cloth := false
			for j in range(3): is_cloth=is_cloth or cloth_weight[indices[i+j]]>.001
			for j in range(3):
				if is_cloth: cloth_indices.append(indices[i+j])
				else: upper_indices.append(indices[i+j])
		var positions := []
		var normals := []
		var uv := []
		for i in range(vertices.size()):
			positions.append(xyz(vertices[i]))
			normals.append(xyz(arrays[Mesh.ARRAY_NORMAL][i]))
			var texture_uv: Vector2=arrays[Mesh.ARRAY_TEX_UV][i]
			uv.append([texture_uv.x,texture_uv.y])
		geometry.surfaces.append({"positions":positions,"normals":normals,"uv":uv,"bones":Array(bones),"weights":Array(weights),"cloth_weights":Array(cloth_weight),"cloth_indices":cloth_indices,"upper_indices":upper_indices,"influences":influences})
		print("GARMENT surface=",surface," vertices=",vertices.size()," cloth triangles=",cloth_indices.size()/3)
	var out := FileAccess.open(WORK+"geometry.json",FileAccess.WRITE)
	out.store_string(JSON.stringify(geometry))
	out.close()
	var matrices := FileAccess.open(WORK+"skin-matrices.bin",FileAccess.WRITE)
	var bodies := FileAccess.open(WORK+"body-points.bin",FileAccess.WRITE)
	var collider_names := ["J_Bip_C_Hips","J_Bip_C_Chest","J_Bip_L_UpperLeg","J_Bip_L_LowerLeg","J_Bip_L_Foot","J_Bip_R_UpperLeg","J_Bip_R_LowerLeg","J_Bip_R_Foot"]
	var animation := Animation.new()
	animation.resource_name="TitleStory"
	animation.length=STORY.END
	var pos_track := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(pos_track,NodePath("PerformanceHero"))
	var rot_track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(rot_track,NodePath("PerformanceHero"))
	var hip_track := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(hip_track,NodePath(str(actor.get_path_to(sk))+":J_Bip_C_Hips"))
	var tracks := PackedInt32Array()
	for bone in range(sk.get_bone_count()):
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track,NodePath(str(actor.get_path_to(sk))+":"+sk.get_bone_name(bone)))
		tracks.append(track)
	var worst_contact := 0.0
	var worst_time := 0.0
	var contacts := {}
	for name in ["J_Bip_L_Foot","J_Bip_R_Foot","L_Hand","J_Bip_R_Hand"]: contacts[name]=PackedVector3Array()
	for frame in range(roundi(STORY.END*FPS)+1):
		var seconds := float(frame)/FPS
		actor.apply_time(seconds)
		for name: String in contacts: contacts[name].append(actor.contact_targets.get(name,actor.point(name)))
		if actor.contact_error>worst_contact:
			worst_contact=actor.contact_error
			worst_time=seconds
		animation.position_track_insert_key(pos_track,seconds,actor.hero.position)
		animation.rotation_track_insert_key(rot_track,seconds,actor.hero.quaternion)
		animation.position_track_insert_key(hip_track,seconds,sk.get_bone_pose_position(sk.find_bone("J_Bip_C_Hips")))
		for bone in range(sk.get_bone_count()): animation.rotation_track_insert_key(tracks[bone],seconds,sk.get_bone_pose_rotation(bone))
		var frame_matrices := PackedFloat32Array()
		var frame_body := PackedFloat32Array()
		for bind in range(skin.get_bind_count()):
			var transform := actor.global_transform.affine_inverse()*sk.global_transform*sk.get_bone_global_pose(bindings[bind])*skin.get_bind_pose(bind)
			frame_matrices.append_array(PackedFloat32Array(matrix(transform)))
		for name in collider_names:
			frame_body.append_array(PackedFloat32Array(xyz(actor.to_local(sk.to_global(sk.get_bone_global_pose(sk.find_bone(name)).origin)))))
		matrices.store_buffer(frame_matrices.to_byte_array())
		bodies.store_buffer(frame_body.to_byte_array())
	matrices.close()
	bodies.close()
	animation.set_meta("sample_hz",FPS)
	animation.set_meta("contact_error",worst_contact)
	animation.set_meta("source_author","Quaternius")
	animation.set_meta("source_clips",["UAL2 LayToIdle","UAL1 Idle_Loop","UAL1 Walk_Loop"])
	animation.set_meta("source_license","CC0-1.0")
	animation.set_meta("contact_targets",contacts)
	animation.set_meta("back_grip",actor.back_grip)
	animation.set_meta("back_tip",actor.back_tip)
	var error := ResourceSaver.save(animation,"res://assets/ui/title/title-story.res",ResourceSaver.FLAG_COMPRESS)
	print("TITLE_STORY_BAKE ",error," contact_error=",worst_contact," at ",worst_time)
	actor.queue_free()
	await process_frame
	quit(error)
