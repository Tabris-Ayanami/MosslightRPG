extends Node3D
class_name CombatAnimationController
## Presentation adapter. All timing and state come from the combat controller.
## Model faces local -Z. update_pose progress is normalized within the supplied phase.

const Art = preload("res://scripts/art.gd")
const SKIN := Color("edc5a6")
const LEATHER := Color("523a36")
const METAL := Color("bfcfda")
const GOLD := Color("e9c576")

var weapon_family := "SINGLE_BLADE"
var current_animation := "idle"
var equipment: Dictionary = {}
var weapon_data: Dictionary = {}
var shield_data: Dictionary = {}
var _shield: Node3D
var _dual_weapon: Node3D
var dual_weapon_data: Dictionary = {}
var _second_blade_trail: MeshInstance3D
var dual_strike_index := -1
var dual_weapon_index := -1
var dual_template := "slash"
var dual_pose_progress: Array[float] = [0.0, 0.0]
var _blade_arc_mesh: Mesh
var _second_blade_arc_mesh: Mesh
var _thrust_streak_mesh: BoxMesh
var body_flash_remaining := 0.0
var body_flash_color := Color.WHITE
var _flash_meshes: Array[MeshInstance3D] = []
var precision_glow_active := false
var _precision_meshes: Array[MeshInstance3D] = []
var _precision_overlay: StandardMaterial3D
var _action: Dictionary = {}
var _charge_action: Dictionary = {}
var _slots: Dictionary = {}
var _rig: Node3D
var _torso: Node3D
var _head: Node3D
var _left_arm: Node3D
var _right_arm: Node3D
var _left_forearm: Node3D
var _right_forearm: Node3D
var _left_leg: Node3D
var _right_leg: Node3D
var _left_shin: Node3D
var _right_shin: Node3D
var _left_hand: Node3D
var _right_hand: Node3D
var _weapon: Node3D
var _spell_glow: MeshInstance3D
var _throw_stone: MeshInstance3D
var _blade_trail: MeshInstance3D
var _charge_aura: MeshInstance3D
var _charge_spark: MeshInstance3D
var _release_flash: MeshInstance3D
var _bow_string_top: MeshInstance3D
var _bow_string_bottom: MeshInstance3D
var _base_color := Color("71cabc")
var _clock := 0.0
var contact_remaining := 0.0
var contact_strength := 0.0
var contact_direction := Vector3.ZERO
var _contact_spark: Node3D
var _contact_material: StandardMaterial3D

func contact_reaction(direction: Vector3, strength: float, guarded := false) -> void:
	contact_remaining = .18
	contact_strength = strength
	contact_direction = direction
	if is_instance_valid(_contact_spark):
		_contact_spark.position = Vector3.UP * .95 - global_basis.inverse() * direction * .25
		_contact_material.albedo_color = Color("b3e5ff") if guarded else Color("ffdfa1")
		_contact_spark.scale = Vector3.ONE * strength
		_contact_spark.show()

func _contact_offset(delta: float) -> void:
	contact_remaining = maxf(0.0, contact_remaining - delta)
	if is_instance_valid(_contact_spark):
		_contact_spark.visible = contact_remaining > .06
		_contact_spark.scale = Vector3.ONE * contact_strength * maxf(.05, (contact_remaining - .06) / .12)
	if contact_remaining <= 0.0: return
	var envelope := contact_remaining / .18
	var local_direction := global_basis.inverse() * contact_direction
	_rig.position += local_direction * (.065 * contact_strength * envelope)
	_rig.rotation.x += -local_direction.z * .12 * contact_strength * envelope
	_rig.rotation.z += -local_direction.x * .10 * contact_strength * envelope
var _moving := false
var _dash := false
var _hit_kind := "HITSTUN"
var _hit_flash := 0.0
var _built := false
var _player := true
var climbing_active := false
var climb_phase := 0.0
var climb_moving := false
var crouch_blend := 0.0
var water_motion = preload("res://combat/water_motion.gd").new()

func set_climbing(active: bool, phase: float, moving: bool) -> void:
	# Traversal supplies displacement phase. Neither visual runs a separate clock
	# for climbing, so stopping or reversing input stops/reverses the actual limbs.
	var changed := climbing_active != active
	climbing_active = active
	climb_phase = fposmod(phase, 1.0)
	climb_moving = active and moving
	if not active and not changed:
		return
	var actor: Node = get_parent()
	var facing: Vector3 = actor.get("facing") if actor and actor.get("facing") != null else -global_basis.z
	var combat: Variant = actor.get("combat") if actor else null
	var state: String = str(combat.state) if combat != null else "NORMAL"
	var action_phase: String = str(combat.runner.action_phase) if combat != null else "NONE"
	play_locomotion(climb_moving)
	if active:
		rotation.y = atan2(-facing.x, -facing.z)
	update_pose(get_physics_process_delta_time(), facing, state, action_phase, 0)

func setup(is_player: bool, color: Color = Color("71cabc"), size_multiplier: float = 1.0) -> void:
	_player = is_player
	_base_color = color
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_slots.clear()
	_rig = _node(self, "VisualRig")
	_rig.scale = Vector3.ONE * maxf(0.2, size_multiplier)
	_torso = _node(_rig, "Body", Vector3(0, 0.99, 0))
	_head = _node(_torso, "HeadPivot", Vector3(0, 0.48, 0))
	Art.sphere(_head, Vector3(0, 0.08, 0), Vector3(0.35, 0.39, 0.33), SKIN)
	Art.sphere(_head, Vector3(0, 0.17, 0.045), Vector3(0.37, 0.25, 0.33), LEATHER)
	for x in [-0.074, 0.074]:
		Art.box(_head, Vector3(x, 0.085, -0.153), Vector3(0.042, 0.041, 0.026), Color("183343"))
	Art.box(_head, Vector3(0, -0.005, -0.157), Vector3(0.08, 0.018, 0.018), Color("b27b69"))
	_add_slot("Head", _node(_head, "Head"))
	_add_slot("Torso", _node(_torso, "Torso"))
	_add_slot("Belt", _node(_torso, "Belt", Vector3(0, -0.065, 0)))
	_add_slot("Neck", _node(_torso, "Neck", Vector3(0, 0.315, -0.155)))
	_left_leg = _node(_rig, "LeftLeg", Vector3(-0.135, 0.83, 0))
	_right_leg = _node(_rig, "RightLeg", Vector3(0.135, 0.83, 0))
	_left_shin = _node(_left_leg, "LeftShin", Vector3(0, -.34, 0))
	_right_shin = _node(_right_leg, "RightShin", Vector3(0, -.34, 0))
	for leg in [_left_leg, _right_leg]:
		_add_slot("Legs", _node(leg, "Legs"))
		var shin: Node3D = _left_shin if leg == _left_leg else _right_shin
		var lower := _node(shin, "Legs")
		lower.set_meta("lower_segment", true)
		_add_slot("Legs", lower)
		_add_slot("Feet", _node(shin, "Feet", Vector3(0, -.28, 0)))
	_left_arm = _node(_torso, "LeftArm", Vector3(-0.29, 0.29, 0))
	_right_arm = _node(_torso, "RightArm", Vector3(0.29, 0.29, 0))
	_left_forearm = _node(_left_arm, "LeftForearm", Vector3(0, -.25, 0))
	_right_forearm = _node(_right_arm, "RightForearm", Vector3(0, -.25, 0))
	for arm in [_left_arm, _right_arm]:
		Art.sphere(arm, Vector3(0, -0.075, 0), Vector3(0.19, 0.24, 0.22), _base_color.darkened(0.13))
		Art.box(arm, Vector3(0, -.19, 0), Vector3(.13, .13, .15), SKIN)
		var forearm: Node3D = _left_forearm if arm == _left_arm else _right_forearm
		Art.box(forearm, Vector3(0, -.075, 0), Vector3(.13, .17, .15), SKIN)
		Art.box(forearm, Vector3(0, -.15, 0), Vector3(.16, .11, .18), LEATHER)
	_left_hand = _node(_left_forearm, "LeftHand", Vector3(0, -.22, 0))
	_right_hand = _node(_right_forearm, "RightHand", Vector3(0, -.22, 0))
	for hand in [_left_hand, _right_hand]:
		Art.sphere(hand, Vector3.ZERO, Vector3(0.15, 0.16, 0.15), SKIN)
	_add_slot("Ring1", _node(_right_hand, "Ring1", Vector3(0, 0, -0.079)))
	_add_slot("Ring2", _node(_left_hand, "Ring2", Vector3(0, 0, -0.079)))
	_spell_glow = Art.sphere(_left_hand, Vector3(0, -0.07, -0.13), Vector3.ONE * 0.20, Color("84e6ed"))
	_spell_glow.material_override = Art.mat(Color("84e6ed"), 0.8)
	_spell_glow.visible = false
	_throw_stone = Art.sphere(_left_hand, Vector3(0, -.04, -.06), Vector3(.40, .36, .38), Color("b9a184"))
	_throw_stone.visible = false
	_blade_trail = Art.ring(_torso, Vector3(0, 0.0, -0.2), 1.12, 0.11, Color("d8ffff"), -1.35, 2.6)
	_blade_trail.visible = false
	_second_blade_trail = Art.ring(_torso, Vector3(0, .12, -.25), 1.05, .085, Color("a8e7ff"), -1.25, 2.5)
	_second_blade_trail.visible = false
	_blade_arc_mesh = _blade_trail.mesh
	_second_blade_arc_mesh = _second_blade_trail.mesh
	_thrust_streak_mesh = BoxMesh.new()
	_thrust_streak_mesh.size = Vector3(.045, .045, 1.0)
	_charge_aura = Art.ring(_rig, Vector3(0, 0.045, 0), 0.65, 0.045, Color("7adac5"))
	_charge_aura.material_override.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_charge_aura.visible = false
	_release_flash = Art.ring(_rig, Vector3(0, 0.065, 0), 0.85, 0.10, GOLD)
	_release_flash.material_override.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_release_flash.visible = false
	_built = true
	for slot in ["Head", "Torso", "Legs", "Feet", "Belt", "Neck", "Ring1", "Ring2"]:
		_refresh_slot(slot)
	switch_weapon_family(weapon_family, weapon_data)
	equip_shield(shield_data)
	equip_dual_swords(dual_weapon_data)
	_reset_pose()
	_contact_spark = _node(self, "ContactSpark")
	_contact_material = StandardMaterial3D.new()
	_contact_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_contact_material.albedo_color = Color("ffdfa1")
	for i in range(3):
		var axis := Vector3(cos(i * TAU / 3), sin(i * TAU / 3), -.35)
		var spark := Art.line(_contact_spark, -axis * .07, axis * .20, .035, Color("ffdfa1"))
		spark.material_override = _contact_material
		spark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_contact_spark.hide()

func switch_weapon_family(family: String, weapon: Dictionary = {}) -> void:
	weapon_family = family.to_upper()
	weapon_data = weapon.duplicate(true)
	if not _built:
		return
	if is_instance_valid(_weapon):
		_weapon.get_parent().remove_child(_weapon)
		_weapon.queue_free()
	var attachment := _left_hand if weapon_family == "BOW" else _right_hand
	_weapon = _node(attachment, "Weapon_" + weapon_family)
	_bow_string_top = null
	_bow_string_bottom = null
	var color := _item_color(weapon, METAL)
	var weapon_type := str(weapon.get("weapon_type", weapon.get("model_id", ""))).to_lower()
	match weapon_family:
		"SINGLE_BLADE", "SHORT_WEAPON":
			var length := 0.54 if weapon_family == "SHORT_WEAPON" else 0.95
			Art.box(_weapon, Vector3(0, 0, 0.025), Vector3(0.065, 0.07, 0.22), LEATHER)
			Art.box(_weapon, Vector3(0, 0, -0.09), Vector3(0.25, 0.06, 0.055), GOLD)
			var blade := Art.box(_weapon, Vector3(0, 0, -0.12 - length * 0.5), Vector3(0.115, 0.035, length), color)
			if "katana" in weapon_type:
				blade.rotation.y = 0.08
			Art.box(_weapon, Vector3(0, 0.021, -0.12 - length * 0.5), Vector3(0.025, 0.012, length * 0.94), Color("f1fbff"))
		"POLEARM":
			Art.box(_weapon, Vector3(0, 0, -0.38), Vector3(0.055, 0.055, 1.80), LEATHER)
			var tip := Art.cylinder(_weapon, Vector3(0, 0, -1.41), 0.095, 0.36, color, 4, 0)
			tip.rotation.x = -PI * 0.5
			Art.box(_weapon, Vector3(0, 0, -1.20), Vector3(0.12, 0.09, 0.10), GOLD)
		"HEAVY_2H":
			Art.box(_weapon, Vector3(0, 0, -0.28), Vector3(0.075, 0.075, 1.0), LEATHER)
			if "sword" in weapon_type:
				Art.box(_weapon, Vector3(0, 0, -0.95), Vector3(0.30, 0.08, 1.05), color)
				Art.box(_weapon, Vector3(0, 0, -0.42), Vector3(0.48, 0.10, 0.09), GOLD)
			elif "hammer" in weapon_type:
				Art.box(_weapon, Vector3(0, 0, -0.95), Vector3(0.63, 0.31, 0.37), color)
			else:
				Art.box(_weapon, Vector3(0, 0, -0.94), Vector3(0.66, 0.11, 0.38), color)
				for x in [-0.32, 0.32]:
					var edge := Art.box(_weapon, Vector3(x, 0, -0.94), Vector3(0.16, 0.065, 0.52), Color("e2ecdf"))
					edge.rotation.y = signf(x) * 0.18
		"BOW":
			Art.box(_weapon, Vector3.ZERO, Vector3(0.075, 0.22, 0.08), LEATHER)
			for side in [-1.0, 1.0]:
				_local_line(_weapon, Vector3(0, side * 0.08, 0), Vector3(0, side * 0.33, -0.15), 0.058, color)
				_local_line(_weapon, Vector3(0, side * 0.33, -0.15), Vector3(0, side * 0.59, 0.02), 0.044, color)
			_bow_string_top = _local_line(_weapon, Vector3(0, 0.59, 0.02), Vector3(0, 0, 0.02), 0.014, Color("dfd5b4"))
			_bow_string_bottom = _local_line(_weapon, Vector3(0, -0.59, 0.02), Vector3(0, 0, 0.02), 0.014, Color("dfd5b4"))
			Art.box(_weapon, Vector3(0.05, 0, -0.25), Vector3(0.018, 0.018, 0.8), GOLD)
		"CASTER":
			if "orb" in weapon_type:
				_weapon.position = Vector3(0, 0.05, -0.24)
				Art.sphere(_weapon, Vector3.ZERO, Vector3.ONE * 0.32, color).material_override = Art.mat(color, 0.6)
				var halo := Art.ring(_weapon, Vector3.ZERO, 0.24, 0.027, GOLD)
				halo.rotation.x = 0.6
			else:
				Art.cylinder(_weapon, Vector3(0, 0.11, 0), 0.036, 1.47, LEATHER, 6)
				Art.cylinder(_weapon, Vector3(0, 0.83, 0), 0.11, 0.17, GOLD, 6, 0.065)
				Art.sphere(_weapon, Vector3(0, 1.02, 0), Vector3(0.25, 0.34, 0.25), color).material_override = Art.mat(color, 0.55)
		_:
			Art.box(_weapon, Vector3(0, 0, -0.35), Vector3(0.08, 0.06, 0.8), color)
	var spark_at: Vector3 = {"SINGLE_BLADE": Vector3(0, 0, -.92), "SHORT_WEAPON": Vector3(0, 0, -.57), "POLEARM": Vector3(0, 0, -1.4), "HEAVY_2H": Vector3(0, 0, -.95), "BOW": Vector3(0, 0, -.35), "CASTER": Vector3.ZERO if "orb" in weapon_type else Vector3(0, 1.02, 0)}.get(weapon_family, Vector3.ZERO)
	_charge_spark = Art.sphere(_weapon, spark_at, Vector3.ONE * .12, GOLD)
	_charge_spark.material_override = Art.mat(GOLD, .8)
	_charge_spark.visible = false
	if is_instance_valid(_shield):
		_shield.visible = weapon_family in ["SINGLE_BLADE", "SHORT_WEAPON", "POLEARM"]
	if precision_glow_active:
		_apply_precision_overlay()

func equip_shield(data: Dictionary) -> void:
	shield_data = data.duplicate(true)
	if not _built:
		return
	if is_instance_valid(_shield):
		_shield.get_parent().remove_child(_shield)
		_shield.queue_free()
	_shield = null
	if data.is_empty():
		return
	_shield = _node(_left_arm, "Shield", Vector3(0, -.35, -.14))
	var color := _item_color(data, Color("996b42"))
	var rim := Art.cylinder(_shield, Vector3.ZERO, .39, .075, METAL, 12)
	rim.rotation.x = PI * .5
	var face := Art.cylinder(_shield, Vector3(0, 0, -.04), .34, .08, color, 12)
	face.rotation.x = PI * .5
	Art.sphere(_shield, Vector3(0, 0, -.11), Vector3(.17, .17, .10), METAL)
	for side in [-1.0, 1.0]:
		Art.box(_shield, Vector3(side * .17, 0, -.088), Vector3(.025, .55, .015), color.lightened(.18))
	_shield.visible = weapon_family in ["SINGLE_BLADE", "SHORT_WEAPON", "POLEARM"]
	if precision_glow_active:
		_apply_precision_overlay()

func equip_dual_swords(second_weapon: Dictionary) -> void:
	dual_weapon_data = second_weapon.duplicate(true)
	if not _built:
		return
	if is_instance_valid(_dual_weapon):
		_dual_weapon.get_parent().remove_child(_dual_weapon)
		_dual_weapon.queue_free()
	_dual_weapon = null
	if second_weapon.is_empty():
		return
	_dual_weapon = _node(_left_hand, "Sword_B")
	var color := _item_color(second_weapon, Color("9fd1e5"))
	Art.box(_dual_weapon, Vector3(0, 0, .025), Vector3(.065, .07, .22), LEATHER)
	Art.box(_dual_weapon, Vector3(0, 0, -.09), Vector3(.25, .06, .055), GOLD)
	var blade := Art.box(_dual_weapon, Vector3(0, 0, -.595), Vector3(.115, .035, .95), color)
	if "katana" in str(second_weapon.get("weapon_type", "")).to_lower():
		blade.rotation.y = -.08
	Art.box(_dual_weapon, Vector3(0, .021, -.595), Vector3(.025, .012, .89), color.lightened(.45))
	if precision_glow_active:
		_apply_precision_overlay()

func play_dual_strike(index: int) -> void:
	# The action runner dispatches the actual first/second hit; this only presents it.
	dual_strike_index = clampi(index, 0, 1)
	var order: Array = _action.get("dual_weapon_order", [1, 0])
	dual_weapon_index = int(order[dual_strike_index])

func set_precision_glow(active: bool) -> void:
	# The defense component owns this exact window; presentation adds no timer.
	if active == precision_glow_active:
		return
	precision_glow_active = active
	_apply_precision_overlay()

func _apply_precision_overlay() -> void:
	for mesh in _precision_meshes:
		if is_instance_valid(mesh) and body_flash_remaining <= 0:
			mesh.material_overlay = null
	_precision_meshes.clear()
	if not _built or not precision_glow_active or body_flash_remaining > 0:
		return
	if _precision_overlay == null:
		_precision_overlay = StandardMaterial3D.new()
		_precision_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_precision_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_precision_overlay.albedo_color = Color(1, 1, 1, .18)
		_precision_overlay.emission_enabled = true
		_precision_overlay.emission = Color.WHITE
		_precision_overlay.emission_energy_multiplier = .15
		_precision_overlay.roughness = .8
	for mesh in _rig.find_children("*", "MeshInstance3D", true, false):
		mesh.material_overlay = _precision_overlay
		_precision_meshes.append(mesh)

func flash_body(color: Color, duration: float = .12) -> void:
	_clear_body_flash()
	body_flash_color = color
	body_flash_remaining = maxf(0.0, duration)
	if not _built or duration <= 0.0:
		return
	var overlay := StandardMaterial3D.new()
	overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	overlay.albedo_color = Color(color, .86)
	overlay.emission_enabled = true
	overlay.emission = color
	overlay.emission_energy_multiplier = 1.2
	for child in _rig.find_children("*", "MeshInstance3D", true, false):
		child.material_overlay = overlay
		_flash_meshes.append(child)

func _clear_body_flash() -> void:
	for mesh in _flash_meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = null
	_flash_meshes.clear()
	body_flash_remaining = 0.0
	_apply_precision_overlay()

func equip(slot: String, item: Dictionary) -> void:
	var key := _slot_key(slot)
	if key.is_empty():
		return
	if item.is_empty():
		equipment.erase(key)
	else:
		equipment[key] = item.duplicate(true)
	if _built:
		_refresh_slot(key)

func play_locomotion(moving: bool) -> void:
	_moving = moving

func play_action(action: Dictionary) -> void:
	_action = action.duplicate(true)
	dual_strike_index = -1
	dual_weapon_index = -1
	dual_pose_progress = [0.0, 0.0]
	current_animation = str(action.get("animation_id", action.get("id", "attack")))
	if _built:
		_spell_glow.material_override = Art.mat(_action_color(action), .8)

func play_charge(action: Dictionary) -> void:
	_charge_action = action.duplicate(true)
	_action = _charge_action.duplicate(true)
	current_animation = "charging"
	if _built:
		_spell_glow.material_override = Art.mat(_action_color(action), .8)

func play_hit(kind: String) -> void:
	_hit_kind = kind.to_upper()
	_hit_flash = 0.16
	current_animation = _hit_kind.to_lower()

func play_dodge(is_dash: bool) -> void:
	_dash = is_dash
	var actor: Node=get_parent()
	current_animation = "swim_dash" if is_instance_valid(actor) and actor.get("swimming")==true else ("dash" if is_dash else "dodge")

func update_pose(delta: float, facing: Vector3, state: String, phase: String, progress: float) -> void:
	if not _built:
		return
	_clock += maxf(0.0, delta)
	water_motion.tick(get_parent(),delta,_moving,state,climbing_active)
	if body_flash_remaining > 0.0:
		body_flash_remaining = maxf(0.0, body_flash_remaining - delta)
		if body_flash_remaining <= 0.0:
			_clear_body_flash()
	_hit_flash = maxf(0.0, _hit_flash - delta)
	if facing.length_squared() > 0.001:
		rotation.y = lerp_angle(rotation.y, atan2(-facing.x, -facing.z), minf(1.0, delta * 18.0))
	_reset_pose()
	if is_instance_valid(get_parent()) and not str(get_parent().get_meta("rest_pose", "")).is_empty():
		_rig.position.y = -.40
		_rig.rotation.x = -.22
		_left_leg.rotation.x = -1.25
		_right_leg.rotation.x = -1.25
		_left_arm.rotation.x = -.35
		_right_arm.rotation.x = -.35
		_torso.rotation.z = .12
		current_animation = "resting"
		return
	if climbing_active:
		_pose_procedural_climb()
		return
	if state == "JUMP":
		_pose_procedural_jump(progress)
		return
	if water_motion.can_pose(state):
		_pose_procedural_swim()
		return
	if state in ["NORMAL", "MOVE"] and crouch_blend > .001:
		_pose_procedural_crouch()
		return
	var p := clampf(progress, 0.0, 1.0)
	match state.to_upper():
		"DEAD":
			_rig.rotation.z = 1.48
			_rig.position.y = 0.13
			_left_arm.rotation.z = -0.7
			_right_arm.rotation.z = 0.7
			current_animation = "dead"
		"KNOCKDOWN":
			_rig.rotation.x = -1.35
			_rig.position.y = 0.25
			_left_leg.rotation.x = 0.38
			_right_leg.rotation.x = 0.12
		"HITSTUN", "LAUNCH":
			_rig.rotation.x = -0.20
			_torso.rotation.z = sin(_clock * 46.0) * 0.065
			_left_arm.rotation.x = -0.48
			_right_arm.rotation.x = -0.48
			if _hit_kind == "LAUNCH" or state.to_upper() == "LAUNCH":
				_left_leg.rotation.x = 0.7
				_right_leg.rotation.x = -0.45
		"DODGE":
			_rig.rotation.x = -0.46 if _dash else -0.80
			_rig.position.y = -0.07 if _dash else -0.23
			_left_arm.rotation.x = -0.9
			_right_arm.rotation.x = -0.9
			_left_leg.rotation.x = sin(_clock * 26.0) * 0.85
			_right_leg.rotation.x = -_left_leg.rotation.x
		"GUARD":
			_pose_guard()
			current_animation = "guard"
		"GUARD_BROKEN", "EXPOSED":
			_torso.rotation.x = .48
			_torso.rotation.z = -.22
			_left_arm.rotation.z = -.8
			_right_arm.rotation.x = -.48
			_rig.position.y = -.17
			_left_leg.rotation.x = .35
			current_animation = "exposed"
		"GRABBED":
			_torso.rotation.x = -.35
			_left_arm.rotation.x = 2.1
			_right_arm.rotation.x = 2.1
			_left_leg.rotation.x = .45
			_right_leg.rotation.x = -.2
			current_animation = "grabbed"
		"GRABBING":
			_torso.rotation.x = -.23
			_left_arm.rotation = Vector3(1.45, -.35, -.35)
			_right_arm.rotation = Vector3(1.45, .35, .35)
			current_animation = "grabbing"
		"ACTION":
			_pose_action(phase.to_upper(), p)
			_pose_release(phase.to_upper(), p)
		"CHARGING":
			_pose_charge(p)
		_:
			current_animation = "move" if _moving else "idle"
			if _moving:
				var stride := sin(_clock * 11.0)
				_left_leg.rotation.x = stride * 0.60
				_right_leg.rotation.x = -stride * 0.60
				_left_arm.rotation.x += -stride * 0.3
				_right_arm.rotation.x += stride * 0.3
				_rig.position.y = absf(cos(_clock * 11.0)) * 0.045
				_torso.rotation.x = -0.07
			else:
				_torso.position.y += sin(_clock * 2.6) * 0.013
	if _hit_flash > 0.0:
		_torso.scale = Vector3(1.0 + _hit_flash * 0.24, 1.0 - _hit_flash * 0.14, 1.0 + _hit_flash * 0.24)
	_contact_offset(delta)

func _pose_procedural_swim() -> void:
	var motion: Transform3D=water_motion.body_transform()
	_rig.position=motion.origin
	_rig.basis=motion.basis.scaled(Vector3.ONE*_rig.scale.x)
	for left: bool in [true,false]:
		var upper: Node3D=_left_arm if left else _right_arm
		var lower: Node3D=_left_forearm if left else _right_forearm
		var hand: Node3D=_left_hand if left else _right_hand
		var goal: Vector3=_rig.to_local(hand.global_position).lerp(water_motion.hand_goal(left),water_motion.blend)
		_pose_limb(upper,lower,hand,goal,Vector3(-.72 if left else .72,.8,.1))
		var leg: Node3D=_left_leg if left else _right_leg
		var shin: Node3D=_left_shin if left else _right_shin
		if water_motion.burst:
			var flutter := sin(water_motion.burst_progress*TAU*2+(0.0 if left else PI))
			leg.rotation.x=.20+flutter*.42
			shin.rotation.x=-.18-maxf(0,flutter)*.44
		else:
			leg.rotation.x=.3+sin(water_motion.phase*TAU+(.4 if left else 0))*.23
			shin.rotation.x=-.45
	_head.rotation.x=water_motion.travel_blend*.35*water_motion.blend
	current_animation=water_motion.animation_name()
	_stow_climbing_equipment()

func water_contact_points() -> Array[Vector3]:
	return [_left_hand.global_position,_right_hand.global_position]

func _pose_procedural_crouch() -> void:
	var blend := crouch_blend
	var stride := sin(_clock * 7.0) * .12 * blend if _moving else 0.0
	_torso.position.y -= .40 * blend
	_torso.rotation.x = .22 * blend
	_head.rotation.x = -.16 * blend
	_left_leg.position.y = .83 - .40 * blend
	_right_leg.position.y = .83 - .40 * blend
	_pose_limb(_left_leg, _left_shin, _slots.Feet[0], Vector3(-.135, .21, stride), Vector3(-.20, .3, -.70))
	_pose_limb(_right_leg, _right_shin, _slots.Feet[1], Vector3(.135, .21, -stride), Vector3(.20, .3, -.70))
	for foot: Node3D in _slots.Feet: foot.global_basis = _rig.global_basis
	_left_arm.rotation.x = .25 * blend
	_right_arm.rotation.x = .25 * blend
	current_animation = "crouch_walk" if _moving else "crouch_idle"

func _pose_procedural_jump(progress: float) -> void:
	var tuck := sin(clampf(progress, 0, 1) * PI)
	_torso.rotation.x = .16 * tuck
	_left_arm.rotation.x = .6 - tuck
	_right_arm.rotation.x = .6 - tuck
	_left_leg.rotation.x = .48 * tuck
	_right_leg.rotation.x = .25 * tuck
	_left_shin.rotation.x = -.8 * tuck
	_right_shin.rotation.x = -.55 * tuck
	current_animation = "jump_arc"

func _pose_procedural_climb() -> void:
	var wave := sin(climb_phase * TAU)
	# Real articulated limbs, using the same contact cycle as the skinned hero.
	_pose_limb(_left_arm, _left_forearm, _left_hand, Vector3(-.27, 1.46 + wave * .16, -.31), Vector3(-.65, 1.05, .05))
	_pose_limb(_right_arm, _right_forearm, _right_hand, Vector3(.27, 1.46 - wave * .16, -.31), Vector3(.65, 1.05, .05))
	_pose_limb(_left_leg, _left_shin, _slots.Feet[0], Vector3(-.15, .26 - wave * .13, -.23), Vector3(-.20, .58, -.65))
	_pose_limb(_right_leg, _right_shin, _slots.Feet[1], Vector3(.15, .26 + wave * .13, -.23), Vector3(.20, .58, -.65))
	# Keep the boots level on a rung instead of rotating them with the shin.
	for foot: Node3D in _slots.Feet:
		foot.global_basis = _rig.global_basis
	_head.rotation.x = -.10
	current_animation = "climb_ik" if climb_moving else "climb_hold"
	_stow_climbing_equipment()

func _pose_limb(upper: Node3D, lower: Node3D, end: Node3D, goal: Vector3, pole: Vector3) -> void:
	var start: Vector3 = _rig.to_local(upper.global_position)
	var a: float = lower.position.length()
	var b: float = end.position.length()
	var direction := (goal - start).normalized()
	var distance := clampf(start.distance_to(goal), absf(a - b) + .001, a + b - .001)
	var along := (a * a - b * b + distance * distance) / (2 * distance)
	var bend := pole - start
	bend = (bend - direction * bend.dot(direction)).normalized()
	var joint := start + direction * along + bend * sqrt(maxf(0, a * a - along * along))
	upper.global_basis = _rig.global_basis * Basis(Quaternion(Vector3.DOWN, (joint - start).normalized()))
	lower.global_basis = _rig.global_basis * Basis(Quaternion(Vector3.DOWN, (goal - joint).normalized()))

func _stow_climbing_equipment() -> void:
	var at := Vector3(.20, .38, .23)
	var orientation := Basis.looking_at(Vector3(-.38, -.92, 0).normalized(), Vector3.BACK)
	match weapon_family:
		"SHORT_WEAPON": at = Vector3(.19, .19, .23)
		"POLEARM":
			at = Vector3(-.24, -.02, .23)
			orientation = Basis.looking_at(Vector3(-.22, .98, 0).normalized(), Vector3.BACK)
		"HEAVY_2H": at = Vector3(.25, .40, .25)
		"BOW":
			at = Vector3(0, .05, .25)
			orientation = Basis.from_euler(Vector3(0, PI, -.30))
		"CASTER":
			at = Vector3(-.28, -.05, .25)
			orientation = Basis.from_euler(Vector3(0, 0, .2))
	if is_instance_valid(_weapon): _weapon.global_transform = _torso.global_transform * Transform3D(orientation, at)
	if is_instance_valid(_dual_weapon): _dual_weapon.global_transform = _torso.global_transform * Transform3D(Basis.looking_at(Vector3(.38, -.92, 0).normalized(), Vector3.BACK), Vector3(-.20, .38, .27))
	if is_instance_valid(_shield): _shield.global_transform = _torso.global_transform * Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, .05, .30))

func _pose_charge(progress: float) -> void:
	# The input/controller owns charge time. This pose never advances or releases it.
	var weight := 0.45 + progress * 0.55
	var secondary := str(_charge_action.get("semantic", "")).begins_with("SECONDARY")
	var ready := progress >= .999
	current_animation = "charge_ready" if ready else "charging"
	_pose_action("STARTUP", weight)
	_left_leg.rotation.x = .22 * weight
	_right_leg.rotation.x = -.25 * weight
	_rig.position.y = -.06 * weight
	match weapon_family:
		"SINGLE_BLADE":
			_right_arm.rotation.x = lerpf(1.30, 2.0, progress)
			_right_arm.rotation.y = -.75 if not secondary else -.25
			_right_arm.rotation.z = .38
			_torso.rotation.y = -.42 * weight
			_weapon.rotation.x = -.30
		"SHORT_WEAPON":
			_torso.rotation.x = -.18 - progress * .16
			_rig.position.y = -.13 * weight
			_right_arm.rotation.x = 1.22
			_right_arm.rotation.y = -.35 if not secondary else .24
			_left_arm.rotation.x = .8
			_weapon.rotation.x = -_right_arm.rotation.x
			_weapon.position.z = .18
		"POLEARM":
			_right_arm.rotation.x = 1.2
			_left_arm.rotation.x = 1.38
			_left_arm.rotation.z = -.4
			_weapon.rotation.x = -1.2
			_weapon.position.z = .3 - progress * .1
			_torso.rotation.y = (-.65 - progress * .4) if secondary else -.3
			_weapon.rotation.y = -.55 if secondary else 0.0
		"HEAVY_2H":
			_right_arm.rotation.x = lerpf(1.85, 2.7, progress)
			_left_arm.rotation.x = _right_arm.rotation.x
			_right_arm.rotation.y = -.15
			_left_arm.rotation.z = -.60
			_torso.rotation.x = .08 + progress * .08
			_torso.rotation.y = .3 if secondary else -.12
			_rig.position.y = -.11 * weight
			_weapon.rotation.x = -.25
		"BOW":
			_left_arm.rotation.x = 1.5
			_left_arm.rotation.y = -.08
			_right_arm.rotation.x = 1.2
			_right_arm.rotation.y = -.65 - progress * .25
			_right_hand.position.z += .30 * progress
			_torso.rotation.y = .32 if secondary else .18
			_weapon.rotation.x = -_left_arm.rotation.x
			_pose_bow_string(weight)
		"CASTER":
			_left_arm.rotation.x = .9 + .4 * progress
			_left_arm.rotation.z = -.35 if secondary else -.18
			_right_arm.rotation.x = .4
			_right_arm.rotation.z = .25
			_torso.rotation.y = .18 if secondary else -.15
			_spell_glow.visible = true
			_spell_glow.scale = Vector3.ONE * (.17 + progress * .23)
	_head.rotation.x = -.07 * weight
	if is_instance_valid(_dual_weapon):
		_torso.rotation = Vector3(-.08, -.22 if not secondary else .28, 0)
		_rig.position.y = -.12 * weight
		_right_arm.rotation = Vector3(1.6 + progress * .45, -.65, .5)
		_left_arm.rotation = Vector3(1.15 + progress * .4, .65, -.55)
		_weapon.rotation = Vector3(-.4, -.15, .15)
		_dual_weapon.rotation = Vector3(-.6, .25, -.35)
		if secondary:
			_right_arm.rotation = Vector3(1.20, -.35, .70)
			_left_arm.rotation = Vector3(1.85, .45, -.30)
			_dual_weapon.rotation.x = -.2
	_blade_trail.visible = false
	# Only the externally supplied precision window lights the character.
	_charge_aura.visible = false
	_charge_spark.visible = false
	current_animation = "charge_ready" if ready else "charging"

func _pose_guard() -> void:
	_left_arm.rotation = Vector3(1.3, -.18, -.15)
	_right_arm.rotation = Vector3(.55, -.4, .2)
	_torso.rotation.y = -.15
	_left_leg.rotation.x = .22
	_right_leg.rotation.x = -.2
	_rig.position.y = -.055
	if is_instance_valid(_shield):
		_shield.rotation.x = -1.3
	_weapon.rotation.x = -.7

func _pose_release(phase: String, progress: float) -> void:
	if not _action.get("charged_release", false):
		return
	var ratio := clampf(float(_action.get("charge_ratio", 0.0)), 0, 1)
	if phase == "ACTIVE":
		_release_flash.visible = true
		_release_flash.scale = Vector3.ONE * (1.0 + progress * .55 + ratio * .15)
		_release_flash.material_override.albedo_color = Color(GOLD if ratio >= .999 else Color("b9eee2"), 1.0 - progress * .75)
		_charge_spark.visible = progress < .65
		_charge_spark.scale = Vector3.ONE * (.14 + ratio * .08)
		if _blade_trail.visible:
			_blade_trail.scale *= 1.0 + ratio * .18

func _action_color(action: Dictionary) -> Color:
	return {"FIRE": Color("ffba75"), "WIND": Color("a6e2bd"), "ICE": Color("91e4f0"), "LIGHTNING": Color("c3b8ff"), "EARTH": Color("d7c591")}.get(str(action.get("damage_type", "")), Color("84e6ed"))

func _local_line(parent: Node3D, start: Vector3, end: Vector3, width: float, color: Color) -> MeshInstance3D:
	# Equipment can be rebuilt after its actor has moved and rotated.
	var direction := end - start
	var segment := Art.box(parent, (start + end) * .5, Vector3(width, width, direction.length()), color)
	if direction.length_squared() > .000001:
		segment.basis = Basis.looking_at(direction.normalized(), Vector3.RIGHT if absf(direction.normalized().y) > .99 else Vector3.UP)
	return segment

func _pose_bow_string(tension: float) -> void:
	if not is_instance_valid(_bow_string_top) or not is_instance_valid(_bow_string_bottom):
		return
	var center := Vector3(0, 0, .02 + clampf(tension, 0, 1) * .38)
	for pair in [[_bow_string_top, Vector3(0, .59, .02)], [_bow_string_bottom, Vector3(0, -.59, .02)]]:
		var segment: MeshInstance3D = pair[0]
		var end: Vector3 = pair[1]
		segment.mesh.size = Vector3(.014, .014, center.distance_to(end))
		segment.position = (center + end) * .5
		segment.basis = Basis.looking_at((end - center).normalized(), Vector3.RIGHT)

func _pose_action(phase: String, p: float) -> void:
	if _action.get("dual_wield", false) and is_instance_valid(_dual_weapon):
		_pose_dual_action(phase, p)
		return
	# One arc consists of the externally supplied windup, strike and recovery.
	var wind := p if phase == "STARTUP" else (1.0 - p if phase == "RECOVERY" else 1.0)
	if phase == "STARTUP" and _action.get("charged_release", false):
		wind = 1.0
	var strike := p if phase == "ACTIVE" else (1.0 if phase == "RECOVERY" else 0.0)
	var release := 1.0 - p if phase == "RECOVERY" else 1.0
	var presentation := str(_action.get("presentation_type", "WEAPON_ACTION"))
	var family := "CASTER" if presentation == "CASTER_ACTION" else weapon_family
	var id := str(_action.get("animation_id", _action.get("id", ""))).to_lower()
	if id == "overhand_throw":
		# Raised stone telegraphs the same fixed direction used by the projectile.
		_stow_climbing_equipment()
		# Raise early, then hold the silhouette long enough to read at game zoom.
		var lift := lerpf(.15, 2.85, minf(1.0, p / .45)) if phase == "STARTUP" else (lerpf(2.85, 1.25, p) if phase == "ACTIVE" else lerpf(1.25, .15, p))
		_left_arm.rotation = Vector3(lift, -.25 * wind, -.25 * wind)
		_left_forearm.rotation.x = -.45 * wind
		_torso.rotation = Vector3(.12 * wind, .18 * wind, 0)
		_throw_stone.visible = phase == "STARTUP"
		current_animation = "throw_windup" if phase == "STARTUP" else "throw_release"
		return
	if _action.get("shield_raise", false) or "shield_raise" in id:
		_pose_guard()
		current_animation = "shield_raise"
		return
	if _action.get("counter_stance", false):
		var prepared := 1.0 if phase == "ACTIVE" else wind
		_torso.rotation.y = -.22 * prepared
		_right_arm.rotation = Vector3(-.65, -.6, -.35) * prepared
		_left_arm.rotation.x = .18 * prepared
		_weapon.position = Vector3(-.25, .42, .18) * prepared
		_weapon.rotation = Vector3(2.2, -.35, .25) * prepared
		_head.rotation.y = .18 * prepared
		current_animation = "counter_stance_ready" if phase == "ACTIVE" else "counter_stance_prepare"
		return
	if _action.get("attack_kind", "") == "GRAB" or "grab" in id:
		_torso.rotation.x = -.22 * wind
		_left_arm.rotation = Vector3(1.3 + strike * .3, -.65 + strike * .45, -.35) * wind
		_right_arm.rotation = Vector3(1.3 + strike * .3, .65 - strike * .45, .35) * wind
		current_animation = "grab_windup" if phase == "STARTUP" else "grabbing"
		return
	var semantic := str(_action.get("semantic", ""))
	var secondary := semantic.begins_with("SECONDARY")
	var basic_combo := semantic == "PRIMARY_TAP" and not bool(_action.get("is_skill", false))
	var combo_step := posmod(int(_action.get("combo_index", 0)), 3)
	var combo_direction := -1.0 if basic_combo and combo_step == 1 else 1.0
	var charged := semantic.ends_with("_CHARGE") or "charge" in id or "slam" in id
	var thrust := "thrust" in id or "pierc" in id or "stab" in id or "lunge" in id
	thrust = thrust or (family == "SINGLE_BLADE" and semantic == "SECONDARY_TAP") or (family == "SHORT_WEAPON" and charged) or (family == "POLEARM" and semantic == "PRIMARY_CHARGE")
	var vertical := "slam" in id or "leap" in id or "quake" in id or (charged and family == "HEAVY_2H")
	vertical = vertical or (basic_combo and combo_step == 2 and family in ["SINGLE_BLADE", "HEAVY_2H"])
	if "fujian_counter" in id or "guard_riposte" in id:
		_right_arm.rotation = Vector3(lerpf(2.1, .5, strike), lerpf(-1.05, 1.1, strike), .3) * wind
		_torso.rotation.y = lerpf(-.5, .6, strike) * wind
		_blade_trail.visible = phase == "ACTIVE"
		_blade_trail.rotation.y = PI + lerpf(-1.0, 1.0, strike)
		_blade_trail.scale = Vector3.ONE * 1.1
		current_animation = "counter_slash"
		return
	if presentation == "VFX_ONLY":
		_left_arm.rotation.z = -wind * 0.6
		_right_arm.rotation.z = wind * 0.6
		_torso.scale = Vector3.ONE * (1.0 + wind * 0.045)
		_spell_glow.visible = phase != "RECOVERY"
		return
	match family:
		"SINGLE_BLADE":
			_right_arm.rotation.x = -0.85 * wind
			if vertical:
				_right_arm.rotation = Vector3(lerpf(-2.4, .15, strike), -.08, .12) * wind
				_torso.rotation = Vector3(lerpf(.12, -.28, strike), -.12, 0) * wind
				_left_leg.rotation.x = -.22 * wind
			elif thrust:
				_right_arm.rotation.x = lerpf(-0.52, -1.58, strike) * release
				_weapon.position.z = -strike * 0.20 * release
				_torso.rotation.y = -0.30 * wind
			else:
				var parity := combo_direction if basic_combo else (-1.0 if id.ends_with("2") else 1.0)
				_right_arm.rotation.y = lerpf(-1.10, 1.35, strike) * wind * parity
				_right_arm.rotation.z = 0.40 * wind
				_torso.rotation.y = lerpf(-0.48, 0.48, strike) * wind * parity
				if charged:
					_right_arm.rotation.x -= 0.65 * (1.0 - strike) * wind
					if secondary:
						_torso.rotation.x = -0.20 * wind
		"SHORT_WEAPON":
			_torso.rotation.x = (0.20 if secondary and not charged else -0.22) * wind
			_right_arm.rotation.x = lerpf(-0.70, -1.45, strike) * wind
			_right_arm.rotation.y = lerpf(-0.75, 0.45, strike) * wind * (-1.0 if int(_action.get("combo_index", 0)) % 2 else 1.0)
			_left_arm.rotation.x = -0.70 * wind
			_left_leg.rotation.x = -0.30 * wind
			_weapon.position.z = -strike * (0.35 if thrust or charged else 0.10) * release
			if secondary and charged:
				_torso.rotation.x = -0.38 * wind
		"POLEARM":
			_right_arm.rotation.x = -1.02 * wind
			_left_arm.rotation.x = -1.20 * wind
			_left_arm.rotation.z = -0.40 * wind
			if thrust:
				_weapon.position.z = lerpf(0.30, -0.65, strike) * wind
				_torso.rotation.x = -0.22 * strike * release
			else:
				_torso.rotation.y = lerpf(-0.95, 1.20, strike) * wind * (1.4 if charged else (1.12 if secondary else 1.0))
				_right_arm.rotation.y = lerpf(-0.45, 0.60, strike) * wind
		"HEAVY_2H":
			_left_arm.rotation.x = -1.0 * wind
			_left_arm.rotation.z = -0.65 * wind
			if vertical:
				_right_arm.rotation.x = lerpf(-2.5, 0.20, strike) * wind
				_left_arm.rotation.x = _right_arm.rotation.x
				_torso.rotation.x = lerpf(0.18, -0.35, strike) * wind
			else:
				_right_arm.rotation.x = -1.15 * wind
				_torso.rotation.y = lerpf(-1.0, 1.40, strike) * wind * combo_direction
				_right_arm.rotation.y = lerpf(-0.75, 0.65, strike) * wind * combo_direction
			_left_leg.rotation.x = -0.25 * wind
			if secondary:
				_left_leg.rotation.x = -0.46 * wind
				_torso.rotation.y += 0.25 * wind
		"BOW":
			_left_arm.rotation.x = -1.52 * wind
			_left_arm.rotation.y = -0.08 * wind
			_right_arm.rotation.x = -1.15 * wind
			_right_arm.rotation.y = -0.60 * wind
			_right_hand.position.z += (0.34 if charged else 0.20) * wind * (1.0 - strike)
			_torso.rotation.y = (0.32 if secondary else 0.18) * wind
			_head.rotation.x = -0.12 * wind if charged else 0.0
			_weapon.rotation.x = 1.52 * wind
		"CASTER":
			# Staff and orb share this pose; their attachment offsets differ.
			_left_arm.rotation.x = lerpf(-0.75, -1.52, strike) * wind
			_left_arm.rotation.z = -0.20 * wind
			_right_arm.rotation.x = -0.48 * wind
			_right_arm.rotation.z = 0.22 * wind
			_torso.rotation.y = (0.18 if secondary else -0.15) * wind
			_left_arm.rotation.z -= 0.28 * wind if secondary else 0.0
			_head.rotation.x = -0.12 * wind if charged else 0.0
			_spell_glow.visible = phase != "RECOVERY" or p < 0.3
			_spell_glow.scale = Vector3.ONE * 0.20 * (0.8 + (1.4 if charged else 0.8) * wind)
	# Arms start downward: positive X raises a hand toward the model's -Z front.
	_left_arm.rotation.x *= -1.0
	_right_arm.rotation.x *= -1.0
	if family == "BOW":
		_weapon.rotation.x = -_left_arm.rotation.x
		_pose_bow_string(wind * (1.0 - strike))
	elif family in ["SHORT_WEAPON", "POLEARM"] or (family == "HEAVY_2H" and not vertical) or thrust:
		_weapon.rotation.x = -_right_arm.rotation.x
	if family == "HEAVY_2H":
		# Both hands share the handle throughout all three heavy strike paths.
		var grip: Vector3 = _right_hand.global_position + _weapon.global_basis * Vector3(0, 0, .12)
		_pose_limb(_left_arm, _left_forearm, _left_hand, _rig.to_local(grip), Vector3(-.62, 1.02, .05))
	_blade_trail.visible = phase == "ACTIVE" and family in ["SINGLE_BLADE", "SHORT_WEAPON", "POLEARM", "HEAVY_2H"] and not thrust
	_blade_trail.rotation.y = PI + lerpf(-0.85, 0.85, strike) * combo_direction
	if vertical:
		_blade_trail.rotation = Vector3(0, PI * .5, PI * .5)
	_blade_trail.scale = Vector3.ONE * (0.65 if family == "SHORT_WEAPON" else (1.28 if family in ["POLEARM", "HEAVY_2H"] else 1.0))
	if basic_combo and family in ["SINGLE_BLADE", "HEAVY_2H"]:
		current_animation = ("heavy_" if family == "HEAVY_2H" else "sword_") + ["slash", "return_slash", "overhead_finish"][combo_step]

func _pose_dual_action(phase: String, p: float) -> void:
	var startup := float(_action.get("startup", .1))
	var active := float(_action.get("active", .28))
	var first_active := maxf(.01, float(_action.get("dual_first_active", .1)))
	var second_at := float(_action.get("dual_second_at", startup + float(_action.get("dual_strike_gap", first_active + .06))))
	var elapsed := startup * p if phase == "STARTUP" else startup + active * p
	if phase == "RECOVERY":
		elapsed = startup + active + float(_action.get("recovery", .2)) * p
	var first := clampf((elapsed - startup) / first_active, 0, 1)
	var second := clampf((elapsed - second_at) / first_active, 0, 1)
	var wind := .4 + p * .6 if phase == "STARTUP" else 1.0
	var recover := 1.0 - p if phase == "RECOVERY" else 1.0
	var secondary := str(_action.get("semantic", "")).begins_with("SECONDARY")
	var charged: bool = bool(_action.get("charged_release", false)) or str(_action.get("semantic", "")).ends_with("CHARGE")
	var sequence: Dictionary = _action.get("dual_sequence", {})
	dual_template = str(sequence.get("template", "slash"))
	var order: Array = _action.get("dual_weapon_order", [1, 0])
	var progress_by_weapon: Array[float] = [0.0, 0.0]
	progress_by_weapon[int(order[0])] = first
	progress_by_weapon[int(order[1])] = second
	dual_pose_progress = progress_by_weapon
	for weapon_index in range(2):
		var sequence_index: int = 0 if int(order[0]) == weapon_index else 1
		var begins: float = startup if sequence_index == 0 else second_at
		var striking: bool = phase == "ACTIVE" and elapsed >= begins and elapsed < begins + first_active
		_pose_dual_side(weapon_index, progress_by_weapon[weapon_index], wind, recover, striking, charged, secondary)
	_torso.rotation.y = (progress_by_weapon[0] - progress_by_weapon[1]) * .65 * recover
	_torso.rotation.x = -.12 * recover
	_left_leg.rotation.x = .20 * recover
	_right_leg.rotation.x = -.18 * recover
	_rig.position.y = -.065 * recover
	if dual_template == "spin":
		# Each side reuses one complete turn, mirrored around the body's forward plane.
		_rig.rotation.y = TAU * (progress_by_weapon[0] - progress_by_weapon[1])
		_torso.rotation.y = 0
		_torso.rotation.x = -.04 * recover
	elif dual_template == "thrust":
		# Root gameplay moves once; this adapter only alternates the two arm thrusts.
		_torso.rotation.x = -.18 * recover
	current_animation = "dual_%s_%s" % ["b" if dual_weapon_index == 1 else "a", dual_template] if phase == "ACTIVE" else "dual_prepare"

func _pose_dual_side(index: int, progress: float, wind: float, recover: float, striking: bool, charged: bool, secondary: bool) -> void:
	# A and B use exactly the same pose template with reflected Y/Z rotations.
	var side: float = 1.0 if index == 0 else -1.0
	var arm: Node3D = _right_arm if index == 0 else _left_arm
	var sword: Node3D = _weapon if index == 0 else _dual_weapon
	var trail: MeshInstance3D = _blade_trail if index == 0 else _second_blade_trail
	var strength: float = wind * recover
	arm.rotation = Vector3(lerpf(1.75 if charged else 1.25, .55, progress), lerpf(-1.0, 1.05, progress) * side, .42 * side) * strength
	sword.rotation = Vector3(-.45, .1 * side, .15 * side)
	trail.visible = striking
	trail.position = Vector3(0, .08 * side, -.2)
	trail.rotation = Vector3(.12 * side, PI + lerpf(-1.1, 1.0, progress) * side, .28 * side)
	trail.scale = Vector3.ONE * (1.12 if charged else .96)
	if secondary:
		arm.rotation.x = lerpf(.65, 1.6, progress) * strength
	if dual_template == "spin":
		arm.rotation = (Vector3(.35, -.15 * side, 1.3 * side) if striking else Vector3(.9, -.4 * side, .15 * side)) * strength
		sword.rotation = Vector3(-.1 if striking else -.55, -.4 * side, .25 * side)
		trail.rotation = Vector3(0, PI + .5 * side, 0)
		trail.scale = Vector3.ONE * 1.26
	elif dual_template == "thrust":
		var extension: float = sin(progress * PI)
		arm.rotation = Vector3(lerpf(.65, 1.57, extension), -.08 * side, .08 * side) * strength
		sword.rotation = Vector3(-arm.rotation.x, 0, 0)
		sword.position.z = -.32 * extension
		trail.mesh = _thrust_streak_mesh
		trail.position = Vector3(.24 * side, .25, -1.12 - extension * .2)
		trail.rotation = Vector3.ZERO
		trail.scale = Vector3.ONE

func _reset_pose() -> void:
	_rig.position = Vector3.ZERO
	_rig.rotation = Vector3.ZERO
	_torso.position = Vector3(0, 0.99, 0)
	_torso.rotation = Vector3.ZERO
	_torso.scale = Vector3.ONE
	_head.rotation = Vector3.ZERO
	for limb in [_left_arm, _right_arm, _left_forearm, _right_forearm, _left_leg, _right_leg, _left_shin, _right_shin]:
		limb.basis = Basis.IDENTITY
	_left_leg.position.y = .83
	_right_leg.position.y = .83
	for foot: Node3D in _slots.get("Feet", []): foot.basis = Basis.IDENTITY
	_left_hand.position = Vector3(0, -.22, 0)
	_right_hand.position = Vector3(0, -.22, 0)
	_spell_glow.visible = false
	_spell_glow.scale = Vector3.ONE * 0.20
	_throw_stone.visible = false
	_blade_trail.visible = false
	_second_blade_trail.visible = false
	_blade_trail.mesh = _blade_arc_mesh
	_second_blade_trail.mesh = _second_blade_arc_mesh
	_blade_trail.position = Vector3(0, 0, -.2)
	_second_blade_trail.position = Vector3(0, .12, -.25)
	_charge_aura.visible = false
	_release_flash.visible = false
	if is_instance_valid(_charge_spark):
		_charge_spark.visible = false
	_pose_bow_string(0.0)
	if is_instance_valid(_shield):
		_shield.position = Vector3(0, -.35, -.14)
		_shield.rotation = Vector3.ZERO
	if is_instance_valid(_dual_weapon):
		_dual_weapon.position = Vector3.ZERO
		_dual_weapon.rotation = Vector3(-.3, 0, 0)
		_left_arm.rotation.z = -.08
		_right_arm.rotation.z = .08
	if is_instance_valid(_weapon):
		_weapon.position = Vector3.ZERO
		_weapon.rotation = Vector3.ZERO
		if weapon_family == "CASTER" and "orb" in str(weapon_data.get("weapon_type", weapon_data.get("model_id", ""))).to_lower():
			_weapon.position = Vector3(0, 0.05 + sin(_clock * 3.0) * 0.025, -0.24)
		elif weapon_family in ["SINGLE_BLADE", "SHORT_WEAPON", "POLEARM", "HEAVY_2H"]:
			_weapon.rotation.x = -0.30

func _refresh_slot(slot: String) -> void:
	var item: Dictionary = equipment.get(slot, {})
	var style := _item_style(item)
	var fallback := _base_color
	if slot == "Legs":
		fallback = Color("304b55")
	elif slot in ["Feet", "Belt"]:
		fallback = LEATHER
	elif slot in ["Ring1", "Ring2", "Neck"]:
		fallback = GOLD
	var color := _item_color(item, fallback)
	for mount: Node3D in _slots.get(slot, []):
		for child in mount.get_children():
			mount.remove_child(child)
			child.queue_free()
		match slot:
			"Head":
				if item.is_empty():
					continue
				if "hood" in style:
					Art.sphere(mount, Vector3(0, 0.16, 0.05), Vector3(0.46, 0.42, 0.42), color)
					Art.box(mount, Vector3(0, 0.23, -0.16), Vector3(0.39, 0.12, 0.14), color)
					for x in [-0.185, 0.185]:
						Art.box(mount, Vector3(x, -0.005, -0.02), Vector3(0.09, 0.35, 0.30), color)
				elif "helm" in style:
					Art.sphere(mount, Vector3(0, 0.17, 0.04), Vector3(0.44, 0.33, 0.41), color)
					Art.box(mount, Vector3(0, 0.175, -0.19), Vector3(0.42, 0.075, 0.05), GOLD)
					Art.box(mount, Vector3(0, 0.31, 0.025), Vector3(0.055, 0.19, 0.30), _base_color)
					for x in [-0.185, 0.185]:
						Art.box(mount, Vector3(x, 0.01, 0.02), Vector3(0.085, 0.25, 0.28), color)
				else:
					Art.cylinder(mount, Vector3(0, 0.23, 0.025), 0.30, 0.055, color, 8)
					Art.cylinder(mount, Vector3(0, 0.35, 0.025), 0.20, 0.22, color, 8, 0.055)
			"Torso":
				Art.box(mount, Vector3(0, 0.13, 0), Vector3(0.48, 0.51, 0.32), color)
				Art.box(mount, Vector3(0, 0.16, -0.17), Vector3(0.055, 0.40, 0.025), GOLD)
				if "armor" in style or "plate" in style:
					Art.box(mount, Vector3(0, 0.16, -0.19), Vector3(0.38, 0.31, 0.09), color.lightened(0.2))
					for x in [-0.31, 0.31]:
						Art.sphere(mount, Vector3(x, 0.29, 0), Vector3(0.28, 0.24, 0.39), color)
				elif "robe" in style:
					Art.cylinder(mount, Vector3(0, -0.23, 0), 0.36, 0.48, color, 8, 0.25)
				else:
					Art.box(mount, Vector3(0, -0.08, 0), Vector3(0.51, 0.13, 0.35), color.darkened(0.08))
			"Legs":
				var lower: bool = mount.get_meta("lower_segment", false)
				Art.box(mount, Vector3(0, -.09 if lower else -.17, 0), Vector3(.205, .20 if lower else .35, .235), color)
				if "greave" in style or "iron" in style:
					Art.box(mount, Vector3(0, -.10 if lower else -.22, -.11), Vector3(.19, .18, .09), color.lightened(.3))
					if not lower: Art.box(mount, Vector3(0, -.17, -.13), Vector3(.22, .12, .095), GOLD)
			"Feet":
				var boot := "boot" in style
				Art.box(mount, Vector3(0, -0.095, -0.055), Vector3(0.225, 0.21, 0.37), color)
				Art.box(mount, Vector3(0, -0.195, -0.055), Vector3(0.24, 0.045, 0.39), color.darkened(0.35))
				if boot:
					Art.box(mount, Vector3(0, 0.065, 0), Vector3(0.235, 0.23, 0.255), color)
					Art.box(mount, Vector3(0, 0.12, -0.134), Vector3(0.095, 0.08, 0.035), GOLD)
			"Belt":
				Art.box(mount, Vector3.ZERO, Vector3(0.53, 0.095, 0.36), color)
				Art.box(mount, Vector3(0, 0, -0.195), Vector3(0.12, 0.10, 0.045), GOLD)
				if not item.is_empty():
					Art.box(mount, Vector3(0.26, -0.035, -0.05), Vector3(0.14, 0.18, 0.17), color.lightened(0.16))
			"Neck":
				if not item.is_empty():
					_local_line(mount, Vector3(-0.11, 0.025, 0), Vector3(0, -0.15, -0.04), 0.018, GOLD)
					_local_line(mount, Vector3(0.11, 0.025, 0), Vector3(0, -0.15, -0.04), 0.018, GOLD)
					Art.sphere(mount, Vector3(0, -0.16, -0.05), Vector3(0.085, 0.11, 0.04), color)
			"Ring1", "Ring2":
				if not item.is_empty():
					Art.box(mount, Vector3.ZERO, Vector3(0.09, 0.046, 0.024), GOLD)
					Art.sphere(mount, Vector3(0, 0, -0.019), Vector3(0.055, 0.065, 0.04), color)

func _node(parent: Node3D, label: String, at: Vector3 = Vector3.ZERO) -> Node3D:
	var result := Node3D.new()
	result.name = label
	result.position = at
	parent.add_child(result)
	return result

func _add_slot(slot: String, mount: Node3D) -> void:
	if not _slots.has(slot):
		_slots[slot] = []
	_slots[slot].append(mount)

func _slot_key(slot: String) -> String:
	match slot.to_lower():
		"head", "hat": return "Head"
		"torso", "chest", "body": return "Torso"
		"legs", "pants": return "Legs"
		"feet", "boots", "shoes": return "Feet"
		"belt", "waist": return "Belt"
		"neck", "necklace": return "Neck"
		"ring", "ring1", "ring_1": return "Ring1"
		"ring2", "ring_2": return "Ring2"
	return ""

func _item_style(item: Dictionary) -> String:
	var visual: Variant = item.get("visual", item.get("model_id", item.get("id", "")))
	if visual is Dictionary:
		return str(visual.get("style", visual.get("model", ""))).to_lower()
	return str(visual).to_lower()

func _item_color(item: Dictionary, fallback: Color) -> Color:
	var visual: Variant = item.get("visual", {})
	var value: Variant = item.get("color", fallback)
	if visual is Dictionary:
		value = visual.get("color", value)
	if value is Color:
		return value
	if value is String:
		return Color.from_string(value, fallback)
	return fallback
