extends SceneTree
## Inspect the actual pose controls and skinned bones for all three basic hits.
const Procedural = preload("res://combat/animation_controller.gd")
const Kirito = preload("res://combat/kirito_combat_visual.gd")
var checks := 0
var failures := 0
var lines: PackedStringArray = []

class VisualHost extends Node3D:
	var combat = null
	var facing := Vector3.FORWARD

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1
	var line := ("PASS " if ok else "FAIL ") + message
	print(line)
	lines.append(line)

func run() -> void:
	root.size = Vector2i(960, 960)
	var stage := Node3D.new()
	root.add_child(stage)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(2.6, 2.1, -4)
	camera.look_at(Vector3(0, .9, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4.3
	var sunlight := DirectionalLight3D.new()
	stage.add_child(sunlight)
	sunlight.rotation_degrees = Vector3(-42, -30, 0)
	var world_environment := WorldEnvironment.new()
	world_environment.environment = Environment.new()
	world_environment.environment.background_mode = Environment.BG_COLOR
	world_environment.environment.background_color = Color("273541")
	world_environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world_environment.environment.ambient_light_color = Color("e4edf3")
	world_environment.environment.ambient_light_energy = .7
	stage.add_child(world_environment)
	for visual_type in [Procedural, Kirito]:
		var host := VisualHost.new()
		stage.add_child(host)
		var visual = visual_type.new()
		host.add_child(visual)
		visual.setup(true)
		for family: String in ["SINGLE_BLADE", "HEAVY_2H"]:
			visual.switch_weapon_family(family)
			var poses: Array[Dictionary] = []
			var clips: PackedStringArray = []
			for index in range(3):
				visual.play_action({"id": "combo_visual_%d" % index, "semantic": "PRIMARY_TAP", "combo_index": index, "startup": .3, "active": .2, "recovery": .4})
				visual.update_pose(0, Vector3.FORWARD, "ACTION", "ACTIVE", .15)
				var pose: Dictionary = {"torso": visual._torso.rotation, "hand": visual._rig.to_local(visual._right_hand.global_position), "arm": visual._right_arm.rotation, "presentation": visual.current_animation}
				if visual is Kirito:
					pose["bone_hand"] = visual._bone_world("J_Bip_R_Hand").origin
					pose["bone_chest"] = visual._bone_world("J_Bip_C_Chest").basis
					clips.append(visual.skeletal_clip)
					check(visual.hand_attachment_error < .001, family + " stage %d weapon attaches to actual animated hand" % index)
				poses.append(pose)
				if DisplayServer.get_name() != "headless":
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png("res://docs/combat/combo_%s_%s_%d.png" % ["kirito" if visual is Kirito else "procedural", family.to_lower(), index])
			var label := ("Kirito " if visual is Kirito else "procedural ") + family
			check(poses[0].torso.y * poses[1].torso.y < -.02, label + " second strike reverses torso sweep")
			check(poses[0].hand.distance_to(poses[1].hand) > .20, label + " returning hand follows a distinct path")
			check(poses[2].arm.x > poses[0].arm.x + .7, label + " third strike raises the arm for overhead finish")
			check(poses[2].presentation.ends_with("overhead_finish"), label + " finisher has explicit distinct presentation")
			if visual is Kirito:
				check(clips == PackedStringArray(["SwordSlash", "SwordAlt", "HeavyChop"]), label + " three stages sample three actual source clips")
				check(poses[0].bone_hand.distance_to(poses[1].bone_hand) > .10 and poses[1].bone_hand.distance_to(poses[2].bone_hand) > .10, label + " all three stages change actual skinned hand position")
				check(poses[0].bone_chest != poses[1].bone_chest and poses[1].bone_chest != poses[2].bone_chest, label + " all three stages change actual skinned chest rotation")
		host.queue_free()
		await process_frame
		await process_frame
	var result := "UNIT_COMBO_VISUAL_RESULT checks=%d failures=%d" % [checks, failures]
	print(result)
	lines.append(result)
	var file := FileAccess.open("res://docs/combat/unit_combo_visual_test.log", FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()
	stage.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures == 0 else 1)
