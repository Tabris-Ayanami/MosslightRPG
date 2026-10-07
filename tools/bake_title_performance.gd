extends SceneTree
const RIG=preload("res://tools/title_performance_rig.gd")
const CLOTH=preload("res://tools/title_coat_solver.gd")
const DURATION=5.4
const FPS=120.0
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var actor := RIG.new()
	root.add_child(actor)
	actor.set_process(false)
	# Constraints are measured in the undeformed bind pose, not the lying pose.
	actor.apply_pose(1)
	var coat := CLOTH.new()
	coat.setup(actor)
	actor.apply_pose(0)
	for i in range(coat.points.size()):
		coat.points[i]=coat.bone_position(coat.bones[i])
		coat.points[i].y=maxf(coat.FLOOR,coat.points[i].y)
	coat.previous=coat.points.duplicate()
	for warmup in range(300):
		actor.apply_pose(0)
		coat.step(1.0/FPS)
	var animation := Animation.new()
	animation.resource_name="RestToStand"
	animation.length=DURATION
	var position_track := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(position_track,NodePath("PerformanceHero"))
	var rotation_track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(rotation_track,NodePath("PerformanceHero"))
	var tracks := PackedInt32Array()
	var skeleton_path := str(actor.get_path_to(actor.skeleton))
	for bone in range(actor.skeleton.get_bone_count()):
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track,NodePath(skeleton_path+":"+actor.skeleton.get_bone_name(bone)))
		tracks.append(track)
	var worst_contact := 0.0
	var worst_frame := 0
	var worst_chains := {}
	for frame in range(roundi(DURATION*FPS)+1):
		var time := float(frame)/FPS
		actor.apply_pose(time/DURATION)
		coat.step(1.0/FPS)
		if actor.contact_error>worst_contact:
			worst_contact=actor.contact_error
			worst_frame=frame
			worst_chains=actor.chain_errors.duplicate()
		animation.position_track_insert_key(position_track,time,actor.hero.position)
		animation.rotation_track_insert_key(rotation_track,time,actor.hero.quaternion)
		for bone in range(actor.skeleton.get_bone_count()):
			animation.rotation_track_insert_key(tracks[bone],time,actor.skeleton.get_bone_pose_rotation(bone))
	# Remove sub-frame contact chatter from the authored cloth cache (+/-50ms window).
	# Limb/waist tracks and their planted contacts remain untouched. This is baked
	# once and is symmetric in time, so reverse playback has exactly the same drape.
	for bone in range(actor.skeleton.get_bone_count()):
		if not actor.skeleton.get_bone_name(bone).begins_with("dayi_"): continue
		var track := tracks[bone]
		var source: Array[Quaternion]=[]
		for i in range(animation.track_get_key_count(track)):
			source.append(animation.track_get_key_value(track,i))
		for i in range(source.size()):
			var sum := Vector4.ZERO
			for offset in range(-6,7):
				var q := source[clampi(i+offset,0,source.size()-1)]
				var weight := exp(-float(offset*offset)/18.0)
				if source[i].dot(q)<0: weight=-weight
				sum+=Vector4(q.x,q.y,q.z,q.w)*weight
			var q := Quaternion(sum.x,sum.y,sum.z,sum.w).normalized()
			animation.track_set_key_value(track,i,q)
	# Metadata makes regenerated clips auditable without expensive runtime solving.
	animation.set_meta("sample_hz",FPS)
	animation.set_meta("max_limb_target_error",worst_contact)
	animation.set_meta("cloth_solver","fixed-step PBD, seams/bending, torso and leg capsules, ground friction")
	DirAccess.make_dir_recursive_absolute("res://assets/ui/title")
	var error := ResourceSaver.save(animation,"res://assets/ui/title/rest-to-stand.res",ResourceSaver.FLAG_COMPRESS)
	print("TITLE BAKE ",error," duration=",DURATION," fps=",FPS," limb error=",worst_contact)
	print("WORST frame=",worst_frame," progress=",float(worst_frame)/(DURATION*FPS)," ",worst_chains)
	actor.queue_free()
	await process_frame
	quit(error)
