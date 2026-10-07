extends Node3D
## Imported, skinned Kirito model; gameplay remains in player.gd.
const SOURCE = preload("res://assets/characters/kirito/kirito.glb")
const MATERIAL = preload("res://shaders/character.gdshader")
var body: Node3D
var skeleton: Skeleton3D
var animator: AnimationPlayer
var motion := ""
var left_hand := -1
var right_hand := -1
var outfit = preload("res://scripts/kirito_outfit.gd").new()
var _pending_equipment: Dictionary = {}

func apply_equipment(equipment: Dictionary) -> void:
	_pending_equipment = equipment.duplicate(true)
	if is_instance_valid(body):
		outfit.apply(body, equipment)

func _exit_tree() -> void:
	if is_instance_valid(body):
		for mesh: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
			mesh.material_overlay = null
			mesh.mesh = null

func _ready() -> void:
	body = SOURCE.instantiate()
	body.name = "Kirito"
	body.rotation.y = PI
	body.scale = Vector3.ONE * 1.08
	add_child(body)
	_prepare(body)
	left_hand = skeleton.find_bone("L_Hand")
	right_hand = skeleton.find_bone("J_Bip_R_Hand")
	for clip in animator.get_animation_list():
		if clip in ["Idle", "Run", "Jump", "Roll", "HoldSword", "Bow", "Heal"]:
			animator.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	play_motion("Idle")
	animator.advance(0)
	if not _pending_equipment.is_empty():
		apply_equipment(_pending_equipment)

func _prepare(node: Node) -> void:
	if node is Skeleton3D:
		skeleton = node
	if node is AnimationPlayer:
		animator = node
	if node is MeshInstance3D:
		for surface in range(node.mesh.get_surface_count()):
			var original := node.mesh.surface_get_material(surface) as StandardMaterial3D
			if original == null:
				continue
			var mat := ShaderMaterial.new()
			mat.shader = MATERIAL
			mat.set_shader_parameter("albedo_texture", original.albedo_texture)
			mat.set_shader_parameter("has_texture", original.albedo_texture != null)
			mat.set_shader_parameter("tint", original.albedo_color)
			mat.set_shader_parameter("cutout", "hair" in original.resource_name.to_lower())
			node.set_surface_override_material(surface, mat)
		# Animation can move the coat and limbs beyond the bind-pose AABB.
		node.extra_cull_margin = 1.5
	for child in node.get_children():
		_prepare(child)

func play_motion(next: String, restart := false, speed := 1.0) -> void:
	if animator == null:
		return
	animator.speed_scale = speed
	if next != motion or restart:
		motion = next
		animator.play(next, .10 if next in ["Idle", "Run", "Bow"] else .05)

func hand_position(left: bool) -> Vector3:
	var bone := left_hand if left else right_hand
	if bone < 0:
		return Vector3(-.35 if left else .35, .8, 0)
	return to_local(skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin)
