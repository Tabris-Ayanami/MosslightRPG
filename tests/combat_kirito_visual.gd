extends SceneTree
## Independent GPU validation of the shared original-mesh combat adapter.
const Visual = preload("res://combat/kirito_combat_visual.gd")
const Database = preload("res://combat/combat_database.gd")
const OUTPUT := "res://docs/combat/"
var hero
var database
var checks := 0
var failures := 0
var captures: PackedStringArray = []
var report: PackedStringArray = []

func _initialize() -> void:
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	var line := ("PASS " if ok else "FAIL ") + label
	print(line)
	report.append(line)

func pose(state: String, phase: String = "NONE", progress: float = 0.0) -> void:
	for i in range(3):
		hero.update_pose(1.0 / 60.0, Vector3.FORWARD, state, phase, progress)
		await process_frame
	await RenderingServer.frame_post_draw

func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var error := root.get_texture().get_image().save_png(OUTPUT + label + ".png")
	verify(error == OK, "capture " + label)
	captures.append(label + ".png")

func fingerprint() -> String:
	var values := []
	for index in range(hero.skeleton.get_bone_count()):
		values.append(hero.skeleton.get_bone_pose_rotation(index))
	return str(values)

func assert_attachments(label: String) -> void:
	verify(hero.hand_attachment_error < .001, label + " meshes attach to actual hand joints")
	var finite := true
	for index in range(hero.skeleton.get_bone_count()):
		finite = finite and hero.skeleton.get_bone_global_pose(index).is_finite()
	verify(finite, label + " all skin joint transforms stay finite")

func run() -> void:
	root.size = Vector2i(1280, 720)
	var stage := Node3D.new()
	root.add_child(stage)
	hero = Visual.new()
	stage.add_child(hero)
	hero.setup(true)
	database = Database.new()
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 3.2
	stage.add_child(camera)
	camera.look_at_from_position(Vector3(2.2, 1.8, -4.5), Vector3(0, .9, 0))
	camera.current = true
	var sun := DirectionalLight3D.new()
	stage.add_child(sun)
	sun.rotation_degrees = Vector3(-35, -30, 0)
	sun.light_energy = 1.4
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("6b8d8a")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("c8e0df")
	environment.environment.ambient_light_energy = .5
	stage.add_child(environment)
	verify(hero.skeleton.get_bone_count() == 112, "original Kirito 112-bone rig is reused")
	verify(hero.animator.get_animation_list().size() == 16, "16 real CC0 retargeted clips are loaded")
	var originals: Array = hero.kirito.find_children("*", "MeshInstance3D", true, false)
	var shader_preserved := true
	for mesh: MeshInstance3D in originals:
		for surface in range(mesh.mesh.get_surface_count()):
			var material = mesh.get_active_material(surface)
			shader_preserved = shader_preserved and material is ShaderMaterial and material.shader.resource_path == "res://shaders/character.gdshader"
	verify(shader_preserved, "original character shader and texture materials remain intact")
	hero.set_weapon_visible(false)
	await pose("NORMAL")
	var empty_slot_hidden: bool = not hero._weapon.visible
	hero.set_weapon_visible(true)
	await pose("NORMAL")
	verify(empty_slot_hidden and hero._weapon.visible, "empty weapon slot stays hidden through pose updates and re-equipping restores it")
	await pose("NORMAL")
	var idle_pose := fingerprint()
	await capture("kirito_combat_idle_1280")
	hero.play_locomotion(true)
	await pose("NORMAL")
	verify(fingerprint() != idle_pose and hero.skeletal_clip == "Run", "movement samples a real skeletal run clip")
	hero.play_locomotion(false)
	for id: String in ["iron_longsword", "hunter_dagger", "border_spear", "bone_greataxe", "shortbow", "apprentice_staff", "storm_orb"]:
		var weapon: Dictionary = database.weapons[id]
		hero.switch_weapon_family(weapon.animation_family, weapon)
		var action: Dictionary = database.get_action(weapon.animation_family, "PRIMARY_TAP").duplicate(true)
		hero.play_action(action)
		await pose("ACTION", "ACTIVE", .45)
		assert_attachments(id)
		verify(fingerprint() != idle_pose, id + " action deforms the real skinned model")
		await capture("kirito_family_" + id + "_1280")
		if weapon.animation_family == "BOW":
			hero.play_charge(database.get_action("BOW", "PRIMARY_CHARGE"))
			await pose("CHARGING", "CHARGE", .65)
			verify(hero.skeletal_clip == "Kirito/Bow", "bow hold samples the existing Kirito drawing pose")
			verify(hero.hand_position(false).y > 1.0, "bow draw raises the string hand instead of retaining idle")
			await capture("kirito_bow_charge_1280")
	hero.switch_weapon_family("SINGLE_BLADE", database.weapons.iron_longsword)
	hero.equip_dual_swords(database.weapons.azure_katana)
	var dual := {"dual_wield": true, "is_skill": true, "dual_weapon_order": [1, 0], "dual_sequence": {"template": "spin"}, "startup": .1, "active": .44, "recovery": .1, "dual_first_active": .2, "dual_second_at": .34}
	hero.play_action(dual)
	hero.play_dual_strike(0)
	await pose("ACTION", "ACTIVE", .2)
	var left_pose := fingerprint()
	verify(hero._second_blade_trail.visible and not hero._blade_trail.visible, "left B skill segment has its own trail")
	await capture("kirito_dual_left_b_1280")
	hero.play_dual_strike(1)
	await pose("ACTION", "ACTIVE", .75)
	verify(fingerprint() != left_pose and hero._blade_trail.visible and not hero._second_blade_trail.visible, "right A skill segment mirrors the left on real skin joints")
	assert_attachments("dual mirrored skill")
	await capture("kirito_dual_right_a_1280")
	hero.equip_dual_swords({})
	hero.equip_shield(database.shields.wooden_shield)
	await pose("GUARD")
	verify(hero.skeletal_clip == "ShieldGuard", "guard uses retargeted skeletal shield stance")
	await capture("kirito_shield_guard_1280")
	hero.set_precision_glow(true)
	await pose("GUARD")
	verify(originals.all(func(mesh): return mesh.material_overlay == hero.precision_material), "precision rim overlay covers original skin meshes without replacing materials")
	await capture("kirito_precision_glow_1280")
	hero.set_precision_glow(false)
	verify(originals.all(func(mesh): return mesh.material_overlay == null), "precision overlay clears immediately")
	hero.flash_body(Color.RED, .25)
	await pose("GRABBING")
	await capture("kirito_grab_red_1280")
	for i in range(18):
		hero.update_pose(1.0 / 60.0, Vector3.FORWARD, "NORMAL", "NONE", 0)
	verify(hero.body_flash_remaining <= 0 and originals.all(func(mesh): return mesh.material_overlay == null), "red grab warning expires cleanly")
	hero.equip_shield({})
	hero.play_action({"counter_stance": {"start": .1, "end": .8}, "id": "duelist_fujian"})
	await pose("ACTION", "ACTIVE", .5)
	verify((-hero._weapon.global_basis.z).y < -.6, "fujian blade points down behind the back from shoulder grip")
	await capture("kirito_fujian_1280")
	for pair in [["head", "iron_helm"], ["torso", "plate_armor"], ["legs", "iron_greaves"], ["feet", "hunter_boots"]]:
		hero.equip(pair[0], database.equipment[pair[1]])
	await pose("NORMAL")
	verify(not hero._slots.Head[0].visible and not hero._slots.Torso[0].visible and not hero._slots.Feet[0].visible and hero.kirito.outfit.surfaces.size() == 3, "clothing uses the original skin with three dyed surfaces and no armor primitives")
	await capture("kirito_equipment_1280")
	for state: String in ["HITSTUN", "GUARD_BROKEN", "DODGE", "DEAD"]:
		await pose(state)
		assert_attachments(state)
	var summary := "COMBAT_KIRITO_VISUAL_RESULT checks=%d failures=%d captures=%d" % [checks, failures, captures.size()]
	print(summary)
	report.append(summary)
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("Captures: " + ", ".join(captures))
	var file := FileAccess.open(OUTPUT + "kirito_visual_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	quit(0 if failures == 0 else 1)
