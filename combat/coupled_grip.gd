extends RefCounted
## Fit both fixed-length arms to the same handle without stretching the skeleton.
static func apply(visual: Node3D, offset: Vector3) -> float:
	var right: Transform3D = visual._bone_world("J_Bip_R_Hand")
	var left: Transform3D = visual._bone_world("L_Hand")
	var right_shoulder: Vector3 = visual._bone_world("J_Bip_R_UpperArm").origin
	var left_shoulder: Vector3 = visual._bone_world("J_Bip_L_UpperArm").origin
	var right_elbow: Vector3 = visual._bone_world("J_Bip_R_LowerArm").origin
	var left_elbow: Vector3 = visual._bone_world("J_Bip_L_LowerArm").origin
	var right_reach := right_shoulder.distance_to(right_elbow) + right_elbow.distance_to(right.origin) - .008
	var left_reach := left_shoulder.distance_to(left_elbow) + left_elbow.distance_to(left.origin) - .008
	var grip_delta: Vector3 = visual._weapon.global_basis * offset
	var handle := right.origin
	# Alternating projections onto two intersecting reach spheres keep the
	# correction small and preserve the authored weapon direction and timing.
	for i in range(6):
		handle = right_shoulder + (handle-right_shoulder).limit_length(right_reach)
		var left_center := left_shoulder - grip_delta
		handle = left_center + (handle-left_center).limit_length(left_reach)
	visual._solve_arm(false,handle)
	_set_hand_basis(visual,"J_Bip_R_Hand",right.basis)
	visual._weapon.global_position = visual._bone_world("J_Bip_R_Hand").origin
	var support: Vector3 = visual._weapon.global_position + grip_delta
	visual._solve_arm(true,support)
	_set_hand_basis(visual,"L_Hand",left.basis)
	return visual._bone_world("L_Hand").origin.distance_to(support)

static func _set_hand_basis(visual: Node3D, name: String, world_basis: Basis) -> void:
	var skeleton: Skeleton3D = visual.skeleton
	var bone: int = visual._bones[name]
	var parent := skeleton.get_bone_parent(bone)
	var parent_world := skeleton.global_basis * skeleton.get_bone_global_pose(parent).basis
	skeleton.set_bone_pose_rotation(bone,(parent_world.inverse()*world_basis).orthonormalized().get_rotation_quaternion())
