extends SceneTree
## Bounded lifecycle checks on actual main-world physics and physical-key events.
const Repository = preload("res://rpg/save_repository.gd")
var game: Node
var actor: CharacterBody3D
var checks := 0
var failures: Array[String] = []
var tracking := false
var peak_frame_motion := 0.0
var workspace := ""
var start := Vector3(100, 10.04, 111)

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		var before: Vector3 = actor.global_position if is_instance_valid(actor) else Vector3.ZERO
		await physics_frame
		await process_frame
		if tracking and is_instance_valid(actor):
			var motion := before.distance_to(actor.global_position)
			peak_frame_motion = maxf(peak_frame_motion, motion)
			if motion > .115:
				print("STEP_LARGE_FRAME before=", before, " after=", actor.global_position, " distance=", motion, " active=", actor.surface_traversal.active, " reason=", actor.surface_traversal.last_reason, " state=", actor.combat.state, " velocity=", actor.velocity)
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)
func release() -> void:
	key(KEY_W, false)
	key(KEY_S, false)
	game._release_actions()
func box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var geometry := BoxShape3D.new()
	geometry.size = size
	collision.shape = geometry
	body.add_child(collision)
	game.world.add_child(body)
	body.global_position = at
	return body
func begin_step() -> bool:
	tracking = false
	release()
	actor.restore(start)
	await ticks(10)
	tracking = true
	key(KEY_W, true)
	for i in range(55):
		await ticks(1)
		if actor.surface_traversal.active:
			await ticks(2)
			print("STEP_BEGIN active=", actor.surface_traversal.active, " position=", actor.global_position, " path=", actor.surface_traversal.last_step)
			return actor.surface_traversal.active
	print("STEP_BEGIN failed at=", actor.global_position, " reason=", actor.surface_traversal.last_reason)
	return false

func run() -> void:
	root.size = Vector2i(1280, 720)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(18)
	actor = game.player
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	game.camera_yaw = 0
	box(Vector3(100, 9.8, 110), Vector3(14, .4, 18))
	box(Vector3(100, 10.15, 108), Vector3(4, .3, 3))
	var prepared: bool = await begin_step()
	var steps: int = actor.surface_traversal.steps
	await ticks(22)
	release()
	await ticks(4)
	check(prepared and not actor.surface_traversal.active and actor.surface_traversal.steps == steps + 1 and actor.global_position.y > 10.25, "physical W plans and completes one continuous 0.3m step")
	prepared = await begin_step()
	var before: Vector3 = actor.global_position
	steps = actor.surface_traversal.steps
	release()
	await ticks(16)
	var after: Vector3 = actor.global_position
	check(prepared and not actor.surface_traversal.active and actor.surface_traversal.steps == steps and Vector2(after.x-before.x, after.z-before.z).length() < .035, "releasing movement midway cancels old endpoint without horizontal drift")
	prepared = await begin_step()
	before = actor.global_position
	key(KEY_W, false)
	key(KEY_S, true)
	await ticks(10)
	release()
	check(prepared and not actor.surface_traversal.active and actor.global_position.z > before.z + .35, "opposite physical direction immediately walks away instead of finishing old step")
	prepared = await begin_step()
	before = actor.global_position
	actor.combat.force_control("HITSTUN", .35)
	await ticks(3)
	release()
	check(prepared and not actor.surface_traversal.active and actor.combat.state == "HITSTUN" and absf(actor.global_position.z-before.z) < .035, "HITSTUN cancels active path before any old-direction displacement")
	await ticks(24)
	prepared = await begin_step()
	tracking = false
	var destination := Vector3(103, 10.04, 112)
	actor.restore(destination)
	release()
	await ticks(16)
	check(prepared and not actor.surface_traversal.active and Vector2(actor.global_position.x-destination.x, actor.global_position.z-destination.z).length() < .035, "player.restore clears path and never pulls a teleported actor back")
	workspace = OS.get_temp_dir().path_join("mosslight-step-save-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var repository := Repository.new(workspace)
	var created: Dictionary = repository.create("跨阶恢复回归")
	var saved: Dictionary = repository.save(int(created.get("slot", -1)), "跨阶恢复回归", actor, game)
	prepared = await begin_step()
	tracking = false
	var restored: Dictionary = repository.restore(saved.get("snapshot", {}), actor, game)
	release()
	await ticks(16)
	check(prepared and created.ok and saved.ok and restored.ok and not actor.surface_traversal.active and absf(actor.global_position.x-destination.x) < .035 and absf(actor.global_position.z-destination.z) < .035, "validated disk snapshot restore clears in-flight path and preserves loaded position")
	prepared = await begin_step()
	var blocked_z: float = actor.global_position.z - .35
	var blocker := box(Vector3(100, 11, blocked_z), Vector3(1.5, 2, .08))
	steps = actor.surface_traversal.steps
	await ticks(16)
	release()
	check(prepared and not actor.surface_traversal.active and actor.surface_traversal.steps == steps and actor.global_position.z > blocked_z + .27, "new obstacle interrupts the swept path without penetrating or completing it")
	blocker.queue_free()
	await ticks(2)
	prepared = await begin_step()
	before = actor.global_position
	actor.health.receive(100000)
	await ticks(3)
	release()
	check(prepared and actor.combat.state == "DEAD" and not actor.surface_traversal.active and actor.global_position.distance_to(before) < .035, "death clears pending movement immediately without completing the old path")
	check(peak_frame_motion <= .115, "all uninterrupted and cancelled step frames remain below 0.115m at 60Hz")
	print("STEP_SAFETY_TRACE maximum_frame_motion=", peak_frame_motion)
	if DirAccess.dir_exists_absolute(workspace):
		var dir := DirAccess.open(workspace)
		for filename in dir.get_files(): DirAccess.remove_absolute(workspace.path_join(filename))
		DirAccess.remove_absolute(workspace)
	game.queue_free()
	tracking = false
	await process_frame
	print("CONTINUOUS_STEP_SAFETY_RESULT checks=", checks, " failures=", failures.size())
	quit(1 if not failures.is_empty() else 0)
