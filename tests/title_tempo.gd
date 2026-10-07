extends SceneTree
## The faster edit must preserve cloth/prop synchronization and reversible cameras.
var app: Node
var checks := 0
var failures: Array[String]=[]

func _initialize() -> void: call_deferred("run")
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func ticks(n: int) -> void:
	for i in range(n): await process_frame

func run() -> void:
	root.size=Vector2i(1280,720)
	app=load("res://scenes/frontend/app.tscn").instantiate()
	var directory := ProjectSettings.globalize_path("res://.work/title-tempo/check-saves-")+str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(directory)
	app.saves=app.SAVE_REPOSITORY.new(directory)
	root.add_child(app)
	app.set_process(false)
	await ticks(4)
	var actor: Node3D=app.meadow.sleeper
	var home: Transform3D=app.meadow.camera.transform
	app.new_adventure()
	app._process(.35)
	check(app.meadow.camera.position.distance_to(home.origin)>.4,"camera begins withdrawing during the initial get-up")
	check(home.basis.get_rotation_quaternion().angle_to(app.meadow.camera.basis.get_rotation_quaternion())>deg_to_rad(1),"camera pitch and yaw begin with the actor, not after standing")
	check(actor.performance_time>actor.STORY.RISE_START and actor.performance_time<actor.STORY.RISE_END,"the early camera movement overlaps the rising pose")
	check(app.shadow_camera.global_transform.is_equal_approx(app.meadow.camera.global_transform),"grass and lettering shadow camera follows the same rendered frame")
	var checkpoint: Transform3D=app.meadow.camera.transform
	var hip_index: int=actor.skeleton.find_bone("J_Bip_C_Hips")
	var hip: Vector3=actor.skeleton.get_bone_pose_position(hip_index)
	var cloth: float=actor.cloth_materials[0].get_shader_parameter("frame")
	app._process(.9)
	app.cancel_journey()
	app._process(.9)
	check(app.meadow.camera.transform.is_equal_approx(checkpoint),"Escape retraces the faster get-up camera exactly")
	check(actor.skeleton.get_bone_pose_position(hip_index).is_equal_approx(hip) and is_equal_approx(actor.cloth_materials[0].get_shader_parameter("frame"),cloth),"body and cloth retrace the same performance sample")
	app._process(.4)
	check(app.stage==app.Stage.TITLE and app.meadow.camera.transform.is_equal_approx(home),"reverse get-up ends at the original resting composition")
	for fps in [30,60,120]:
		app.new_adventure()
		var synchronized := true
		var level := true
		var moving := true
		var previous: Transform3D=home
		for frame in range(roundi(app.JOURNEY_SECONDS*fps)):
			app._process(1.0/fps)
			level=level and absf(app.meadow.camera.basis.x.y)<.0001
			synchronized=synchronized and is_equal_approx(actor.performance_time*30,actor.cloth_materials[0].get_shader_parameter("frame"))
			if frame>1 and frame<roundi(app.JOURNEY_SECONDS*fps)-2: moving=moving and previous.origin.distance_to(app.meadow.camera.position)>.00001
			previous=app.meadow.camera.transform
		app._process(.0001)
		check(moving and level,"continuous, level camera throughout the edit at %d FPS"%fps)
		check(synchronized,"cloth uses the accelerated body clock at %d FPS"%fps)
		check(app.stage==app.Stage.CHOOSING and actor.sword_attached,"the six-second edit finishes with sword sheathed at %d FPS"%fps)
		var end: Transform3D=app.meadow.camera.transform
		app.ascent_cursor=0
		app._sample_ascent()
		check(app.meadow.camera.transform.is_equal_approx(end),"horizon and departure share an identical camera endpoint at %d FPS"%fps)
		app.cancel_journey()
		app._process(.2)
		check(app.journey_cursor<1,"cancellation moves immediately while sky letters disperse at %d FPS"%fps)
		app._process(app.JOURNEY_SECONDS)
	app.new_adventure()
	app._process(app.JOURNEY_SECONDS+.01)
	app.choice.name_input.text="节奏验证"
	app.choice.age=2
	app.choice._confirm()
	check(app.stage==app.Stage.DISSOLVING,"actual name confirmation enters departure with a valid isolated save")
	app._process(.25)
	check(app.stage==app.Stage.DISSOLVING and app.ascent_cursor>0 and actor.performance_time>actor.STORY.CHOICE_TIME,"walking and crane movement overlap dispersing choice text")
	checkpoint=app.meadow.camera.transform
	var performance_time: float=actor.performance_time
	app._process(.3)
	app.cancel_journey()
	app._process(.3)
	check(app.meadow.camera.transform.is_equal_approx(checkpoint) and is_equal_approx(actor.performance_time,performance_time),"cancelling during text dispersal reverses the in-flight camera and actor")
	app._process(.26)
	app._process(app.JOURNEY_SECONDS+.01)
	check(app.stage==app.Stage.TITLE,"cancelled departure returns all the way to the resting title")
	app.start_adventure()
	app._process(app.JOURNEY_SECONDS+.01)
	app.choice.selected_slot=0
	app.choice.age=2
	app.choice._confirm()
	var elapsed := 0.0
	while app.stage in [app.Stage.DISSOLVING,app.Stage.ASCENDING] and elapsed<8:
		app._process(1.0/60)
		elapsed+=1.0/60
	check(app.stage==app.Stage.LOADING and elapsed<=app.ASCENT_SECONDS+.02,"dispersal adds no extra hold to the 5.4-second ascent")
	check(is_equal_approx(app.cloud_material.get_shader_parameter("cover"),1.0),"the faster edit still covers the world swap with opaque clouds")
	var deadline := Time.get_ticks_msec()+20000
	while app.stage==app.Stage.LOADING and Time.get_ticks_msec()<deadline:
		app._process(.05)
		await ticks(1)
	check(app.stage==app.Stage.DESCENDING and is_instance_valid(app.game),"real threaded world loading still reaches the arrival camera")
	if is_instance_valid(app.game):
		app._process(1)
		var arrival: Transform3D=app.game.camera.global_transform
		app._process(1)
		app.cancel_journey()
		app._process(1)
		check(arrival.is_equal_approx(app.game.camera.global_transform),"arrival cancellation still retraces its unchanged camera path")
		app._process(1.01)
		await ticks(2)
		app._process(app.ASCENT_SECONDS+.01)
		app._process(app.JOURNEY_SECONDS+.01)
		check(app.stage==app.Stage.TITLE and not is_instance_valid(app.game),"cancelled world arrival releases the world and restores the title")
	app.queue_free()
	await ticks(12)
	print("TITLE_TEMPO ",checks-failures.size(),"/",checks)
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
