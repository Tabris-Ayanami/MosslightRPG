extends SceneTree
const RIG=preload("res://tools/title_performance_rig.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	DirAccess.make_dir_recursive_absolute("res://.work/motion-integration/")
	var stage := Node3D.new()
	root.add_child(stage)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode=Environment.BG_COLOR
	env.background_color=Color("c3cdc2")
	env.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color=Color.WHITE
	env.ambient_light_energy=.6
	env_node.environment=env
	stage.add_child(env_node)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-48,-28,0)
	sun.shadow_enabled=true
	sun.light_energy=1.3
	stage.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size=Vector2(100,100)
	ground.mesh=plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color=Color("859c83")
	ground.material_override=mat
	stage.add_child(ground)
	var camera := Camera3D.new()
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=6.0
	stage.add_child(camera)
	var actor=RIG.new()
	stage.add_child(actor)
	for seconds: float in [0,1,1.45,1.65,1.9,2.4,3.4,4.2,5.4,6.5,7.2,8.6,10,10.5,12.2]:
		actor.apply_time(seconds)
		var target: Vector3=actor.STORY.FACING*actor.STORY.distance_at(seconds)
		camera.look_at_from_position(target+Vector3(5,4.4,7),target+Vector3(0,1.35,0))
		print("POSE ",seconds," error=",actor.chain_errors," palm=",actor.point("L_Hand")," goal=",actor.contact_targets.get("L_Hand")," soles=",actor._sole_min("L")," / ",actor._sole_min("R"))
		for i in range(3): await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://.work/motion-integration/rig-%04d.png"%roundi(seconds*100))
	stage.queue_free()
	for i in range(4): await process_frame
	quit()
