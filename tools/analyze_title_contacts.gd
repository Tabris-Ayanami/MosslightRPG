extends SceneTree
const VISUAL=preload("res://scripts/kirito_visual.gd")
const NAMES=["J_Bip_C_Hips","J_Bip_C_Chest","J_Bip_C_Head","J_Bip_L_UpperLeg","J_Bip_L_LowerLeg","J_Bip_L_Foot","J_Bip_L_ToeBase","J_Bip_R_Foot","J_Bip_L_UpperArm","J_Bip_L_LowerArm","L_Hand","J_Bip_R_Hand"]
func _initialize() -> void: call_deferred("run")
func run() -> void:
	DirAccess.make_dir_recursive_absolute("res://.work/motion-integration/")
	var actor := Node3D.new()
	root.add_child(actor)
	var hero=VISUAL.new()
	hero.name="PerformanceHero"
	actor.add_child(hero)
	hero.rotation.y=PI
	hero.scale=Vector3.ONE*1.78
	hero.animator.stop()
	hero.animator.active=false
	var sk: Skeleton3D=hero.skeleton
	var player := AnimationPlayer.new()
	actor.add_child(player)
	var library: AnimationLibrary=load("res://assets/animations/retargeted/quaternius-title.res")
	player.add_animation_library("",library)
	for mesh: Node in hero.find_children("*","MeshInstance3D",true,false):
		print("MESH ",mesh.name," ",mesh.mesh.get_aabb())
	var data := {}
	var body: MeshInstance3D=hero.find_child("body_low",true,false)
	var arrays := body.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var influences: PackedInt32Array=arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
	var stride := weights.size()/vertices.size()
	var bind_ids := []
	for bind in range(body.skin.get_bind_count()): bind_ids.append(sk.find_bone(body.skin.get_bind_name(bind)))
	# The jacket's back is thicker than the body mesh. Its torso skin, including
	# the rigid/dynamic seam, participates in lying-body floor clearance as well.
	var jacket: MeshInstance3D=hero.find_child("polySurface84",true,false)
	var jacket_bind_ids := []
	for bind in range(jacket.skin.get_bind_count()): jacket_bind_ids.append(sk.find_bone(jacket.skin.get_bind_name(bind)))
	var jacket_core := []
	var waist_y := (sk.global_transform*sk.get_bone_global_rest(sk.find_bone("J_Bip_C_Hips"))).origin.y
	for surface in range(jacket.mesh.get_surface_count()):
		var a := jacket.mesh.surface_get_arrays(surface)
		var v: PackedVector3Array=a[Mesh.ARRAY_VERTEX]
		var b: PackedInt32Array=a[Mesh.ARRAY_BONES]
		var w: PackedFloat32Array=a[Mesh.ARRAY_WEIGHTS]
		var n := w.size()/v.size()
		for id in range(v.size()):
			var core_weight := 0.0
			var coat_weight := 0.0
			for j in range(n):
				var name := sk.get_bone_name(jacket_bind_ids[b[id*n+j]])
				if name.begins_with("J_Bip_C_"): core_weight+=w[id*n+j]
				elif name.begins_with("dayi") or name.ends_with("UpperLeg"): coat_weight+=w[id*n+j]
			var fixed_waist := core_weight+coat_weight>.7 and jacket.to_global(v[id]).y>waist_y
			if core_weight>.7 or fixed_waist: jacket_core.append({"p":v[id],"b":b.slice(id*n,(id+1)*n),"w":w.slice(id*n,(id+1)*n)})
	for clip in ["GetUp","Idle","Walk"]:
		player.play(clip)
		player.pause()
		var animation := player.get_animation(clip)
		var rows := []
		var frame_count := roundi(animation.length*60)
		for frame in range(frame_count+1):
			var seconds := animation.length*float(frame)/frame_count
			player.seek(seconds,true)
			var row := {"time":seconds,"bones":{}}
			var matrices := []
			for bind in range(body.skin.get_bind_count()): matrices.append(sk.global_transform*sk.get_bone_global_pose(bind_ids[bind])*body.skin.get_bind_pose(bind))
			var bounds := {"body":100.0,"core":100.0,"leftfoot":100.0,"rightfoot":100.0}
			var jacket_matrices := []
			for bind in range(jacket.skin.get_bind_count()): jacket_matrices.append(sk.global_transform*sk.get_bone_global_pose(jacket_bind_ids[bind])*jacket.skin.get_bind_pose(bind))
			for probe: Dictionary in jacket_core:
				var q := Vector3.ZERO
				for j in range(probe.w.size()): q+=(jacket_matrices[probe.b[j]]*probe.p)*probe.w[j]
				bounds.core=minf(bounds.core,q.y)
			for vertex in range(vertices.size()):
				var point := Vector3.ZERO
				var lf := 0.0
				var rf := 0.0
				var core := 0.0
				for influence in range(stride):
					var weight := weights[vertex*stride+influence]
					var bind := influences[vertex*stride+influence]
					point+=(matrices[bind]*vertices[vertex])*weight
					var name := sk.get_bone_name(bind_ids[bind])
					if name in ["J_Bip_L_Foot","J_Bip_L_ToeBase"]: lf+=weight
					if name in ["J_Bip_R_Foot","J_Bip_R_ToeBase"]: rf+=weight
					if name.begins_with("J_Bip_C_"): core+=weight
				bounds.body=minf(bounds.body,point.y)
				if core>.7: bounds.core=minf(bounds.core,point.y)
				if lf>.7: bounds.leftfoot=minf(bounds.leftfoot,point.y)
				if rf>.7: bounds.rightfoot=minf(bounds.rightfoot,point.y)
			row.bounds=bounds
			for name: String in NAMES:
				var p := sk.to_global(sk.get_bone_global_pose(sk.find_bone(name)).origin)
				row.bones[name]=[p.x,p.y,p.z]
			rows.append(row)
			if frame%10==0: print(clip," ",seconds," min=",bounds," hip=",row.bones.J_Bip_C_Hips," palm=",row.bones.L_Hand)
		data[clip]=rows
		for channel in ["body","core","leftfoot","rightfoot"]:
			var curve := PackedFloat32Array()
			for row: Dictionary in rows: curve.append(row.bounds[channel])
			animation.set_meta("floor_"+channel,curve)
		animation.set_meta("floor_hz",60.0)
	FileAccess.open("res://.work/motion-integration/raw-contacts.json",FileAccess.WRITE).store_string(JSON.stringify(data))
	print("MEASURED_CONTACTS ",ResourceSaver.save(library,"res://assets/animations/retargeted/quaternius-title.res",ResourceSaver.FLAG_COMPRESS))
	actor.queue_free()
	await process_frame
	quit()
