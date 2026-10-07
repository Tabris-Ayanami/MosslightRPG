extends Node3D
## Offline assembly of Quaternius clips with an authored hands-behind-head rest.
## Rest offsets release into the source get-up; IK keeps contacts and prop handling.
const VISUAL=preload("res://scripts/kirito_visual.gd")
const LIBRARY=preload("res://assets/animations/retargeted/quaternius-title.res")
const STORY=preload("res://scripts/frontend/title_story.gd")
const FLOOR := .025
var hero: Node3D
var skeleton: Skeleton3D
var contact_error := 0.0
var chain_errors := {}
var rest_rotations: Array[Quaternion]=[]
var tracks := {}
var hips := -1
var rise := 0.0
var idle_feet: Array[Vector3]=[]
var idle_foot_rotations: Array[Quaternion]=[]
var resting_offsets: Dictionary={}
var back_grip: Vector3
var back_tip: Vector3
var contact_targets := {}
var sole_vertices: Array=[]
var skin_bindings: Array=[]
var skin: Skin
var body_arrays: Array

func _ready() -> void:
	hero=VISUAL.new()
	hero.name="PerformanceHero"
	add_child(hero)
	hero.scale=Vector3.ONE*1.78
	hero.rotation.y=PI
	skeleton=hero.skeleton
	hero.animator.stop()
	hero.animator.active=false
	skeleton.reset_bone_poses()
	hips=skeleton.find_bone("J_Bip_C_Hips")
	for bone in range(skeleton.get_bone_count()): rest_rotations.append(skeleton.get_bone_pose_rotation(bone))
	for clip: String in LIBRARY.get_animation_list():
		var animation := LIBRARY.get_animation(clip)
		var entries := []
		for track in range(animation.get_track_count()):
			entries.append([track,skeleton.find_bone(animation.track_get_path(track).get_subname(0)),animation.track_get_type(track)])
		tracks[clip]=entries
	_build_sole_clouds()
	_install(_sample("Idle",0))
	_ground_base()
	for side: String in ["L","R"]:
		var foot := "J_Bip_"+side+"_Foot"
		var goal := point(foot)+Vector3.UP*(FLOOR-_sole_min(side))
		_leg(side,goal)
		idle_feet.append(point(foot))
		idle_foot_rotations.append(frame(foot).basis.orthonormalized().get_rotation_quaternion())
	var chest := frame("J_Bip_C_Chest")
	back_grip=chest.affine_inverse()*STORY.BACK_GRIP
	back_tip=chest.affine_inverse()*STORY.BACK_TIP
	_build_rest_pose()
	apply_time(0)

func frame(name: String) -> Transform3D:
	return global_transform.affine_inverse()*skeleton.global_transform*skeleton.get_bone_global_pose(skeleton.find_bone(name))
func point(name: String) -> Vector3: return frame(name).origin

func _sample(clip: String, time: float) -> Dictionary:
	var animation := LIBRARY.get_animation(clip)
	var t := clampf(time,0,animation.length)
	if animation.loop_mode==Animation.LOOP_LINEAR: t=fposmod(time,animation.length)
	var rotations := rest_rotations.duplicate()
	var position := skeleton.get_bone_rest(hips).origin
	for entry: Array in tracks[clip]:
		if entry[2]==Animation.TYPE_ROTATION_3D: rotations[entry[1]]=animation.rotation_track_interpolate(entry[0],t)
		elif entry[2]==Animation.TYPE_POSITION_3D: position=animation.position_track_interpolate(entry[0],t)
	var curve: PackedFloat32Array=animation.get_meta("floor_core" if clip=="GetUp" else "floor_body")
	var f := minf(t*float(animation.get_meta("floor_hz")),curve.size()-1)
	var i := mini(floori(f),curve.size()-2)
	var floor_height := lerpf(curve[i],curve[i+1],f-i)
	if clip=="GetUp": floor_height=minf(floor_height,FLOOR-.055)
	return {"rotations":rotations,"hips":position,"floor":floor_height}

func _blend(a: Dictionary, b: Dictionary, weight: float) -> Dictionary:
	for bone in range(a.rotations.size()): a.rotations[bone]=a.rotations[bone].slerp(b.rotations[bone],weight)
	a.hips=a.hips.lerp(b.hips,weight)
	a.floor=lerpf(a.floor,b.floor,weight)
	return a

func _install(pose: Dictionary) -> void:
	hero.position=Vector3.ZERO
	hero.rotation=Vector3(0,PI,0)
	for bone in range(skeleton.get_bone_count()): skeleton.set_bone_pose_rotation(bone,pose.rotations[bone])
	skeleton.set_bone_pose_position(hips,pose.hips)
	hero.position.y=FLOOR-pose.floor

func _build_sole_clouds() -> void:
	var body: MeshInstance3D=hero.find_child("body_low",true,false)
	body_arrays=body.mesh.surface_get_arrays(0)
	skin=body.skin
	for bind in range(skin.get_bind_count()): skin_bindings.append(skeleton.find_bone(skin.get_bind_name(bind)))
	var vertices: PackedVector3Array=body_arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array=body_arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array=body_arrays[Mesh.ARRAY_WEIGHTS]
	var stride := weights.size()/vertices.size()
	for side: String in ["L","R"]:
		var ids := PackedInt32Array()
		for vertex in range(vertices.size()):
			var weight := 0.0
			for j in range(stride):
				var name := skeleton.get_bone_name(skin_bindings[bones[vertex*stride+j]])
				if name in ["J_Bip_"+side+"_Foot","J_Bip_"+side+"_ToeBase"]: weight+=weights[vertex*stride+j]
			if weight>.7: ids.append(vertex)
		sole_vertices.append(ids)

func _sole_min(side: String) -> float:
	var matrices := []
	for bind in range(skin.get_bind_count()):
		matrices.append(global_transform.affine_inverse()*skeleton.global_transform*skeleton.get_bone_global_pose(skin_bindings[bind])*skin.get_bind_pose(bind))
	var vertices: PackedVector3Array=body_arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array=body_arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array=body_arrays[Mesh.ARRAY_WEIGHTS]
	var stride := weights.size()/vertices.size()
	var minimum := 100.0
	for id: int in sole_vertices[0 if side=="L" else 1]:
		var p := Vector3.ZERO
		for j in range(stride): p+=(matrices[bones[id*stride+j]]*vertices[id])*weights[id*stride+j]
		minimum=minf(minimum,p.y)
	return minimum

func _ground_base() -> void:
	# Evaluate the blended shoe geometry as well as the source pose's floor curve.
	hero.position.y+=maxf(0,FLOOR-minf(_sole_min("L"),_sole_min("R")))

func _aim(bone: int, child: int, goal: Vector3) -> void:
	var pose := skeleton.get_bone_global_pose(bone)
	var a := (skeleton.get_bone_global_pose(child).origin-pose.origin).normalized()
	var b := (goal-pose.origin).normalized()
	var parent := skeleton.get_bone_parent(bone)
	var parent_basis := skeleton.get_bone_global_pose(parent).basis if parent>=0 else Basis.IDENTITY
	skeleton.set_bone_pose_rotation(bone,(parent_basis.inverse()*Basis(Quaternion(a,b))*pose.basis).orthonormalized().get_rotation_quaternion())

func _chain(upper_name: String, lower_name: String, end_name: String, goal: Vector3, pole: Vector3) -> void:
	var upper := skeleton.find_bone(upper_name)
	var lower := skeleton.find_bone(lower_name)
	var end := skeleton.find_bone(end_name)
	var end_basis := skeleton.get_bone_global_pose(end).basis
	var start := skeleton.get_bone_global_pose(upper).origin
	var joint := skeleton.get_bone_global_pose(lower).origin
	var finish := skeleton.get_bone_global_pose(end).origin
	var target := skeleton.to_local(to_global(goal))
	var a := start.distance_to(joint)
	var b := joint.distance_to(finish)
	var direction := (target-start).normalized()
	var distance := clampf(start.distance_to(target),absf(a-b)+.001,a+b-.001)
	var along := (a*a-b*b+distance*distance)/(2*distance)
	var bend := skeleton.to_local(to_global(pole))-start
	bend=(bend-direction*bend.dot(direction)).normalized()
	var knee := start+direction*along+bend*sqrt(maxf(0,a*a-along*along))
	_aim(upper,lower,knee)
	_aim(lower,end,target)
	# Keep the source foot roll / palm orientation when correcting its position.
	var parent := skeleton.get_bone_parent(end)
	skeleton.set_bone_pose_rotation(end,(skeleton.get_bone_global_pose(parent).basis.inverse()*end_basis).orthonormalized().get_rotation_quaternion())
	var error := point(end_name).distance_to(goal)
	contact_error=maxf(contact_error,error)
	chain_errors[end_name]=error
	contact_targets[end_name]=goal

func _leg(side: String, goal: Vector3) -> void:
	_chain("J_Bip_"+side+"_UpperLeg","J_Bip_"+side+"_LowerLeg","J_Bip_"+side+"_Foot",goal,point("J_Bip_"+side+"_LowerLeg"))

func _world_bone_turn(name: String, rotation: Basis) -> void:
	var bone := skeleton.find_bone(name)
	var parent := skeleton.get_bone_parent(bone)
	var desired := skeleton.global_basis.inverse()*global_basis*rotation*frame(name).basis
	skeleton.set_bone_pose_rotation(bone,(skeleton.get_bone_global_pose(parent).basis.inverse()*desired).orthonormalized().get_rotation_quaternion())

func _world_bone_orientation(name: String, orientation: Quaternion, weight: float) -> void:
	var current := frame(name).basis.orthonormalized()
	var desired := Basis(current.get_rotation_quaternion().slerp(orientation,weight))
	_world_bone_turn(name,desired*current.inverse())

func _build_rest_pose() -> void:
	# Solve the authored pose once, then release fixed local rotation offsets.
	# Re-solving a moving elbow pole can cross a singularity and flip the wrist.
	var source := _sample("GetUp",0)
	_install(source)
	var head := point("J_Bip_C_Head")
	var changed: Array[String]=[]
	for side: String in ["L","R"]:
		var sign_x := 1.0 if side=="L" else -1.0
		var upper := "J_Bip_"+side+"_UpperArm"
		var lower := "J_Bip_"+side+"_LowerArm"
		var hand := "L_Hand" if side=="L" else "J_Bip_R_Hand"
		_chain(upper,lower,hand,head+Vector3(sign_x*.17,-.115,-.12),head+Vector3(sign_x*.90,-.045,.02))
		var fingers := Vector3(-sign_x*.9,0,-.44).normalized()
		var palm := Vector3.UP*sign_x
		_world_bone_orientation(hand,Basis(fingers.cross(palm),fingers,palm).get_rotation_quaternion(),1)
		changed.append_array([upper,lower,hand])
	# Left leg keeps the source's relaxed extension. Right heel slides closer to
	# the pelvis, knee upward and slightly outward, with the sole on the grass.
	_chain("J_Bip_R_UpperLeg","J_Bip_R_LowerLeg","J_Bip_R_Foot",Vector3(-.37,.16,.78),Vector3(-.47,1.15,.35))
	_world_bone_orientation("J_Bip_R_Foot",idle_foot_rotations[1],1)
	changed.append_array(["J_Bip_R_UpperLeg","J_Bip_R_LowerLeg","J_Bip_R_Foot"])
	for name: String in changed:
		var index := skeleton.find_bone(name)
		var leg := name.contains("Leg") or name.ends_with("Foot")
		# The supporting left hand releases first; the free right arm follows.
		var release_end := .48 if leg else (.34 if name.contains("_L_") or name=="L_Hand" else .42)
		resting_offsets[index]={"rotation":source.rotations[index].inverse()*skeleton.get_bone_pose_rotation(index),"start":.10 if leg else 0.0,"end":release_end}

func _resting_pose(native: float) -> void:
	for bone: int in resting_offsets:
		var entry: Dictionary=resting_offsets[bone]
		var weight := 1.0-smoothstep(entry.start,entry.end,native)
		if weight>0:
			# Fade a single fixed offset so no changing pair of poses can switch
			# quaternion hemispheres halfway through the release.
			skeleton.set_bone_pose_rotation(bone,skeleton.get_bone_pose_rotation(bone)*Quaternion.IDENTITY.slerp(entry.rotation,weight))

func apply_pose(progress: float) -> void: apply_time(progress*STORY.RISE_END)

func apply_time(seconds: float) -> void:
	var time := clampf(seconds,0,STORY.END)
	rise=clampf(time/STORY.RISE_END,0,1)
	contact_error=0
	chain_errors.clear()
	contact_targets.clear()
	var native := STORY.getup_time(time)
	var idle_time := maxf(0,time-(STORY.RISE_START+STORY.GETUP_DURATION))
	var pose := _sample("GetUp",native)
	if time>STORY.RISE_START+STORY.GETUP_DURATION:
		pose=_blend(pose,_sample("Idle",idle_time),smoothstep(0,.5,idle_time))
	var distance := STORY.distance_at(time)
	var walk_time := maxf(0,time-STORY.CHOICE_TIME)
	var walk_weight := smoothstep(0,.65,walk_time)
	# Enter the loop at its early support phase: the front foot then matches the
	# staggered idle stance instead of asking a planted leg to span another 26 cm.
	var cycle := distance/STORY.WALK_STRIDE+.10
	if walk_time>0: pose=_blend(pose,_sample("Walk",cycle*LIBRARY.get_animation("Walk").length),walk_weight)
	_install(pose)
	_resting_pose(native)
	if time>STORY.RISE_END: _ground_base()
	if time<=STORY.RISE_END:
		var sole_lift := maxf(0,FLOOR-minf(_sole_min("L"),_sole_min("R")))
		for side: String in ["L","R"]:
			var weight := 1.0
			if side=="R": weight=1-smoothstep(.98,1.15,native)+smoothstep(1.26,1.49,native)
			var height := _sole_min(side)+sole_lift
			var goal := point("J_Bip_"+side+"_Foot")+Vector3.UP*(sole_lift+(FLOOR-height)*weight)
			_leg(side,goal)
		# The source plants its left palm, then releases it to rise. Use that contact
		# interval to pick up the sword beside him, without inventing a new get-up.
		var contact := smoothstep(.14,.34,native)*(1-smoothstep(STORY.PICKUP_NATIVE_TIME,.70,native))
		var hand := point("L_Hand")
		if contact>.0001: _chain("J_Bip_L_UpperArm","J_Bip_L_LowerArm","L_Hand",hand.lerp(STORY.GROUND_GRIP,contact),point("J_Bip_L_LowerArm"))
		return
	var p := STORY.prepare(time)
	var yaw := STORY.yaw_at(time)
	var turn := Basis(Vector3.UP,yaw)
	hero.position=turn*hero.position+STORY.FACING*distance
	hero.rotation.y=PI+yaw
	for side_index in range(2):
		var side := "L" if side_index==0 else "R"
		var foot := "J_Bip_"+side+"_Foot"
		if walk_time<=0:
			var step := smoothstep(.06,.42,p) if side_index==0 else smoothstep(.32,.78,p)
			var step_turn := Basis(Vector3.UP,STORY.YAW*step)
			var goal := step_turn*idle_feet[side_index]+Vector3.UP*(.10*sin(step*PI))
			_world_bone_turn(foot,Basis(Vector3.UP,STORY.YAW*step-yaw))
			_leg(side,goal)
		else:
			var raw := point(foot)
			var phase := fposmod(cycle-(.5 if side_index==1 else 0),1)
			var support := (1-smoothstep(.29,.43,phase))*smoothstep(.0,.035,phase)
			var anchor := Vector3(.128 if side_index==0 else -.128,0,.510 if side_index==0 else .525)
			anchor.z+=(floorf(cycle-(.5 if side_index==1 else 0))+(.5 if side_index==1 else 0)-.10)*STORY.WALK_STRIDE
			if side_index==0 and cycle<.43: anchor=idle_feet[0]
			if side_index==1 and cycle<.5: support=0
			var goal := raw.lerp(turn*anchor,support)
			goal.y=raw.y+(FLOOR-_sole_min(side))*support
			_leg(side,goal)
	# An additive reach handles the back-mounted prop. Its socket follows the
	# animated chest, so transfer to the back preserves one continuous transform.
	var head_weight := smoothstep(.70,1,p)*(1-smoothstep(0,.55,walk_time))
	_world_bone_turn("J_Bip_C_Head",turn*Basis(Vector3.RIGHT,deg_to_rad(-10)*head_weight)*turn.inverse())
	if time<STORY.PREPARE_END:
		var reach := STORY.sample(STORY.SHEATHE,p)
		var raw_hand := point("L_Hand")
		var socket := frame("J_Bip_C_Chest")*back_grip
		var socket_weight := smoothstep(.44,.61,p)*(1-smoothstep(.72,.90,p))
		var reach_weight := smoothstep(0,.12,p)*(1-smoothstep(.90,1,p))
		var goal := raw_hand.lerp((turn*reach).lerp(socket,socket_weight),reach_weight)
		var guide := turn*Vector3(.95,2.05,.40)
		var pole := point("J_Bip_L_LowerArm").lerp(guide,smoothstep(0,.2,p)*reach_weight)
		_chain("J_Bip_L_UpperArm","J_Bip_L_LowerArm","L_Hand",goal,pole)
