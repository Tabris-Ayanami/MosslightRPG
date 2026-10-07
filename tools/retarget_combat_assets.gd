extends SceneTree
## Bake existing, verified CC0 Quaternius Standard combat clips onto Kirito.
## Only root/hips positions are retargeted; limb lengths and skin stay unchanged.
const VISUAL=preload("res://scripts/kirito_visual.gd")
const SOURCE2="res://source_assets/animations/quaternius_ual2/Universal Animation Library 2 [Standard]/Unreal-Godot/UAL2_Standard.glb"
const SOURCE1="res://source_assets/animations/quaternius_ual1/AnimationLibrary_Godot_Standard.glb"
const OUT="res://assets/animations/retargeted/"
var mapping={"Root":"root","J_Bip_C_Hips":"pelvis","J_Bip_C_Spine":"spine_01","J_Bip_C_Chest":"spine_02","J_Bip_C_UpperChest":"spine_03","J_Bip_C_Neck":"neck_01","J_Bip_C_Head":"Head"}
func _initialize() -> void: call_deferred("run")
func descendants(node: Node, kind: String) -> Node:
	if node.is_class(kind): return node
	for child in node.get_children():
		var found := descendants(child,kind)
		if found: return found
	return null
func load_source(path: String) -> Node3D:
	var state := GLTFState.new()
	var document := GLTFDocument.new()
	var error := document.append_from_file(path,state)
	assert(error==OK,"Cannot parse source GLB")
	return document.generate_scene(state)
func world_bone(sk: Skeleton3D, name: String) -> Transform3D:
	return sk.global_transform*sk.get_bone_global_pose(sk.find_bone(name))
func anatomical_frame(sk: Skeleton3D, hips: String, head: String, left: String, right: String) -> Basis:
	var x := (world_bone(sk,left).origin-world_bone(sk,right).origin).normalized()
	var y := (world_bone(sk,head).origin-world_bone(sk,hips).origin).normalized()
	var z := x.cross(y).normalized()
	return Basis(y.cross(z).normalized(),y,z).orthonormalized()
func legacy_names() -> Dictionary:
	var names={"root":"root","pelvis":"DEF-hips","spine_01":"DEF-spine.001","spine_02":"DEF-spine.002","spine_03":"DEF-spine.003","neck_01":"DEF-neck","Head":"DEF-head"}
	for side: String in ["l","r"]:
		for part: String in {"clavicle":"shoulder","upperarm":"upper_arm","lowerarm":"forearm","hand":"hand","thigh":"thigh","calf":"shin","foot":"foot","ball":"toe"}:
			names[part+"_"+side]="DEF-"+{"clavicle":"shoulder","upperarm":"upper_arm","lowerarm":"forearm","hand":"hand","thigh":"thigh","calf":"shin","foot":"foot","ball":"toe"}[part]+"."+side.to_upper()
		for finger: String in ["index","middle","pinky","ring","thumb"]:
			for joint in range(1,4): names[finger+"_0"+str(joint)+"_"+side]="DEF-"+("f_" if finger!="thumb" else "")+finger+".0"+str(joint)+"."+side.to_upper()
	return names

func soften_sampling_spikes(animation: Animation) -> void:
	# Short symmetric filtering removes angular sampling spikes without changing
	# clip duration or limb lengths. Contacts are measured/corrected afterwards.
	var kernel := [1.0,4.0,6.0,4.0,1.0]
	var looping := animation.loop_mode==Animation.LOOP_LINEAR
	for track in range(animation.get_track_count()):
		var values := []
		for key in range(animation.track_get_key_count(track)): values.append(animation.track_get_key_value(track,key))
		var last := values.size()-1
		for key in range(values.size()):
			if not looping and key in [0,last]: continue
			if animation.track_get_type(track)==Animation.TYPE_ROTATION_3D:
				var reference: Quaternion=values[key]
				var sum := Vector4.ZERO
				for j in range(5):
					var at := posmod(key+j-2,last) if looping else clampi(key+j-2,0,last)
					var q: Quaternion=values[at]
					var weight: float=kernel[j]*(1.0 if reference.dot(q)>=0 else -1.0)
					sum+=Vector4(q.x,q.y,q.z,q.w)*weight
				sum=sum.normalized()
				animation.track_set_key_value(track,key,Quaternion(sum.x,sum.y,sum.z,sum.w))
			elif animation.track_get_type(track)==Animation.TYPE_POSITION_3D:
				var sum := Vector3.ZERO
				for j in range(5):
					var at := posmod(key+j-2,last) if looping else clampi(key+j-2,0,last)
					sum+=values[at]*kernel[j]/16.0
				animation.track_set_key_value(track,key,sum)
	animation.set_meta("angular_cleanup","5-tap symmetric filter at 60 Hz; non-loop endpoints preserved")
func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for side in ["L","R"]:
		for part in {"Shoulder":"clavicle","UpperArm":"upperarm","LowerArm":"lowerarm","Hand":"hand","UpperLeg":"thigh","LowerLeg":"calf","Foot":"foot","ToeBase":"ball"}:
			var target: String="L_Hand" if side=="L" and part=="Hand" else "J_Bip_"+side+"_"+part
			mapping[target]={"Shoulder":"clavicle","UpperArm":"upperarm","LowerArm":"lowerarm","Hand":"hand","UpperLeg":"thigh","LowerLeg":"calf","Foot":"foot","ToeBase":"ball"}[part]+"_"+side.to_lower()
		for finger in {"Index":"index","Middle":"middle","Ring":"ring","Little":"pinky","Thumb":"thumb"}:
			for joint in range(1,4): mapping["J_Bip_"+side+"_"+finger+str(joint)]={"Index":"index","Middle":"middle","Ring":"ring","Little":"pinky","Thumb":"thumb"}[finger]+"_0"+str(joint)+"_"+side.to_lower()
	var actor := Node3D.new()
	root.add_child(actor)
	var hero=VISUAL.new()
	hero.name="KiritoBody"
	actor.add_child(hero)
	hero.rotation.y=0
	hero.scale=Vector3.ONE
	hero.animator.stop()
	hero.animator.active=false
	var target: Skeleton3D=hero.skeleton
	var library := AnimationLibrary.new()
	for spec in [[SOURCE2,{"Idle_Shield_Loop":"ShieldGuard","Shield_OneShot":"ShieldRaise","Idle_Shield_Break":"ShieldBreak","Hit_Knockback":"Stagger","TreeChopping_Loop":"HeavyChop","Sword_Regular_A":"SwordAlt","Sword_Regular_B":"SwordB","Sword_Regular_C":"SwordC","Sword_Regular_A_Rec":"SwordARecovery","Sword_Regular_B_Rec":"SwordBRecovery"}],[SOURCE1,{"Idle_Loop":"Idle","Jog_Fwd_Loop":"Run","Sprint_Loop":"Sprint","Roll":"Roll","Hit_Chest":"Hit","Death01":"Death","Sword_Idle":"SwordIdle","Sword_Attack":"SwordSlash","Spell_Simple_Idle_Loop":"CastIdle","Spell_Simple_Shoot":"Cast"}]]:
		var source := load_source(spec[0])
		root.add_child(source)
		var sk: Skeleton3D=descendants(source,"Skeleton3D")
		var animator: AnimationPlayer=descendants(source,"AnimationPlayer")
		if sk.find_bone("pelvis")<0:
			var aliases := legacy_names()
			for name: String in mapping: mapping[name]=aliases[mapping[name]]
		print("SOURCE clips=",animator.get_animation_list())
		animator.play("A_TPose")
		animator.seek(0,true)
		animator.pause()
		target.reset_bone_poses()
		var source_frame := anatomical_frame(sk,mapping.J_Bip_C_Hips,mapping.J_Bip_C_Head,mapping.J_Bip_L_UpperArm,mapping.J_Bip_R_UpperArm)
		var target_frame := anatomical_frame(target,"J_Bip_C_Hips","J_Bip_C_Head","J_Bip_L_UpperArm","J_Bip_R_UpperArm")
		var alignment := target_frame*source_frame.inverse()
		var sr := {}
		var tr := {}
		for name: String in mapping:
			assert(target.find_bone(name)>=0 and sk.find_bone(mapping[name])>=0,"Missing mapped bone: "+name)
			sr[name]=world_bone(sk,mapping[name])
			tr[name]=world_bone(target,name)
		var source_leg: float=sr.J_Bip_C_Hips.origin.distance_to(sr.J_Bip_L_Foot.origin)
		var target_leg: float=tr.J_Bip_C_Hips.origin.distance_to(tr.J_Bip_L_Foot.origin)
		var ratio := target_leg/source_leg
		print("RETARGET mapped=",mapping.size()," leg_scale=",ratio," source_hip=",sr.J_Bip_C_Hips.origin," target_hip=",tr.J_Bip_C_Hips.origin)
		for clip: String in spec[1]:
			var original := animator.get_animation(clip)
			var animation := Animation.new()
			animation.length=original.length
			animation.loop_mode=Animation.LOOP_LINEAR if clip.ends_with("Loop") else Animation.LOOP_NONE
			var tracks := {}
			for bone in range(target.get_bone_count()):
				var name := target.get_bone_name(bone)
				if not mapping.has(name): continue
				var track := animation.add_track(Animation.TYPE_ROTATION_3D)
				animation.track_set_path(track,NodePath(str(actor.get_path_to(target))+":"+name))
				tracks[name]=track
			var position_track := animation.add_track(Animation.TYPE_POSITION_3D)
			animation.track_set_path(position_track,NodePath(str(actor.get_path_to(target))+":J_Bip_C_Hips"))
			animator.play(clip)
			animator.pause()
			var frames := roundi(original.length*60)
			for frame in range(frames+1):
				var time := original.length*float(frame)/frames
				animator.seek(time,true)
				target.reset_bone_poses()
				for bone in range(target.get_bone_count()):
					var name := target.get_bone_name(bone)
					if not mapping.has(name): continue
					var parent := target.get_bone_parent(bone)
					var parent_world := target.global_transform
					if parent>=0: parent_world*=target.get_bone_global_pose(parent)
					var source_pose := world_bone(sk,mapping[name])
					var delta: Basis=alignment*source_pose.basis.orthonormalized()*sr[name].basis.orthonormalized().inverse()*alignment.inverse()
					var desired: Basis=delta*tr[name].basis.orthonormalized()
					var local_rotation := (parent_world.basis.orthonormalized().inverse()*desired).get_rotation_quaternion()
					target.set_bone_pose_rotation(bone,local_rotation)
					animation.rotation_track_insert_key(tracks[name],time,local_rotation)
					if name=="J_Bip_C_Hips":
						var desired_position: Vector3=tr[name].origin+alignment*(source_pose.origin-sr[name].origin)*ratio
						var local_position := parent_world.affine_inverse()*desired_position
						# Gameplay exclusively owns translation; retain only local hip sway.
						var rest_position: Vector3 = target.get_bone_rest(bone).origin
						local_position.x = clampf(local_position.x, rest_position.x - .12, rest_position.x + .12)
						local_position.z = clampf(local_position.z, rest_position.z - .12, rest_position.z + .12)
						target.set_bone_pose_position(bone,local_position)
						animation.position_track_insert_key(position_track,time,local_position)
			soften_sampling_spikes(animation)
			animation.set_meta("author","Quaternius")
			animation.set_meta("source_clip",clip)
			animation.set_meta("license","CC0-1.0")
			library.add_animation(spec[1][clip],animation)
			print("BAKED ",spec[1][clip]," duration=",animation.length," keys=",frames+1)
		source.queue_free()
		await process_frame
	var error := ResourceSaver.save(library,OUT+"quaternius-combat.res",ResourceSaver.FLAG_COMPRESS)
	print("RETARGET_SAVE ",error)
	actor.queue_free()
	for i in range(4): await process_frame
	quit(error)

