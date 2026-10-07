extends "res://combat/animation_controller.gd"
class_name KiritoCombatVisual
## Shared playable Kirito visual. Rules/timing remain in CombatController.
## Original Kirito shape/skin remain; equipment dyes only its clothing surfaces.
## CC0 clips supply the body performance; a small two-bone IK layer connects each
## family / mirrored strike template to actual hand joints and held equipment.

const KIRITO = preload("res://scripts/kirito_visual.gd")
const COMBAT_CLIPS = preload("res://assets/animations/retargeted/quaternius-combat.res")
const PRECISION_SHADER = preload("res://combat/kirito_precision.gdshader")
const Motion = preload("res://combat/melee_motion.gd")
const Impact = preload("res://combat/impact_feedback.gd")
const Grip = preload("res://combat/coupled_grip.gd")
const Trail = preload("res://combat/weapon_trail.gd")
var kirito: Node3D
var skeleton: Skeleton3D
var animator: AnimationPlayer
var skeletal_clip := "Idle"
var skeletal_time := 0.0
var hand_attachment_error := 0.0
var _state_age := 0.0
var _previous_state := ""
var _mount_rest: Dictionary = {}
var _bones: Dictionary = {}
var _bone_rest_basis: Dictionary = {}
var precision_material: ShaderMaterial
var _main_weapon_visible := true
var punch_hand := ""
var punch_extension := 0.0
var combat_pose_active := false
var weapons_stowed := true
var carry_anchor := Transform3D.IDENTITY
var back_attachment_error := 0.0
var _authored_melee := false
var support_hand_error := 0.0
var _pose_key := ""
var _blend_age := 1.0
var _blend_from: Array[Quaternion] = []
var _last_rotations: Array[Quaternion] = []
var _blend_hip := Vector3.ZERO
var _last_hip := Vector3.ZERO
var _weapon_trails: Array[Trail] = []
func switch_weapon_family(family: String, weapon: Dictionary = {}) -> void:
	super.switch_weapon_family(family, weapon)
	_refresh_attachment_after_equipping()

func equip_shield(data: Dictionary) -> void:
	super.equip_shield(data)
	_refresh_attachment_after_equipping()

func equip_dual_swords(data: Dictionary) -> void:
	super.equip_dual_swords(data)
	_refresh_attachment_after_equipping()

func _refresh_attachment_after_equipping() -> void:
	if is_instance_valid(kirito) and is_instance_valid(skeleton):
		_attach_weapons(false, "NORMAL")

func set_weapon_visible(visible_weapon: bool) -> void:
	_main_weapon_visible = visible_weapon
	if is_instance_valid(_weapon):
		_weapon.visible = visible_weapon

func _exit_tree() -> void:
	# Detach instances while their resources are still alive. The headless dummy
	# renderer can otherwise query a freed overlay RID during subtree teardown.
	if is_instance_valid(_rig):
		for mesh: MeshInstance3D in _rig.find_children("*", "MeshInstance3D", true, false):
			mesh.material_overlay = null
			mesh.mesh = null

func setup(is_player: bool, color: Color = Color("71cabc"), size_multiplier: float = 1.0) -> void:
	for trail in _weapon_trails:
		if is_instance_valid(trail):
			trail.hide()
			trail.queue_free()
	_weapon_trails.clear()
	kirito = null
	_mount_rest.clear()
	_bones.clear()
	_bone_rest_basis.clear()
	super.setup(is_player, color, size_multiplier)
	# The legacy nodes are pose controls. Their body primitives never render.
	for mesh: MeshInstance3D in _rig.find_children("*", "MeshInstance3D", true, false):
		mesh.hide()
	for branch in [_weapon, _dual_weapon, _shield, _spell_glow, _blade_trail, _second_blade_trail, _release_flash, _charge_spark]:
		if is_instance_valid(branch):
			_show_meshes(branch)
	for slot: String in _slots:
		for mount: Node3D in _slots[slot]:
			_mount_rest[mount] = mount.transform
			mount.hide()
	kirito = KIRITO.new()
	kirito.name = "KiritoBody"
	_rig.add_child(kirito)
	skeleton = kirito.skeleton
	kirito.apply_equipment(equipment)
	kirito.animator.stop()
	kirito.animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for index in range(skeleton.get_bone_count()):
		_bones[skeleton.get_bone_name(index)] = index
		_bone_rest_basis[skeleton.get_bone_name(index)] = skeleton.get_bone_global_rest(index).basis.orthonormalized()
	animator = AnimationPlayer.new()
	animator.name = "CombatSkeletalPlayer"
	_rig.add_child(animator)
	animator.add_animation_library("", Motion.make_library())
	animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_sample_clip("Idle", 0)
	for i in range(2):
		var trail := Trail.new()
		trail.name = "WeaponTrail%d" % i
		add_child(trail)
		_weapon_trails.append(trail)
	_apply_precision_overlay()
	update_pose(0, Vector3.FORWARD, "NORMAL", "NONE", 0)

func _show_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		node.show()
	for child in node.get_children():
		_show_meshes(child)

func _apply_precision_overlay() -> void:
	super._apply_precision_overlay()
	if _precision_meshes.is_empty():
		return
	if precision_material == null:
		precision_material = ShaderMaterial.new()
		precision_material.shader = PRECISION_SHADER
	for mesh in _precision_meshes:
		mesh.material_overlay = precision_material

func _refresh_slot(slot: String) -> void:
	for mount: Node3D in _slots.get(slot, []):
		mount.hide()
	if is_instance_valid(kirito):
		kirito.apply_equipment(equipment)

func apply_equipment(items: Dictionary) -> void:
	if not is_instance_valid(kirito):
		return
	kirito.apply_equipment(items)
	equipment.clear()
	for slot in kirito.outfit.equipment:
		var key := _slot_key(str(slot))
		if not key.is_empty() and not kirito.outfit.equipment[slot].is_empty():
			equipment[key] = kirito.outfit.equipment[slot].duplicate(true)
	for slot: String in _slots:
		for mount: Node3D in _slots[slot]:
			mount.hide()

func _slot_scale(slot: String) -> Vector3:
	return {"Head": Vector3(.68, .68, .68), "Torso": Vector3(.70, .82, .68), "Legs": Vector3(.64, .80, .66), "Feet": Vector3(.68, .68, .68), "Belt": Vector3(.67, .75, .70), "Neck": Vector3.ONE * .65, "Ring1": Vector3.ONE * .45, "Ring2": Vector3.ONE * .45}.get(slot, Vector3.ONE)

func update_pose(delta: float, facing: Vector3, state: String, phase: String, progress: float) -> void:
	for mount in _mount_rest:
		if is_instance_valid(mount):
			mount.transform = _mount_rest[mount]
	super.update_pose(delta, facing, state, phase, progress)
	if not is_instance_valid(skeleton):
		return
	var actor: Node = get_parent()
	var combat: Variant = actor.get("combat") if actor else null
	var engaged: bool = combat != null and bool(combat.in_combat)
	combat_pose_active = engaged or state in ["ACTION", "CHARGING", "GUARD", "HITSTUN", "LAUNCH", "GUARD_BROKEN", "EXPOSED", "GRABBED", "GRABBING", "KNOCKDOWN", "DEAD"]
	weapons_stowed = climbing_active or water_motion.can_pose(state) or not combat_pose_active
	_state_age = _state_age + delta if state == _previous_state else 0.0
	_previous_state = state
	var clip := _select_clip(state)
	var time := _clip_time(clip, state, phase, progress)
	_authored_melee = state == "ACTION" and not weapons_stowed and Motion.active_for(_action) and weapon_family in ["SINGLE_BLADE", "SHORT_WEAPON", "POLEARM", "HEAVY_2H"]
	if _authored_melee:
		var sample := Motion.sample(_action, phase, progress)
		clip = sample.clip
		time = sample.time
	_sample_clip(clip, time)
	_blend_pose(state + ":" + clip + ":" + str(_action.get("instance_id", "")), delta)
	if state in ["DEAD", "KNOCKDOWN", "DODGE"] and not water_motion.can_pose(state):
		# These clips already rotate/curl the skinned body. Translation is gameplay.
		_rig.rotation.x = 0
		_rig.rotation.z = 0
		_rig.position.y = 0
	var posing: bool = state in ["ACTION", "CHARGING", "GUARD", "GRABBED", "GRABBING"]
	var native_bow: bool = posing and weapon_family == "BOW"
	var resting: bool = not str(actor.get_meta("rest_pose", "")).is_empty()
	if resting:
		_rig.position.y = -.48
		_rig.rotation.x = -.16
		_solve_leg(true,to_global(Vector3(-.16,.04,-.42)))
		_solve_leg(false,to_global(Vector3(.16,.04,-.42)))
		_solve_arm(true,to_global(Vector3(-.22,.64,-.24)))
		_solve_arm(false,to_global(Vector3(.22,.64,-.24)))
		_rotate_world("J_Bip_C_Neck",Vector3(.25,0,.12))
		current_animation = "resting"
	elif climbing_active:
		_pose_climb()
	elif state == "JUMP":
		_pose_jump(progress)
	elif water_motion.can_pose(state):
		_pose_swim()
	elif state in ["NORMAL", "MOVE"] and crouch_blend > .001:
		_pose_crouch()
	elif weapon_family == "UNARMED" and combat_pose_active and state in ["NORMAL", "MOVE", "ACTION", "CHARGING"]:
		_pose_unarmed(state, phase, progress)
	elif native_bow:
		# The existing Kirito asset already has a correctly retargeted bow pose.
		var bow_clip := "BowRelease" if state == "ACTION" and phase != "STARTUP" else "Bow"
		skeleton.reset_bone_poses()
		kirito.animator.play(bow_clip, 0)
		kirito.animator.seek(.12, true)
		kirito.animator.pause()
		kirito.animator.advance(0)
		skeletal_clip = "Kirito/" + bow_clip
		if bow_clip == "Bow":
			_solve_arm(true, _rig.to_global(Vector3(-.24, 1.22, -.55)))
			_solve_arm(false, _rig.to_global(Vector3(-.20, 1.22, -.12)))
	elif posing and not _authored_melee:
		_rotate_world("J_Bip_C_Chest", _torso.rotation * .65)
		var left_goal: Vector3 = _left_hand.global_position
		var right_goal: Vector3 = _right_hand.global_position
		if state == "ACTION" and _action.get("counter_stance", false):
			right_goal = _rig.to_global(Vector3(.19, 1.32, .13))
		_solve_arm(false, right_goal)
		if weapon_family == "HEAVY_2H" and state in ["ACTION", "CHARGING"] and _action.get("attack_kind", "") != "GRAB":
			left_goal = _bone_world("J_Bip_R_Hand").origin + _weapon.global_basis * Vector3(0, 0, .12)
		_solve_arm(true, left_goal)
	if not resting and not combat_pose_active and not climbing_active and state != "JUMP" and crouch_blend <= .001 and water_motion.blend <= .001:
		punch_hand = ""
		punch_extension = 0
		current_animation = "travel_run" if _moving else "travel_idle"
	_align_equipment()
	_attach_weapons(posing, state)
	support_hand_error = 0.0
	if _authored_melee or clip == "TwoHandIdle" and not weapons_stowed:
		# The authored hand rotation now owns the blade, without the old arm IK.
		var hand := _bone_world("J_Bip_R_Hand")
		var rest: Basis = _bone_rest_basis["J_Bip_R_Hand"]
		_weapon.global_basis = hand.basis.orthonormalized() * rest.inverse() * animator.get_animation(clip).get_meta("weapon_rest_basis", Basis.IDENTITY)
		if weapon_family in ["POLEARM", "HEAVY_2H"] and shield_data.is_empty():
			support_hand_error = Grip.apply(self, Vector3(0,0,-.42 if weapon_family == "POLEARM" else .14))
	# Use actual weapon edges for both authored and legacy melee/dual actions.
	_update_weapon_trails(state, phase, progress)
	_blade_trail.hide()
	_second_blade_trail.hide()
	_remember_pose()
	_weapon.visible = _main_weapon_visible and weapon_family != "UNARMED"
	if weapon_family == "UNARMED":
		_blade_trail.hide()
		_second_blade_trail.hide()
		_release_flash.hide()
		_charge_spark.hide()
		_spell_glow.hide()
	_sync_carry_details()

func _remember_pose() -> void:
	_last_rotations.resize(skeleton.get_bone_count())
	for i in range(skeleton.get_bone_count()): _last_rotations[i] = skeleton.get_bone_pose_rotation(i)
	_last_hip = skeleton.get_bone_pose_position(int(_bones["J_Bip_C_Hips"]))

func _blend_pose(key: String, delta: float) -> void:
	if key != _pose_key:
		_pose_key = key
		_blend_age = 0.0
		_blend_from = _last_rotations.duplicate()
		_blend_hip = _last_hip
	_blend_age += delta
	if _blend_from.is_empty() or _blend_age >= .055 or delta <= 0.0: return
	var weight := smoothstep(0.0, .055, _blend_age)
	for i in range(skeleton.get_bone_count()):
		skeleton.set_bone_pose_rotation(i, _blend_from[i].slerp(skeleton.get_bone_pose_rotation(i), weight))
	var hips: int = _bones["J_Bip_C_Hips"]
	skeleton.set_bone_pose_position(hips, _blend_hip.lerp(skeleton.get_bone_pose_position(hips), weight))

func _update_weapon_trails(state: String, phase: String, progress: float) -> void:
	var active := state == "ACTION" and phase == "ACTIVE" and not weapons_stowed and _main_weapon_visible and Impact.trails_enabled
	active = active and weapon_family in ["SINGLE_BLADE", "SHORT_WEAPON", "POLEARM", "HEAVY_2H"]
	active = active and _action.get("presentation_type", "WEAPON_ACTION") == "WEAPON_ACTION" and float(_action.get("projectile_speed",0)) <= 0
	active = active and not _action.get("counter_stance",false) and not _action.get("shield_raise",false) and _action.get("attack_kind", "") != "GRAB"
	var dual: bool = _action.get("dual_wield",false)
	var order: Array = _action.get("dual_weapon_order",[1,0])
	var elapsed := float(_action.get("active",.1)) * progress
	for i in range(_weapon_trails.size()):
		var weapon: Node3D = _weapon if i == 0 else _dual_weapon
		var enabled := active and is_instance_valid(weapon) and (i == 0 or dual)
		if enabled and dual:
			var at := 0.0 if int(order[0]) == i else float(_action.get("dual_strike_gap",.1))
			enabled = elapsed >= at and elapsed < at + float(_action.get("dual_first_active",.1))
		var edge := Trail.edge(weapon_family if i == 0 else "SINGLE_BLADE", weapon_data if i == 0 else dual_weapon_data)
		_weapon_trails[i].sample(enabled,str(_action.get("instance_id",_action.get("id",""))),_clock,weapon.to_global(edge[0]) if enabled else Vector3.ZERO,weapon.to_global(edge[1]) if enabled else Vector3.ZERO)

func _pose_swim() -> void:
	var motion: Transform3D=water_motion.body_transform()
	_rig.position=motion.origin
	_rig.rotation=motion.basis.get_euler()
	_rotate_world("J_Bip_C_Chest",Vector3(water_motion.travel_blend*.16*water_motion.blend,0,0))
	_rotate_world("J_Bip_C_Neck",Vector3(water_motion.travel_blend*.30*water_motion.blend,0,0))
	for left: bool in [true,false]:
		var hand: Vector3=_bone_world("L_Hand" if left else "J_Bip_R_Hand").origin
		_solve_arm(left,hand.lerp(_rig.to_global(water_motion.hand_goal(left)),water_motion.blend))
		var side := "L" if left else "R"
		var foot: Vector3=_bone_world("J_Bip_"+side+"_Foot").origin
		_solve_leg(left,foot.lerp(_rig.to_global(water_motion.foot_goal(left)),water_motion.blend))
	current_animation=water_motion.animation_name()

func water_contact_points() -> Array[Vector3]:
	return [_bone_world("L_Hand").origin,_bone_world("J_Bip_R_Hand").origin]

func _pose_crouch() -> void:
	# Lower the pelvis and bend actual leg bones while keeping the feet grounded.
	# The silhouette and clothes remain those of the existing Kirito asset.
	_rig.position.y = -.42 * crouch_blend
	_rig.rotation = Vector3.ZERO
	var wave := sin(_clock * 7.0) * .13 * crouch_blend if _moving else 0.0
	_rotate_world("J_Bip_C_Chest", Vector3(.22 * crouch_blend, 0, 0))
	_solve_leg(true, to_global(Vector3(-.13, .035 + maxf(0, wave) * .2, wave)))
	_solve_leg(false, to_global(Vector3(.13, .035 + maxf(0, -wave) * .2, -wave)))
	_solve_arm(true, to_global(Vector3(-.24, 1.02 - .20 * crouch_blend, -.20)))
	_solve_arm(false, to_global(Vector3(.24, 1.02 - .20 * crouch_blend, -.20)))
	current_animation = "crouch_walk" if _moving else "crouch_idle"

func _pose_jump(progress: float) -> void:
	var tuck := sin(clampf(progress, 0, 1) * PI)
	_rig.position = Vector3.ZERO
	_rig.rotation = Vector3.ZERO
	_rotate_world("J_Bip_C_Chest", Vector3(.14 * tuck, 0, 0))
	_solve_leg(true, to_global(Vector3(-.15, .07 + .30 * tuck, -.15 * tuck)))
	_solve_leg(false, to_global(Vector3(.15, .07 + .21 * tuck, -.08 * tuck)))
	_solve_arm(true, to_global(Vector3(-.27, 1.16 + .12 * tuck, -.15 + .18 * tuck)))
	_solve_arm(false, to_global(Vector3(.27, 1.16 + .12 * tuck, -.15 + .18 * tuck)))
	current_animation = "jump_arc"

func _pose_climb() -> void:
	# Phase comes from real ladder displacement. A stationary climber holds the
	# exact same four bone targets, independent of render/animation wall time.
	var wave := sin(climb_phase * TAU)
	_rig.position = Vector3.ZERO
	_rig.rotation = Vector3.ZERO
	_rotate_world("J_Bip_C_Chest", Vector3(.10, 0, 0))
	_solve_arm(true, _rig.to_global(Vector3(-.23, 1.29 + wave * .20, -.36)))
	_solve_arm(false, _rig.to_global(Vector3(.23, 1.29 - wave * .20, -.36)))
	_solve_leg(true, _rig.to_global(Vector3(-.16, .22 - wave * .13, -.28)))
	_solve_leg(false, _rig.to_global(Vector3(.16, .22 + wave * .13, -.28)))
	current_animation = "climb_ik" if climb_moving else "climb_hold"

func _pose_unarmed(state: String, phase: String, progress: float) -> void:
	var left := Vector3(-.22, 1.18, -.25)
	var right := Vector3(.22, 1.18, -.25)
	punch_hand = str(_action.get("punch_hand", "right")) if state == "ACTION" else ""
	punch_extension = 0.0
	if state == "ACTION":
		var heavy: bool = str(_action.get("id", "")).contains("heavy")
		var sign_side := -1.0 if punch_hand == "left" else 1.0
		if phase == "ACTIVE":
			punch_extension = sin((.25 + clampf(progress, 0, 1) * .75) * PI)
		elif phase == "STARTUP":
			punch_extension = -.18 * progress
		_rotate_world("J_Bip_C_Chest", Vector3(-.06 * punch_extension, sign_side * punch_extension * (.40 if heavy else .26), 0))
		var strike := Vector3(sign_side * lerpf(.22, .08, maxf(0, punch_extension)), 1.14 if heavy else 1.20, -.25 - punch_extension * (.62 if heavy else .52))
		if punch_hand == "left": left = strike
		else: right = strike
		current_animation = "unarmed_" + punch_hand + ("_heavy" if heavy else "_jab")
	_solve_arm(true, _rig.to_global(left))
	_solve_arm(false, _rig.to_global(right))

func _select_clip(state: String) -> String:
	if water_motion.can_pose(state): return "Idle"
	if state == "JUMP" or crouch_blend > .001 and state in ["NORMAL", "MOVE"]: return "Idle"
	if climbing_active:
		return "Idle"
	if not combat_pose_active and state in ["NORMAL", "MOVE"]:
		return "Run" if _moving else "Idle"
	if not weapons_stowed and state == "NORMAL" and not _moving and shield_data.is_empty() and weapon_family in ["POLEARM", "HEAVY_2H"]:
		return "TwoHandIdle"
	if weapon_family == "UNARMED" and state in ["NORMAL", "MOVE", "ACTION", "CHARGING"]:
		return "Run" if _moving and state != "ACTION" else "Idle"
	match state:
		"DODGE": return "Roll"
		"DEAD", "KNOCKDOWN": return "Death"
		"HITSTUN", "LAUNCH", "GRABBED": return "Hit"
		"GUARD_BROKEN", "EXPOSED": return "ShieldBreak"
		"GUARD": return "ShieldGuard"
		"GRABBING": return "CastIdle"
		"CHARGING":
			return "CastIdle" if weapon_family == "CASTER" else "SwordIdle"
		"ACTION":
			if _action.get("counter_stance", false): return "SwordIdle"
			if _action.get("shield_raise", false): return "ShieldRaise"
			if _action.get("attack_kind", "") == "GRAB": return "Cast"
			if weapon_family == "CASTER": return "Cast"
			if _action.get("semantic", "") == "PRIMARY_TAP" and not _action.get("is_skill", false) and not _action.get("dual_wield", false) and weapon_family in ["SINGLE_BLADE", "HEAVY_2H"]:
				# A controller-owned three-strike sequence: across, return, overhead.
				# Sample each source clip over the action's own timing. Family speed
				# therefore remains in combat data, never in a visual-only timer.
				return ["SwordSlash", "SwordAlt", "HeavyChop"][posmod(int(_action.get("combo_index", 0)), 3)]
			if weapon_family == "HEAVY_2H": return "HeavyChop"
			if weapon_family == "BOW": return "CastIdle"
			return "SwordAlt" if _action.get("dual_wield", false) else "SwordSlash"
	return "Run" if _moving else "SwordIdle"

func _clip_time(clip: String, state: String, phase: String, p: float) -> float:
	var duration: float = animator.get_animation(clip).length
	if climbing_active:
		return .15
	if state in ["NORMAL", "GUARD", "MOVE"]:
		return fmod(_clock, duration)
	if state == "CHARGING" or _action.get("counter_stance", false) and state == "ACTION":
		return minf(.25, duration * .35)
	if state == "ACTION":
		var normalized: float = p * .28 if phase == "STARTUP" else (.28 + p * .46 if phase == "ACTIVE" else .74 + p * .26)
		return clampf(normalized * duration, 0, duration)
	if state == "DODGE":
		return minf(duration, _state_age / .36 * duration)
	return minf(duration, _state_age)

func _sample_clip(clip: String, time: float) -> void:
	skeletal_clip = clip
	skeletal_time = time
	skeleton.reset_bone_poses()
	if animator.assigned_animation != clip: animator.play(clip, 0)
	animator.seek(time, true)
	animator.pause()

func _bone_world(name: String) -> Transform3D:
	return skeleton.global_transform * skeleton.get_bone_global_pose(int(_bones[name]))

func _rotate_world(name: String, angles: Vector3) -> void:
	var index: int = _bones[name]
	var bone: Transform3D = skeleton.get_bone_global_pose(index)
	var parent: int = skeleton.get_bone_parent(index)
	var parent_basis: Basis = skeleton.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	var in_skeleton: Basis = skeleton.global_basis.orthonormalized().inverse() * _rig.global_basis.orthonormalized()
	var delta: Basis = in_skeleton * Basis.from_euler(angles) * in_skeleton.inverse()
	skeleton.set_bone_pose_rotation(index, (parent_basis.inverse() * delta * bone.basis).orthonormalized().get_rotation_quaternion())

func _aim_bone(index: int, child: int, goal: Vector3) -> void:
	var pose: Transform3D = skeleton.get_bone_global_pose(index)
	var before: Vector3 = (skeleton.get_bone_global_pose(child).origin - pose.origin).normalized()
	var after: Vector3 = (goal - pose.origin).normalized()
	var parent: int = skeleton.get_bone_parent(index)
	var parent_basis: Basis = skeleton.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	skeleton.set_bone_pose_rotation(index, (parent_basis.inverse() * Basis(Quaternion(before, after)) * pose.basis).orthonormalized().get_rotation_quaternion())

func _solve_arm(left: bool, world_goal: Vector3) -> void:
	var side := "L" if left else "R"
	var upper: int = _bones["J_Bip_" + side + "_UpperArm"]
	var lower: int = _bones["J_Bip_" + side + "_LowerArm"]
	var hand: int = _bones["L_Hand" if left else "J_Bip_R_Hand"]
	var start: Vector3 = skeleton.get_bone_global_pose(upper).origin
	var elbow: Vector3 = skeleton.get_bone_global_pose(lower).origin
	var end: Vector3 = skeleton.get_bone_global_pose(hand).origin
	var target: Vector3 = skeleton.to_local(world_goal)
	var a: float = start.distance_to(elbow)
	var b: float = elbow.distance_to(end)
	var direction: Vector3 = (target - start).normalized()
	var distance: float = clampf(start.distance_to(target), absf(a - b) + .002, a + b - .002)
	var along: float = (a * a - b * b + distance * distance) / (2 * distance)
	var pole: Vector3 = _rig.to_global(Vector3(-.65 if left else .65, .8, .1))
	var bend: Vector3 = skeleton.to_local(pole) - start
	bend = (bend - direction * bend.dot(direction)).normalized()
	if bend.length_squared() < .01:
		bend = direction.cross(Vector3.UP).normalized()
	var desired_elbow: Vector3 = start + direction * along + bend * sqrt(maxf(0, a * a - along * along))
	_aim_bone(upper, lower, desired_elbow)
	_aim_bone(lower, hand, target)

func hand_position(left: bool) -> Vector3:
	return to_local(_bone_world("L_Hand" if left else "J_Bip_R_Hand").origin)

func _solve_leg(left: bool, world_goal: Vector3) -> void:
	var side := "L" if left else "R"
	var upper: int = _bones["J_Bip_" + side + "_UpperLeg"]
	var lower: int = _bones["J_Bip_" + side + "_LowerLeg"]
	var foot: int = _bones["J_Bip_" + side + "_Foot"]
	var start: Vector3 = skeleton.get_bone_global_pose(upper).origin
	var knee: Vector3 = skeleton.get_bone_global_pose(lower).origin
	var end: Vector3 = skeleton.get_bone_global_pose(foot).origin
	var target: Vector3 = skeleton.to_local(world_goal)
	var a: float = start.distance_to(knee)
	var b: float = knee.distance_to(end)
	var direction: Vector3 = (target - start).normalized()
	var distance: float = clampf(start.distance_to(target), absf(a - b) + .002, a + b - .002)
	var along: float = (a * a - b * b + distance * distance) / (2 * distance)
	var bend: Vector3 = skeleton.to_local(_rig.to_global(Vector3(-.19 if left else .19, .55, -.60))) - start
	bend = (bend - direction * bend.dot(direction)).normalized()
	_aim_bone(upper, lower, start + direction * along + bend * sqrt(maxf(0, a * a - along * along)))
	_aim_bone(lower, foot, target)

func _back_frame() -> Transform3D:
	var name := "J_Bip_C_Chest"
	var current: Basis = skeleton.get_bone_global_pose(int(_bones[name])).basis.orthonormalized()
	var delta: Basis = skeleton.global_basis.orthonormalized() * current * _bone_rest_basis[name].inverse() * skeleton.global_basis.orthonormalized().inverse()
	return Transform3D(delta * _rig.global_basis, _bone_world(name).origin)

func _carry(node: Node3D, position: Vector3, orientation: Basis) -> void:
	if not is_instance_valid(node):
		return
	var expected: Transform3D = carry_anchor * Transform3D(orientation, position)
	node.global_transform = expected
	back_attachment_error = maxf(back_attachment_error, node.global_position.distance_to(expected.origin))

func _attach_back() -> void:
	carry_anchor = _back_frame()
	back_attachment_error = 0
	var position := Vector3(.20, .17, .18)
	var direction := Vector3(-.36, -.93, 0).normalized()
	var orientation := Basis.looking_at(direction, Vector3.BACK)
	match weapon_family:
		"SHORT_WEAPON": position = Vector3(.17, .02, .18)
		"HEAVY_2H":
			position = Vector3(.24, .20, .20)
			orientation = Basis.looking_at(Vector3(-.55, -.84, 0).normalized(), Vector3.BACK)
		"POLEARM":
			position = Vector3(-.23, -.20, .19)
			orientation = Basis.looking_at(Vector3(-.22, .98, 0).normalized(), Vector3.BACK)
		"BOW":
			position = Vector3(.02, -.22, .21)
			orientation = Basis.from_euler(Vector3(0, PI, -.32))
		"CASTER":
			if "orb" in str(weapon_data.get("weapon_type", "")).to_lower():
				position = Vector3(-.28, -.27, .27)
				orientation = Basis.IDENTITY
			else:
				position = Vector3(-.25, -.35, .20)
				orientation = Basis.from_euler(Vector3(0, 0, .22))
	_carry(_weapon, position, orientation)
	_carry(_dual_weapon, Vector3(-.20, .17, .23), Basis.looking_at(Vector3(.36, -.93, 0).normalized(), Vector3.BACK))
	_carry(_shield, Vector3(0, -.12, .28), Basis.from_euler(Vector3(0, PI, 0)))

func _sync_carry_details() -> void:
	if weapons_stowed:
		_blade_trail.hide()
		_second_blade_trail.hide()
		_spell_glow.hide()
		_release_flash.hide()
		_charge_spark.hide()
	if weapon_family == "BOW":
		for mesh: MeshInstance3D in _weapon.find_children("*", "MeshInstance3D", true, false):
			if mesh.mesh is BoxMesh and is_equal_approx(mesh.mesh.size.x, .018) and is_equal_approx(mesh.mesh.size.y, .018):
				mesh.visible = not weapons_stowed

func _attach_weapons(posing: bool, state: String) -> void:
	hand_attachment_error = 0
	if weapons_stowed:
		_attach_back()
		return
	if is_instance_valid(_weapon):
		var left: bool = weapon_family == "BOW"
		var actual: Vector3 = _bone_world("L_Hand" if left else "J_Bip_R_Hand").origin
		var floating_offset: Vector3 = _weapon.global_position - _right_hand.global_position if weapon_family == "CASTER" and "orb" in str(weapon_data.get("weapon_type", "")).to_lower() else Vector3.ZERO
		_weapon.global_position = actual + floating_offset
		if state == "ACTION" and _action.get("counter_stance", false):
			_weapon.global_basis = Basis.looking_at((_rig.global_basis * Vector3(-.32, -.90, .28)).normalized(), _rig.global_basis * Vector3.FORWARD)
		if not posing and state not in ["DODGE", "DEAD", "KNOCKDOWN"] and weapon_family in ["SINGLE_BLADE", "SHORT_WEAPON", "HEAVY_2H"]:
			_weapon.global_basis = _rig.global_basis * Basis.from_euler(Vector3(-1.05, .12, 0))
		hand_attachment_error = (actual + floating_offset).distance_to(_weapon.global_position)
	if is_instance_valid(_dual_weapon):
		var actual: Vector3 = _bone_world("L_Hand").origin
		_dual_weapon.global_position = actual
		if not posing:
			_dual_weapon.global_basis = _rig.global_basis * Basis.from_euler(Vector3(-1.05, -.12, 0))
		hand_attachment_error = maxf(hand_attachment_error, actual.distance_to(_dual_weapon.global_position))
	if is_instance_valid(_shield):
		_shield.global_position = _bone_world("L_Hand").origin.lerp(_bone_world("J_Bip_L_LowerArm").origin, .45)
		_shield.global_position += _rig.global_basis * Vector3(-.05, 0, -.10)
	_spell_glow.global_position = _bone_world("L_Hand").origin + _rig.global_basis * Vector3(0, -.03, -.1)

func _align_equipment() -> void:
	for slot: String in _slots:
		var mounts: Array = _slots[slot]
		for i in range(mounts.size()):
			var mount: Node3D = mounts[i]
			if not mount.visible:
				continue
			var bone_name: String = "J_Bip_C_Chest"
			var offset := Vector3.ZERO
			match slot:
				"Head": bone_name = "J_Bip_C_Head"
				"Torso": offset = Vector3(0, -.2, 0)
				"Belt":
					bone_name = "J_Bip_C_Hips"
					offset.y = .05
				"Legs": bone_name = "J_Bip_" + ("L" if i == 0 else "R") + "_UpperLeg"
				"Feet":
					bone_name = "J_Bip_" + ("L" if i == 0 else "R") + "_Foot"
					offset.y = .06
				"Neck":
					bone_name = "J_Bip_C_Neck"
					offset = Vector3(0, -.10, -.13)
				"Ring1": bone_name = "J_Bip_R_Hand"
				"Ring2": bone_name = "L_Hand"
			var current: Basis = skeleton.get_bone_global_pose(int(_bones[bone_name])).basis.orthonormalized()
			var delta: Basis = skeleton.global_basis.orthonormalized() * current * _bone_rest_basis[bone_name].inverse() * skeleton.global_basis.orthonormalized().inverse()
			mount.global_basis = delta * _rig.global_basis * Basis.IDENTITY.scaled(_slot_scale(slot))
			mount.global_position = _bone_world(bone_name).origin + delta * _rig.global_basis * offset
