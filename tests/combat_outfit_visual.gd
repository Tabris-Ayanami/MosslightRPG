extends "res://tests/combat_charge_visual.gd"
## Actual equipment callbacks, unchanged skinned geometry, isolated preview dyes.
const Kirito = preload("res://scripts/kirito_visual.gd")
var actor
var visual
var preview

func geometry_signature(character) -> Array:
	var result := []
	for mesh: MeshInstance3D in character.body.find_children("*", "MeshInstance3D", true, false):
		for surface in range(mesh.mesh.get_surface_count()):
			var arrays: Array = mesh.mesh.surface_get_arrays(surface)
			for index in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS, Mesh.ARRAY_INDEX]:
				result.append(hash(arrays[index]))
	return result

func normal_difference(first, second) -> float:
	var result := 0.0
	var a: Array = first.body.find_children("*", "MeshInstance3D", true, false)
	var b: Array = second.body.find_children("*", "MeshInstance3D", true, false)
	for i in range(a.size()):
		for surface in range(a[i].mesh.get_surface_count()):
			var na: PackedVector3Array = a[i].mesh.surface_get_arrays(surface)[Mesh.ARRAY_NORMAL]
			var nb: PackedVector3Array = b[i].mesh.surface_get_arrays(surface)[Mesh.ARRAY_NORMAL]
			for index in range(na.size()):
				result = maxf(result, na[index].distance_to(nb[index]))
	return result

func protected_materials(character) -> Array:
	var result := []
	for mesh: MeshInstance3D in character.body.find_children("*", "MeshInstance3D", true, false):
		for surface in range(mesh.mesh.get_surface_count()):
			var source: Material = mesh.mesh.surface_get_material(surface)
			if source and ("hair" in source.resource_name or "tou" in source.resource_name or "gloves" in source.resource_name):
				result.append(mesh.get_surface_override_material(surface))
	return result

func equip_set(items: Dictionary, label: String) -> void:
	for slot in items:
		verify(actor.loadout.equip_item(slot, items[slot]), label + " actual equip " + slot)
	await tick(4)
	verify(visual.kirito.outfit.equipment.get("torso", {}).id == items.torso, label + " actor receives real outfit material data")
	var no_primitives := true
	for mounts in visual._slots.values():
		for mount in mounts:
			no_primitives = no_primitives and not mount.visible
	verify(no_primitives, label + " creates no armor or hat replacement geometry")

func punch(expected: String, secondary: bool = false) -> void:
	await mouse(true, secondary)
	await mouse(false, secondary)
	var waited := 0
	while actor.combat.runner.action_phase != "ACTIVE" and waited < 40:
		await tick()
		waited += 1
	await tick(2)
	verify(actor.combat.runner.current_action.get("punch_hand", "") == expected, "real " + expected + " punch action is routed")
	verify(visual.punch_hand == expected and visual.punch_extension > .3, "real skeleton extends the " + expected + " fist")
	verify(not visual._weapon.visible and not visual._blade_trail.visible and not visual._second_blade_trail.visible, "unarmed action has no weapon mesh or sword trail")
	var left: Vector3 = visual._rig.to_local(visual._bone_world("L_Hand").origin)
	var right: Vector3 = visual._rig.to_local(visual._bone_world("J_Bip_R_Hand").origin)
	verify(left.z < right.z - .08 if expected == "left" else right.z < left.z - .08, "punching hand reaches ahead of the guarded hand")
	await capture("outfit_unarmed_" + ("heavy" if secondary else expected) + "_1080")
	while actor.combat.runner.busy():
		await tick()

func run() -> void:
	root.size = Vector2i(1920, 1080)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	await tick(5)
	actor = arena.player
	visual = actor.animation
	arena.ui.toggle_menu(false)
	arena.toast_time = 0
	arena.renderer.camera_height = 8
	arena.renderer.target_camera_height = 8
	actor.facing = Vector3(.38, 0, .93).normalized()
	arena.aim_override = actor.global_position + actor.facing * 4
	for enemy in arena.enemies:
		enemy.set_physics_process(false)
	await tick(30)
	verify(visual.weapon_family == "UNARMED", "real Lv0 uses the unarmed visual family")
	await punch("left")
	await punch("right")
	await punch("right", true)
	verify(actor.loadout.select_career("warrior"), "real warrior equipment fixture is ready")
	await tick(15)
	var original_shape := geometry_signature(visual.kirito)
	var protected := protected_materials(visual.kirito)
	preview = Kirito.new()
	preview.visible = false
	arena.actor_parent.add_child(preview)
	var preview_shape := geometry_signature(preview)
	verify(original_shape == preview_shape, "clothing mask exactly preserves original vertices, UV, bones, weights and indices")
	# ArrayMesh octahedral-normal repacking differs by at most one quantization
	# step; geometry/skin arrays above remain byte-identical.
	verify(normal_difference(visual.kirito, preview) < .0002, "original normals remain within one render-packing quantization step")
	await capture("outfit_original_1080")
	await equip_set({"head": "scout_hood", "torso": "linen_tunic", "legs": "traveler_pants", "feet": "soft_shoes", "belt": "vigor_belt", "neck": "scholar_pendant", "ring1": "qi_ring", "ring2": "hunter_ring"}, "linen")
	verify(geometry_signature(visual.kirito) == original_shape, "linen outfit keeps exactly the original modeled shape")
	verify(protected_materials(visual.kirito) == protected, "linen outfit preserves face, hair and hand materials")
	var linen: ShaderMaterial = visual.kirito.outfit.surfaces[0].material
	verify(linen.get_shader_parameter("torso_pattern") == 1 and linen.get_shader_parameter("torso_color") == Color("D6BA89"), "linen uses its catalog colour and woven pattern")
	await capture("outfit_linen_1080")
	preview.apply_equipment(actor.loadout.equipment)
	verify(preview.outfit.equipment.torso.id == "linen_tunic", "independent book-style Kirito accepts slot-to-item-ID equipment directly")
	verify(preview.outfit.surfaces[0].material != linen, "each Kirito instance owns separate outfit materials")
	await equip_set({"head": "iron_helm", "torso": "plate_armor", "legs": "iron_greaves", "feet": "hunter_boots"}, "armor")
	verify(geometry_signature(visual.kirito) == original_shape and visual.skeleton.get_bone_count() == 112, "armor keeps original shape and all 112 bones")
	verify(protected_materials(visual.kirito) == protected, "armor preserves face, hair and hands")
	verify(preview.outfit.surfaces[0].material.get_shader_parameter("torso_color") == Color("D6BA89"), "changing the live actor never recolours the independent preview")
	await capture("outfit_armor_1080")
	for slot in actor.loadout.SLOTS:
		verify(actor.loadout.equip_item(slot, ""), "actual unequip " + slot)
	await tick(3)
	var restored := true
	for entry in visual.kirito.outfit.surfaces:
		restored = restored and entry.mesh.get_surface_override_material(entry.surface) == entry.original
	verify(restored, "removing all clothes restores original texture shader materials")
	await capture("outfit_restored_1080")
	var summary := "COMBAT_OUTFIT_VISUAL_RESULT checks=%d failures=%d captures=%d" % [checks, failures, images.size()]
	print(summary)
	report.append(summary)
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	var file := FileAccess.open(OUTPUT + "outfit_visual_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	quit(0 if failures == 0 else 1)
