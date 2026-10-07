extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var actor=load("res://scripts/frontend/resting_kirito.gd").new()
	root.add_child(actor)
	var skeleton: Skeleton3D=actor.skeleton
	var previous: Array[Quaternion]=[]
	var max_step := 0.0
	var max_name := ""
	var max_progress := 0.0
	var min_hem := 100.0
	var max_contact := 0.0
	var bone_max := {}
	for frame in range(649):
		actor.apply_pose(float(frame)/648)
		max_contact=maxf(max_contact,actor.contact_error)
		for bone in range(skeleton.get_bone_count()):
			var q := skeleton.get_bone_pose_rotation(bone)
			if frame==0: previous.append(q)
			var angle := previous[bone].angle_to(q)
			var name := skeleton.get_bone_name(bone)
			bone_max[name]=maxf(bone_max.get(name,0),rad_to_deg(angle))
			if angle>max_step:
				max_step=angle
				max_name=skeleton.get_bone_name(bone)
				max_progress=float(frame)/648
			previous[bone]=q
			if skeleton.get_bone_name(bone).begins_with("dayi_"):
				var p: Vector3=actor.to_local(skeleton.to_global(skeleton.get_bone_global_pose(bone).origin))
				min_hem=minf(min_hem,p.y)
	print("PERFORMANCE_AUDIT max_bone_step_degrees=",rad_to_deg(max_step)," bone=",max_name," progress=",max_progress," min_cloth_y=",min_hem," endpoint_error=",max_contact)
	var names := bone_max.keys()
	names.sort_custom(func(a,b): return bone_max[a]>bone_max[b])
	for n in names.slice(0,10): print("MAX_BONE ",n," ",bone_max[n])
	var hips := skeleton.find_bone("J_Bip_C_Hips")
	for time in [.16,.28,.34,.41,.53,.66,.8,.92]:
		actor.apply_pose(time-.003)
		var before := skeleton.to_global(skeleton.get_bone_global_pose(hips).origin)
		actor.apply_pose(time+.003)
		var after := skeleton.to_global(skeleton.get_bone_global_pose(hips).origin)
		print("HIP_SPEED ",time," ",before.distance_to(after)/(.006*5.4))
	actor.queue_free()
	await process_frame
	quit()
