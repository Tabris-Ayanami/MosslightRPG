extends RefCounted
## Offline fixed-step PBD on the imported coat rig. Waist anchors, inextensible
## seams, bending and neighbouring-panel constraints, capsule and floor contacts.
## Playback uses the baked result; never run a history-dependent sim when seeking.
var rig: Node3D
var points := PackedVector3Array()
var previous := PackedVector3Array()
var bones := PackedInt32Array()
var pinned := PackedByteArray()
var chains: Array[PackedInt32Array]=[]
var constraints: Array[Vector4]=[]
var capsules: Array=[]
const FLOOR := .055
const ORDER := [0,1,7,2,3,4,5,8,6]

func setup(actor: Node3D) -> void:
	rig=actor
	for bone_chain: PackedInt32Array in rig.coat_chains:
		var particle_chain := PackedInt32Array()
		for j in range(bone_chain.size()):
			var bone := bone_chain[j]
			particle_chain.append(points.size())
			bones.append(bone)
			points.append(bone_position(bone))
			pinned.append(1 if j==0 else 0)
		chains.append(particle_chain)
	previous=points.duplicate()
	for chain in chains:
		for j in range(chain.size()-1): add_constraint(chain[j],chain[j+1],1.0)
		for j in range(chain.size()-2): add_constraint(chain[j],chain[j+2],.065)
	# The front of Kirito's coat is open. Connect panels around the back and sides,
	# but never stitch the two front flaps together across his legs.
	for k in range(ORDER.size()):
		if k==4: continue
		var left := chains[ORDER[k]]
		var right := chains[ORDER[(k+1)%ORDER.size()]]
		for j in range(1,left.size()):
			var closest := 1
			for other in range(1,right.size()):
				if absf(points[left[j]].y-points[right[other]].y)<absf(points[left[j]].y-points[right[closest]].y): closest=other
			add_constraint(left[j],right[closest],.55)
			add_constraint(left[j-1],right[closest],.12)

func bone_position(bone: int) -> Vector3:
	return rig.to_local(rig.skeleton.to_global(rig.skeleton.get_bone_global_pose(bone).origin))

func named_position(name: String) -> Vector3:
	return bone_position(rig.skeleton.find_bone(name))

func add_constraint(a: int, b: int, strength: float) -> void:
	constraints.append(Vector4(a,b,points[a].distance_to(points[b]),strength))

func update_capsules() -> void:
	capsules.clear()
	var hip := named_position("J_Bip_C_Hips")
	var chest := named_position("J_Bip_C_Chest")
	capsules.append([hip,chest,.245])
	for side in ["L","R"]:
		var thigh := named_position("J_Bip_%s_UpperLeg"%side)
		var knee := named_position("J_Bip_%s_LowerLeg"%side)
		var ankle := named_position("J_Bip_%s_Foot"%side)
		capsules.append([thigh,knee,.16])
		capsules.append([knee,ankle,.115])

func project_contacts(point: Vector3, fallback: Vector3) -> Vector3:
	for capsule: Array in capsules:
		var a: Vector3=capsule[0]
		var ab: Vector3=capsule[1]-a
		var center := a+ab*clampf((point-a).dot(ab)/maxf(ab.length_squared(),.0001),0,1)
		var delta := point-center
		var radius: float=capsule[2]
		if delta.length_squared()<radius*radius:
			if delta.length_squared()<.00001: delta=fallback-center
			if delta.length_squared()<.00001: delta=Vector3.BACK
			point=center+delta.normalized()*radius
	point.y=maxf(FLOOR,point.y)
	return point

func step(dt: float) -> void:
	update_capsules()
	var anchors := PackedVector3Array()
	for i in range(points.size()): anchors.append(bone_position(bones[i]))
	for i in range(points.size()):
		if pinned[i]:
			points[i]=anchors[i]
			previous[i]=points[i]
			continue
		var current := points[i]
		var velocity := (points[i]-previous[i])*exp(-4.5*dt)
		# Soft shape memory is enough to keep the open hem; gravity owns the drape.
		var force := Vector3(0,-9.8,0)+(anchors[i]-points[i])*2.3
		points[i]+=velocity+force*dt*dt
		previous[i]=current
	for iteration in range(18):
		for link: Vector4 in constraints:
			var a := int(link.x)
			var b := int(link.y)
			var wa := 0.0 if pinned[a] else 1.0
			var wb := 0.0 if pinned[b] else 1.0
			if wa+wb==0: continue
			var delta := points[b]-points[a]
			var distance := maxf(delta.length(),.00001)
			var correction := delta*((distance-link.z)/distance)*link.w/(wa+wb)
			points[a]+=correction*wa
			points[b]-=correction*wb
		for i in range(points.size()):
			if not pinned[i]: points[i]=project_contacts(points[i],anchors[i])
	for i in range(points.size()):
		if pinned[i]: continue
		for capsule: Array in capsules:
			var a: Vector3=capsule[0]
			var ab: Vector3=capsule[1]-a
			var center := a+ab*clampf((points[i]-a).dot(ab)/maxf(ab.length_squared(),.0001),0,1)
			if points[i].distance_to(center)<float(capsule[2])+.008:
				previous[i]=previous[i].lerp(points[i],.55)
		if not pinned[i] and points[i].y<=FLOOR+.002:
			# Static ground contact dissipates sliding rather than bouncing.
			previous[i].x=lerpf(previous[i].x,points[i].x,.68)
			previous[i].z=lerpf(previous[i].z,points[i].z,.68)
	for chain in chains:
		for j in range(chain.size()-1):
			rig._aim(bones[chain[j]],bones[chain[j+1]],rig._target(points[chain[j+1]]))
