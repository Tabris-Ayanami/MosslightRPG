extends SceneTree
## Small isolated render rig. No App, preferences, saves or world progress.
const Visual = preload("res://combat/kirito_combat_visual.gd")
class Host extends Node3D:
	var combat = null
	var facing := Vector3.FORWARD
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := "res://.work/arpg-next-20261001/motion-preview"
	DirAccess.make_dir_recursive_absolute(output)
	root.size = Vector2i(700, 700)
	var stage := Node3D.new()
	root.add_child(stage)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(2.5, 2.1, -4)
	camera.look_at(Vector3(0, .9, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 3.5
	var light := DirectionalLight3D.new()
	stage.add_child(light)
	light.rotation_degrees = Vector3(-42, -30, 0)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("23313d")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color("e4edf3")
	world.environment.ambient_light_energy = .7
	stage.add_child(world)
	var host := Host.new()
	stage.add_child(host)
	var visual := Visual.new()
	host.add_child(visual)
	visual.setup(true)
	visual.switch_weapon_family("SINGLE_BLADE")
	var db := CombatDatabase.new()
	var measurements: Array = []
	for step in range(3):
		var action := db.get_action("SINGLE_BLADE", "PRIMARY_TAP", step)
		visual.play_action(action)
		var frames := [["STARTUP", .1], ["STARTUP", .75], ["ACTIVE", 0.0], ["ACTIVE", .3], ["ACTIVE", .7], ["RECOVERY", .05], ["RECOVERY", .6], ["RECOVERY", 1.0]]
		for index in range(frames.size()):
			visual.update_pose(0, Vector3.FORWARD, "ACTION", frames[index][0], frames[index][1])
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output.path_join("s%d-%d.png" % [step + 1, index]))
			measurements.append({"step": step, "phase": frames[index][0], "progress": frames[index][1], "clip": visual.skeletal_clip, "time": visual.skeletal_time, "hand": str(visual._weapon.global_position), "tip": str(visual._weapon.to_global(Vector3(0, 0, -1.05))), "attachment_error": visual.hand_attachment_error})
		# Inspect the authored blade path, independent of gameplay retiming.
		var clip: String = action.motion.clip
		for index in range(roundi(visual.animator.get_animation(clip).length * 60) + 1):
			visual._sample_clip(clip, index / 60.0)
			var hand := visual._bone_world("J_Bip_R_Hand")
			var blade: Vector3 = hand.basis.orthonormalized() * visual._bone_rest_basis["J_Bip_R_Hand"].inverse() * Vector3.FORWARD
			measurements.append({"step": step, "source_time": index / 60.0, "tip": str(hand.origin + blade * 1.05), "hand": str(hand.origin)})
	var file := FileAccess.open(output.path_join("measurements.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(measurements, "\t"))
	file.close()
	stage.queue_free()
	for i in range(4): await process_frame
	print("MOTION_PREVIEW complete")
	quit()
