extends "res://tools/retarget_combat_assets.gd"
## Deterministic KayKit retarget. Preserve target rest lengths and gameplay translation.
func run() -> void:
	mapping = {"Root":"root", "J_Bip_C_Hips":"hips", "J_Bip_C_Spine":"spine", "J_Bip_C_Chest":"chest", "J_Bip_C_UpperChest":"chest", "J_Bip_C_Head":"head"}
	for side in ["L", "R"]:
		for part in {"UpperArm":"upperarm", "LowerArm":"lowerarm", "Hand":"hand", "UpperLeg":"upperleg", "LowerLeg":"lowerleg", "Foot":"foot", "ToeBase":"toes"}:
			var target_name: String = "L_Hand" if side == "L" and part == "Hand" else "J_Bip_" + side + "_" + part
			mapping[target_name] = {"UpperArm":"upperarm", "LowerArm":"lowerarm", "Hand":"hand", "UpperLeg":"upperleg", "LowerLeg":"lowerleg", "Foot":"foot", "ToeBase":"toes"}[part] + "." + side.to_lower()
	var actor := Node3D.new()
	root.add_child(actor)
	var hero = VISUAL.new()
	hero.name = "KiritoBody"
	actor.add_child(hero)
	hero.rotation.y = 0
	hero.scale = Vector3.ONE
	hero.animator.stop()
	hero.animator.active = false
	var target: Skeleton3D = hero.skeleton
	var source := load_source("res://source_assets/animations/kaykit_adventurers/Knight.glb")
	root.add_child(source)
	var sk: Skeleton3D = descendants(source, "Skeleton3D")
	var player: AnimationPlayer = descendants(source, "AnimationPlayer")
	player.play("T-Pose"); player.seek(0, true); player.pause()
	target.reset_bone_poses()
	var alignment := anatomical_frame(target,"J_Bip_C_Hips","J_Bip_C_Head","J_Bip_L_UpperArm","J_Bip_R_UpperArm") * anatomical_frame(sk,"hips","head","upperarm.l","upperarm.r").inverse()
	# Source swords run along +Y below handslot.r; our weapons run along -Z.
	# Runtime multiplies a skeleton-local rest basis by the animated WORLD hand.
	# Convert the authored world rest axis into that same skeleton space first.
	var weapon_rest := target.global_basis.orthonormalized().inverse() * alignment * world_bone(sk,"handslot.r").basis.orthonormalized() * Basis(Vector3.LEFT,Vector3.FORWARD,Vector3.DOWN)
	var sr := {}; var tr := {}
	for name: String in mapping:
		assert(target.find_bone(name) >= 0 and sk.find_bone(mapping[name]) >= 0, "Missing bone " + name)
		sr[name] = world_bone(sk, mapping[name]); tr[name] = world_bone(target, name)
	var ratio: float = tr.J_Bip_C_Hips.origin.distance_to(tr.J_Bip_L_Foot.origin) / sr.J_Bip_C_Hips.origin.distance_to(sr.J_Bip_L_Foot.origin)
	var clips := {"1H_Melee_Attack_Slice_Diagonal":"KnifeDiagonal", "1H_Melee_Attack_Slice_Horizontal":"KnifeReturn", "1H_Melee_Attack_Stab":"KnifeStab", "1H_Melee_Attack_Chop":"KnifeChop", "2H_Melee_Attack_Slice":"TwoHandSlice", "2H_Melee_Attack_Chop":"TwoHandChop", "2H_Melee_Attack_Stab":"TwoHandStab", "2H_Melee_Attack_Spin":"TwoHandSpin", "2H_Melee_Idle":"TwoHandIdle"}
	var grip_player := AnimationPlayer.new()
	actor.add_child(grip_player)
	grip_player.add_animation_library("grip",load("res://assets/animations/retargeted/quaternius-combat.res"))
	grip_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var library := AnimationLibrary.new()
	for clip: String in clips:
		target.reset_bone_poses()
		grip_player.play("grip/HeavyChop" if clip.begins_with("2H") else "grip/SwordAlt")
		grip_player.seek(.15,true);grip_player.pause()
		var fingers := {}
		for bone in range(target.get_bone_count()):
			var name := target.get_bone_name(bone)
			if "Index" in name or "Middle" in name or "Ring" in name or "Little" in name or "Thumb" in name:
				fingers[name] = target.get_bone_pose_rotation(bone)
		var original := player.get_animation(clip)
		var animation := Animation.new()
		animation.length = original.length
		var tracks := {}
		for bone in range(target.get_bone_count()):
			var name := target.get_bone_name(bone)
			if not mapping.has(name): continue
			var track := animation.add_track(Animation.TYPE_ROTATION_3D)
			animation.track_set_path(track, NodePath(str(actor.get_path_to(target)) + ":" + name))
			tracks[name] = track
		for name: String in fingers:
			var track := animation.add_track(Animation.TYPE_ROTATION_3D)
			animation.track_set_path(track,NodePath(str(actor.get_path_to(target))+":"+name))
			animation.rotation_track_insert_key(track,0.0,fingers[name])
			animation.rotation_track_insert_key(track,animation.length,fingers[name])
		var hip_track := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(hip_track,NodePath(str(actor.get_path_to(target))+":J_Bip_C_Hips"))
		player.play(clip); player.pause()
		var frames := roundi(original.length * 60)
		for frame in range(frames + 1):
			var time := original.length * float(frame) / frames
			player.seek(time, true)
			target.reset_bone_poses()
			for bone in range(target.get_bone_count()):
				var name := target.get_bone_name(bone)
				if not mapping.has(name): continue
				var parent := target.get_bone_parent(bone)
				var parent_world := target.global_transform
				if parent >= 0: parent_world *= target.get_bone_global_pose(parent)
				var source_pose := world_bone(sk,mapping[name])
				var delta: Basis = alignment * source_pose.basis.orthonormalized() * sr[name].basis.orthonormalized().inverse() * alignment.inverse()
				var desired: Basis = delta * tr[name].basis.orthonormalized()
				var local_rotation := (parent_world.basis.orthonormalized().inverse() * desired).get_rotation_quaternion()
				target.set_bone_pose_rotation(bone, local_rotation)
				animation.rotation_track_insert_key(tracks[name], time, local_rotation)
				if name == "J_Bip_C_Hips":
					var desired_position: Vector3 = tr[name].origin + alignment * (source_pose.origin - sr[name].origin) * ratio
					var position := parent_world.affine_inverse() * desired_position
					var rest := target.get_bone_rest(bone).origin
					position.x = clampf(position.x,rest.x-.12,rest.x+.12)
					position.z = clampf(position.z,rest.z-.12,rest.z+.12)
					target.set_bone_pose_position(bone,position)
					animation.position_track_insert_key(hip_track,time,position)
			# Aim the narrow stab/chop through the forward target instead of beside it.
			var yaw: float = {"KnifeStab":.30,"KnifeChop":.47,"TwoHandChop":.30}.get(clips[clip],0.0)
			var weight := smoothstep(0.0,.15,time) * (1.0-smoothstep(original.length-.15,original.length,time))
			var root_rotation := Quaternion(Vector3.UP,yaw*weight) * target.get_bone_pose_rotation(target.find_bone("Root"))
			animation.track_set_key_value(tracks.Root,frame,root_rotation)
		soften_sampling_spikes(animation)
		animation.set_meta("author","Kay Lousberg")
		animation.set_meta("license","CC0-1.0")
		animation.set_meta("source_clip",clip)
		animation.set_meta("weapon_rest_basis",weapon_rest)
		library.add_animation(clips[clip], animation)
		print("FAMILY_CLIP ",clips[clip]," ",original.length)
	var result := ResourceSaver.save(library,"res://assets/animations/retargeted/kaykit-family.res",ResourceSaver.FLAG_COMPRESS)
	source.queue_free(); actor.queue_free()
	for _i in range(4): await process_frame
	print("FAMILY_BAKE ",JSON.stringify({"ok":result == OK,"clips":library.get_animation_list().size(),"mapped_bones":mapping.size()}))
	quit(result)
