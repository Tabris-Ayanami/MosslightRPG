extends SceneTree
## Real F/W/S through the main frontend for both skinned hero and possessed unit.
## Assertions inspect joint transforms and hand/foot trajectories, not just flags.
const Kirito = preload("res://combat/kirito_combat_visual.gd")
const OUTPUT := "res://docs/combat/"
var app: Node
var game: Node
var actor: Node
var visual: Node
var ladder: Node3D
var checks := 0
var failures := 0
var captures := 0
var report: PackedStringArray = []
var previews: Dictionary = {}
var samples: Array[Dictionary] = []
var frame_index := 0

func _initialize() -> void: call_deferred("run")
func tick(count := 1) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	var line := ("PASS " if ok else "FAIL ") + label
	print(line)
	report.append(line)
func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await tick(2)
func tap(code: Key) -> void:
	await key(code, true)
	await key(code, false)
func pose() -> Dictionary:
	var result: Dictionary = {}
	if visual is Kirito:
		for pair in [["left_hand", "L_Hand"], ["right_hand", "J_Bip_R_Hand"], ["left_foot", "J_Bip_L_Foot"], ["right_foot", "J_Bip_R_Foot"]]:
			result[pair[0]] = visual._rig.to_local(visual._bone_world(pair[1]).origin)
		for name in ["J_Bip_L_UpperArm", "J_Bip_R_UpperArm", "J_Bip_L_LowerArm", "J_Bip_R_LowerArm", "J_Bip_L_UpperLeg", "J_Bip_R_UpperLeg", "J_Bip_L_LowerLeg", "J_Bip_R_LowerLeg"]:
			result[name] = visual.skeleton.get_bone_global_pose(visual._bones[name])
	else:
		for pair in [["left_hand", visual._left_hand], ["right_hand", visual._right_hand], ["left_foot", visual._slots.Feet[0]], ["right_foot", visual._slots.Feet[1]]]:
			result[pair[0]] = visual._rig.to_local(pair[1].global_position)
		for node: Node3D in [visual._left_arm, visual._right_arm, visual._left_forearm, visual._right_forearm, visual._left_leg, visual._right_leg, visual._left_shin, visual._right_shin]:
			result[node.name] = node.transform
	return result
func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(OUTPUT + "climbing_" + label + ".png") == OK, "capture " + label)
	captures += 1
func pose_difference(a: Dictionary, b: Dictionary) -> float:
	var difference := 0.0
	for key_name: String in a:
		if a[key_name] is Vector3:
			difference = maxf(difference, a[key_name].distance_to(b[key_name]))
		elif a[key_name] is Transform3D:
			var before: Transform3D = a[key_name]
			var after: Transform3D = b[key_name]
			difference = maxf(difference, before.origin.distance_to(after.origin))
			for column: int in range(3):
				difference = maxf(difference, before.basis[column].distance_to(after.basis[column]))
	return difference
func record(label: String, stage: String, count: int) -> void:
	for i in range(count):
		await tick()
		var sample := pose()
		sample["phase"] = actor.ladder.phase
		sample["stage"] = stage
		samples.append(sample)
		if DisplayServer.get_name() != "headless" and i % 3 == 0:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(str(previews[label].directory).path_join("frame_%04d.png" % frame_index))
			var screen: Vector2 = game.world_to_screen(actor.global_position + Vector3.UP * .8)
			previews[label].points.append([screen.x, screen.y])
			previews[label].stages.append(stage)
			frame_index += 1
func reset_at_bottom() -> void:
	actor.ladder.cleanup()
	actor.combat.reset()
	actor.global_position = ladder.bottom_exit() + Vector3.UP * .02
	actor.velocity = Vector3.ZERO
	game.aim_override = actor.global_position + ladder.facing_direction() * 4
	await tick(10)
	await tap(KEY_F)
func exercise(label: String) -> void:
	visual = actor.animation
	await reset_at_bottom()
	check(actor.ladder.active and visual.climbing_active, label + " actual F enters shared climbing animation")
	var initial := pose()
	check(visual.current_animation == "climb_hold" and initial.left_hand.y > 1.05 and initial.right_hand.y > 1.05, label + " grips ladder with both real hands above relaxed height")
	check(visual._torso.to_local(visual._weapon.global_position).z > .1 and visual._weapon.global_position.distance_to(visual._right_hand.global_position) > .3, label + " sword is stowed behind torso and leaves hands free")
	await key(KEY_W, true)
	await tick(36)
	await key(KEY_W, false)
	check(actor.ladder.active and pose() != initial, label + " physical W changes actual limb pose while rising")
	await capture(label + "_default_1080")
	game.target_camera_height = 8
	game.camera_yaw = game.DEFAULT_CAMERA_YAW + .48
	await tick(30)

	frame_index = 0
	samples.clear()
	var directory := OS.get_temp_dir().path_join("mosslight-climb-%s-%d" % [label, OS.get_process_id()])
	DirAccess.make_dir_recursive_absolute(directory)
	previews[label] = {"directory": directory, "points": [], "stages": [], "sample_interval_seconds": .05}
	await key(KEY_W, true)
	await record(label, "up", 48)
	await key(KEY_W, false)
	var raised := pose()
	var position: Vector3 = actor.global_position
	var phase: float = actor.ladder.phase
	await record(label, "hold", 18)
	var drift := pose_difference(pose(), raised)
	check(drift < .001 and actor.global_position == position and actor.ladder.phase == phase, label + " released W holds four-limb pose and location (sub-millimetre transform drift %.8f)" % drift)
	check(visual.current_animation == "climb_hold", label + " stationary grip uses hold presentation")
	await capture(label + "_hold_close_1080")
	for endpoint: String in ["left_hand", "right_hand", "left_foot", "right_foot"]:
		var lowest := INF
		var highest := -INF
		for sample: Dictionary in samples:
			lowest = minf(lowest, sample[endpoint].y)
			highest = maxf(highest, sample[endpoint].y)
		check(highest - lowest > .08, label + " actual " + endpoint + " alternates by %.3f m" % (highest - lowest))
	var a: Dictionary = samples[4]
	var b: Dictionary = samples[16]
	var left_shift: float = b.left_hand.y - a.left_hand.y
	var right_shift: float = b.right_hand.y - a.right_hand.y
	check(left_shift * right_shift < -.0001, label + " hands alternate opposite reaches rather than moving together")
	# Evaluate opposition over the recorded cycle. Comparing just two adjacent
	# poses can select the same planted-rung plateau for a short-legged rig.
	var left_values: Array[float] = []
	var right_values: Array[float] = []
	for sample: Dictionary in samples:
		if sample.stage == "up":
			left_values.append(sample.left_foot.y)
			right_values.append(sample.right_foot.y)
	var mean_left: float = left_values.reduce(func(sum, value): return sum + value, 0.0) / left_values.size()
	var mean_right: float = right_values.reduce(func(sum, value): return sum + value, 0.0) / right_values.size()
	var covariance := 0.0
	for i: int in range(left_values.size()):
		covariance += (left_values[i] - mean_left) * (right_values[i] - mean_right) / left_values.size()
	check(covariance < -.0005, label + " feet alternate opposite steps across the climb cycle (covariance %.5f)" % covariance)
	await key(KEY_S, true)
	var previous_phase: float = actor.ladder.phase
	await tick()
	check(wrapf(actor.ladder.phase - previous_phase, -.5, .5) < 0, label + " physical S reverses displacement-driven animation phase")
	await record(label, "down", 21)
	await key(KEY_S, false)
	check(actor.global_position.y < position.y - .4 and pose() != raised, label + " descending changes real joints while lowering body")
	await capture(label + "_down_close_1080")
	await tap(KEY_F)
	check(not actor.ladder.active and not visual.climbing_active and not visual.current_animation.begins_with("climb"), label + " manual F clears climbing pose immediately")
	if label == "soldier":
		check(visual._left_forearm.rotation.is_zero_approx() and visual._right_forearm.rotation.is_zero_approx() and visual._left_shin.rotation.is_zero_approx() and visual._right_shin.rotation.is_zero_approx(), "procedural elbow and knee offsets reset after exit")
	await reset_at_bottom()
	actor.combat.force_control("HITSTUN", .4)
	# Tick the real traversal synchronously to inspect the exit frame before any
	# subsequent normal Actor animation update could hide a wrong NORMAL pose.
	actor.ladder.tick(1.0 / 60)
	check(not actor.ladder.active and not visual.climbing_active and actor.combat.state == "HITSTUN" and visual.current_animation == "hitstun", label + " interrupted exit preserves HITSTUN on the very same presentation frame")
	if label == "hero": check(visual.skeletal_clip == "Hit", "hero interrupted exit samples actual Hit bones instead of idle")
	await reset_at_bottom()
	actor.resources.change("HP", -actor.resources.current("HP"))
	actor.ladder.tick(1.0 / 60)
	check(not actor.ladder.active and not visual.climbing_active and actor.combat.state == "DEAD" and visual.current_animation == "dead", label + " death clears climbing while retaining death pose")
	if label == "hero": check(visual.skeletal_clip == "Death", "hero death exit samples actual Death clip")
	actor.combat.reset()
	actor.global_position = ladder.bottom_exit() + Vector3.RIGHT * 3
	await tick(3)
	game.target_camera_height = game.DEFAULT_CAMERA_HEIGHT
	game.camera_yaw = game.DEFAULT_CAMERA_YAW
	await tick(30)

func exercise_ogre() -> void:
	actor = game.combat_world.spawn_enemy("ogre", ladder.bottom_exit() + Vector3.UP * .02)
	actor.brain.aggressive = false
	visual = actor.animation
	check(game.combat_world.control.possess(actor, 60), "real possession supplies large ogre body")
	await reset_at_bottom()
	check(actor.ladder.active and visual.climbing_active, "ogre enters actual ladder with its original scaled collision")
	if actor.ladder.active:
		await exercise("ogre")
	game.combat_world.control.release()
func run() -> void:
	Input.use_accumulated_input = false
	# GPU readbacks can be slower than 60 Hz. Keep test input steps tied to
	# one simulation step instead of consuming several catch-up steps per PNG.
	Engine.max_physics_steps_per_frame = 1
	root.size = Vector2i(1920, 1080)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	await tick(3)
	app._enter_world(load("res://scenes/main.tscn"))
	await tick(3)
	app._finish_arrival()
	game = app.game
	app.ui.close_panel(true)
	app.ui.career_picker = false
	app.ui.region_clock = 0
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	actor = game.player
	check(actor.progression.choose_career("warrior"), "real protagonist equips sword through progression")
	ladder = game.reference_map.get_node("NorthernVillage/VillageHouseLadder")
	await exercise("hero")
	actor = game.combat_world.spawn_enemy("soldier", ladder.bottom_exit() + Vector3.UP * .02)
	actor.brain.aggressive = false
	check(game.combat_world.control.possess(actor, 60), "real possession supplies ordinary procedural soldier for climbing")
	await exercise("soldier")
	check(game.combat_world.control.possess(actor, 60), "soldier can be controlled again after death/reset")
	await reset_at_bottom()
	game.combat_world.control.release()
	check(not actor.ladder.active and not actor.animation.climbing_active, "releasing controlled climber clears both traversal and visual flags")
	await exercise_ogre()
	actor = game.player
	await reset_at_bottom()
	check(actor.form.apply_enemy_form("fire_elemental", 2) and not actor.ladder.active and not actor.animation.climbing_active, "changing unit form on ladder clears old pose and starts replacement model clean")
	actor.form.restore()
	game._release_actions()
	if DisplayServer.get_name() != "headless":
		var output := FileAccess.open(OUTPUT + "climbing_preview_metadata.json", FileAccess.WRITE)
		output.store_string(JSON.stringify(previews, "\t"))
		output.close()
	app.queue_free()
	await tick(4)
	var result := "UNIT_CLIMBING_VISUAL_RESULT checks=%d failures=%d captures=%d" % [checks, failures, captures]
	print(result)
	report.append(result)
	report.append("UTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	var file := FileAccess.open(OUTPUT + "unit_climbing_visual_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	file.close()
	quit(0 if failures == 0 else 1)
