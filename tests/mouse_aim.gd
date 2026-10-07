extends SceneTree
## Real display mouse coordinates, both pixel presenters, and actual action starts.
const Preferences = preload("res://rpg/game_preferences.gd")
var app: Node
var arena: Node
var presenter: Node
var hero: Node
var origin: Vector3
var pointer_position := Vector2.ZERO
var started: Array[Dictionary] = []
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", label)
func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
func mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = root.get_final_transform() * pointer_position
	event.global_position = event.position
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)
func pointer(point: Vector3) -> void:
	for i in range(3):
		pointer_position = presenter.world_to_screen(point)
		if DisplayServer.get_name() != "headless":
			root.grab_focus()
			root.warp_mouse(pointer_position)
		var event := InputEventMouseMotion.new()
		event.position = root.get_final_transform() * pointer_position
		event.global_position = event.position
		Input.parse_input_event(event)
		await ticks(1)
func tap_attack(button := MOUSE_BUTTON_LEFT) -> void:
	mouse(button, true)
	await ticks(2)
	mouse(button, false)
	await ticks(2)
func record(action: Dictionary) -> void:
	started.append({"action": action.duplicate(true), "direction": hero.combat.action_direction, "point": hero.combat.action_point})
func flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x-b.x, a.z-b.z).length()
func expected_direction(point: Vector3) -> Vector3:
	return Vector3(point.x-hero.global_position.x, 0, point.z-hero.global_position.z).normalized()
func surface(at: Vector3) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(at+Vector3.UP*15, at-Vector3.UP*20, 1)
	var hit: Dictionary = hero.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position if not hit.is_empty() else at
func box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	arena.actor_parent.add_child(body)
	body.global_position = at
	return body
func prepare(career := "warrior", skill := "") -> void:
	for code in [KEY_Q, KEY_E, KEY_R]: key(code, false)
	for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]: mouse(button, false)
	hero.input_router.cancel()
	hero.loadout.sandbox_mode = true
	var definition: Dictionary = arena.database.careers[career]
	hero.loadout.select_career(str(definition.get("base_career", career)))
	hero.loadout.set_level(maxi(1, int(definition.get("required_level", 1))))
	if career != definition.get("base_career", career): hero.loadout.select_career(career)
	if not skill.is_empty(): check(hero.loadout.assign_skill(0, 0, skill), "equip catalog skill " + skill)
	hero.combat.reset()
	hero.global_position = origin
	hero.velocity = Vector3.ZERO
	hero.facing = Vector3.FORWARD
	arena.locked_target = null
	arena.aim_override = null
	if is_instance_valid(arena.host): arena.host.aim_override = null
	else: arena.ui.toggle_menu(false)
	arena.input_blocked = false
	arena.pointer_blocked = false
	await ticks(45)
	started.clear()
func inspect_ground(point: Vector3, label: String) -> void:
	await pointer(point)
	var aim: Vector3 = arena.refresh_aim()
	print("AIM_TRACE ", label, " wanted=", point, " actual=", aim, " display=", root.get_mouse_position())
	check(aim.distance_to(point) < .07, label + " mouse ray resolves the actual surface in XYZ")
	check(hero.facing.dot(Vector3.FORWARD) > .999, label + " idle pointer motion preserves body facing")
	var direction := expected_direction(point)
	await tap_attack()
	check(started.size() == 1 and started[0].direction.dot(direction) > .999, label + " actual LMB attack follows the selected surface")

func run() -> void:
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-mouse-aim-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	root.size = Vector2i(1920, 1080)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = app.SAVE_REPOSITORY.new(Preferences.settings_path + "-adventures")
	root.add_child(app)
	current_scene = app
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	await ticks(3)
	app._finish_arrival()
	presenter = app.game
	arena = presenter.combat_world
	hero = presenter.player
	app.ui.close_panel(true)
	app.ui.modulate.a = 1
	app.ui.career_picker = false
	app.ui.region_clock = 0
	presenter.sound.muted = true
	arena.encounters_started = true
	for unit in arena.units():
		if unit != hero: unit.set_physics_process(false)
	hero.combat.runner.action_started.connect(record)
	await ticks(40)
	origin = hero.global_position
	await prepare()
	var right: Vector3 = arena.camera_right()
	await inspect_ground(surface(origin + right*3), "main flat ground")
	await prepare()
	var raised := origin + right*4
	var platform := box(raised + Vector3.UP*.55, Vector3(2, 1.1, 2))
	await ticks(2)
	raised.y += 1.1
	await inspect_ground(raised, "main raised ground")
	await prepare()
	await pointer(raised)
	mouse(MOUSE_BUTTON_RIGHT, true)
	await ticks(22)
	check(hero.combat.state == "CHARGING", "actual RMB starts weapon charging")
	mouse(MOUSE_BUTTON_RIGHT, false)
	await ticks(2)
	check(started.size() == 1 and started[0].direction.dot(expected_direction(raised)) > .999, "main RMB charge release uses the same height-aware aim")
	await prepare()
	var water: Vector3 = presenter.GARDEN_ORIGIN + Vector3(2.5, 0, 13.4)
	water.y = presenter.water_surface_at(water)
	await pointer(water)
	check(arena.refresh_aim().distance_to(water) < .07, "visible water is selected before its deeper riverbed")
	platform.queue_free()
	hero.input_router.cancel()
	app.queue_free()
	await ticks(5)

	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(6)
	presenter = arena.renderer
	hero = arena.player
	hero.combat.runner.action_started.connect(record)
	arena.sound.muted = true
	for unit in arena.enemies:
		unit.set_physics_process(false)
		unit.global_position = Vector3(18, .1, 18)
	origin = Vector3(0, .02, 6)
	await prepare()
	right = arena.camera_right()
	await inspect_ground(surface(origin+right*3), "arena flat ground")
	await prepare()
	raised = Vector3(4, 1.2, 6)
	platform = box(raised-Vector3.UP*.6, Vector3(2, 1.2, 2))
	await ticks(2)
	await inspect_ground(raised, "arena raised ground")
	await prepare("warrior", "warrior_thrust")
	await pointer(raised)
	key(KEY_Q, true)
	await ticks(2)
	check(hero.skill_casting.preview.intent.direction.dot(expected_direction(raised)) > .999, "directional skill and LMB share the same raised-ground direction")
	key(KEY_Q, false)
	await ticks(2)
	var committed: Vector3 = hero.combat.action_direction
	await pointer(Vector3(-4, 0, 6))
	check(started.size() == 1 and committed.dot(expected_direction(raised)) > .999 and hero.combat.action_direction.dot(committed) > .999, "skill release snapshots aim and does not follow later mouse movement")
	await prepare("evoker", "evoker_ice_storm")
	await pointer(raised)
	key(KEY_Q, true)
	await ticks(2)
	check(hero.skill_casting.preview.intent.point.distance_to(raised) < .07, "POINT skill centre uses the elevated impact surface")
	key(KEY_Q, false)
	await ticks(2)
	check(started.size() == 1 and hero.combat.action_point.distance_to(raised) < .07, "POINT execution preserves the actual preview centre and height")
	platform.queue_free()
	await ticks(2)
	await prepare("evoker", "evoker_ice_storm")
	var far := Vector3(16, 1.2, 6)
	platform = box(far-Vector3.UP*.6, Vector3(2, 1.2, 2))
	await ticks(2)
	await pointer(far)
	key(KEY_Q, true)
	await ticks(2)
	var intent: Dictionary = hero.skill_casting.preview.intent
	var reach: float = hero.skill_casting.preview.action.range
	check(absf(flat_distance(intent.point, hero.global_position)-reach) < .005 and absf(intent.point.y) < .05, "out-of-range POINT clamps horizontally and reprojects onto the reachable ground")
	hero.input_router.cancel()
	key(KEY_Q, false)
	platform.queue_free()
	await ticks(2)

	await prepare("conjurer", "conjurer_dreamwalk")
	platform = box(Vector3(4, 1, 6), Vector3(2, 2, 2))
	var soldier: Node = arena.spawn_enemy("soldier", Vector3(4, 2, 6))
	soldier.set_physics_process(false)
	await ticks(2)
	await pointer(soldier.global_position+Vector3.UP*1.0)
	key(KEY_Q, true)
	await ticks(2)
	var reference: Variant = hero.skill_casting.preview.intent.get("target")
	check(reference is WeakRef and reference.get_ref() == soldier and hero.skill_casting.preview.valid, "clicking an elevated unit torso selects its real body without a ground-plane offset")
	hero.input_router.cancel()
	key(KEY_Q, false)
	await ticks(2)
	await prepare("warrior", "warrior_thrust")
	await pointer(soldier.global_position + Vector3.UP)
	key(KEY_Q, true)
	await ticks(2)
	check(hero.skill_casting.preview.intent.direction.dot(expected_direction(soldier.global_position)) > .999, "directional skill aimed at an elevated torso shares the unit aim used by LMB")
	key(KEY_Q, false)
	await ticks(2)
	check(started.size() == 1 and started[0].direction.dot(expected_direction(soldier.global_position)) > .999, "directional release executes towards the hovered body rather than ground behind it")
	await prepare("evoker", "evoker_ice_storm")
	await pointer(soldier.global_position + Vector3.UP)
	key(KEY_Q, true)
	await ticks(2)
	var body_point: Vector3 = soldier.global_position
	check(hero.skill_casting.preview.intent.point.distance_to(body_point) < .001 and hero.skill_casting.preview.intent.target == null, "POINT aimed at a body centres on its feet without selecting a homing target")
	key(KEY_Q, false)
	await ticks(2)
	soldier.global_position += Vector3.BACK
	await ticks(2)
	check(started.size() == 1 and hero.combat.action_point.distance_to(body_point) < .001, "moving the hovered unit after POINT release preserves the committed ground centre")
	platform.queue_free()
	await ticks(2)
	await prepare()
	soldier.global_position = Vector3(2, 0, 6)
	await ticks(2)
	var empty := Vector3(3.5, 0, 4.8)
	await pointer(empty)
	check(arena.target_for(hero) == null, "empty ground near an enemy does not magnetically retarget the attack")
	await tap_attack()
	check(started.size() == 1 and started[0].direction.dot(expected_direction(empty)) > .999, "LMB preserves mouse direction next to an unhovered enemy")
	await prepare()
	await pointer(soldier.global_position+Vector3.UP*.8)
	await tap_attack()
	check(started.size() == 1 and started[0].direction.dot(expected_direction(soldier.global_position)) > .999, "LMB aimed at a unit body uses that unit's actual feet direction")
	await prepare()
	arena.locked_target = soldier
	await pointer(empty)
	await tap_attack()
	check(started.size() == 1 and started[0].direction.dot(expected_direction(soldier.global_position)) > .999, "explicit Tab lock keeps its intended aim priority")
	soldier.queue_free()
	await ticks(2)

	for yaw: float in [.9, -.6]:
		await prepare()
		presenter.camera_yaw = yaw
		presenter.camera_height = 13 if yaw > 0 else 26
		presenter.target_camera_height = presenter.camera_height
		await ticks(60)
		await inspect_ground(Vector3(4, 0, 6), "arena orbit/zoom %.1f" % yaw)
	root.size = Vector2i(1280, 720)
	await prepare()
	await ticks(5)
	await inspect_ground(Vector3(4, 0, 6), "resized stretched window")
	await prepare()
	await pointer(Vector3(4, 0, 6))
	var before_orbit := root.get_mouse_position()
	mouse(MOUSE_BUTTON_MIDDLE, true)
	await ticks(3)
	mouse(MOUSE_BUTTON_MIDDLE, false)
	await ticks(3)
	check(root.get_mouse_position().distance_to(before_orbit) < 2.5, "resized camera orbit restores viewport coordinates without a cursor jump")
	root.size = Vector2i(1920, 1080)
	await ticks(5)
	await prepare()
	platform = box(Vector3(0, 1, 6), Vector3(2, 2, 2))
	hero.global_position = Vector3(0, 2.02, 6)
	await ticks(45)
	await inspect_ground(Vector3(4, 0, 6), "raised caster aiming down")
	platform.queue_free()
	hero.input_router.cancel()
	arena.queue_free()
	await ticks(4)
	DirAccess.remove_absolute(Preferences.settings_path)
	Preferences.settings_path = Preferences.DEFAULT_PATH
	print("MOUSE_AIM_RESULT %d/%d passed" % [checks-failures, checks])
	quit(0 if failures == 0 else 1)
