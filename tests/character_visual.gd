extends SceneTree
var actor: Node3D
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("PASS " if ok else "FAIL ", label)

func run() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	actor = load("res://scripts/kirito_visual.gd").new()
	stage.add_child(actor)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.8
	stage.add_child(camera)
	camera.look_at_from_position(Vector3(2.2,1.8,-4.5),Vector3(0,.9,0))
	camera.current = true
	var sun := DirectionalLight3D.new()
	stage.add_child(sun)
	sun.rotation_degrees = Vector3(-35,-30,0)
	sun.light_energy = 1.4
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("6b8d8a")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("c8e0df")
	env.environment.ambient_light_energy = .5
	stage.add_child(env)
	check(actor.skeleton.get_bone_count() == 112, "repaired source rig has 112 bones")
	check(actor.left_hand >= 0 and actor.right_hand >= 0, "both weapon anchors exist")
	var sane_meshes := true
	for mesh: MeshInstance3D in actor.find_children("*","MeshInstance3D",true,false):
		var box: AABB = mesh.get_aabb()
		print("MESH ",mesh.name," ",box)
		sane_meshes = sane_meshes and box.size.length() < 3.0
	check(sane_meshes,"source meshes use meters, including former morph-target geometry")
	var capture := DisplayServer.get_name() != "headless"
	if capture:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/character"))
	for motion in ["Idle","Run","Jump","Roll","Slash","Heavy","HoldSword","Bow","BowRelease","Heal"]:
		check(actor.animator.has_animation(motion),motion+" skeletal clip exists")
		actor.play_motion(motion,true)
		actor.animator.play(motion,0)
		actor.animator.seek(.18,true)
		actor.animator.advance(0)
		actor.animator.pause()
		await process_frame
		await process_frame
		var l: Vector3 = actor.hand_position(true)
		var r: Vector3 = actor.hand_position(false)
		check(l.is_finite() and r.is_finite() and l.length() < 2.5 and r.length() < 2.5,motion+" hand anchors remain attached to the body")
		if motion == "Bow":
			check(l.z < -.25, "bow pose extends the left hand in front of the body")
		if capture and motion in ["Idle","Run","Bow","Slash"]:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://docs/character/"+motion.to_lower()+".png")
	print("CHARACTER_TEST_RESULT %d/%d passed" % [checks-failures,checks])
	stage.queue_free()
	await process_frame
	quit(0 if failures==0 else 1)
