extends "res://tests/combat_feel.gd"
## Real movement, mouse and skill input verify facing independently of aim.

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(3)
	player = arena.player
	player.combat.runner.action_started.connect(record_action)
	await check_idle_and_movement()
	await check_attack_turns()
	await check_charge_and_defense()
	await check_dodge_facing()
	for action in InputMap.get_actions():
		Input.action_release(action)
	print("COMBAT_FACING: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures:
		printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)

func aim_at(direction: Vector3) -> void:
	arena.aim_override = player.global_position + direction * 12.0
	arena.aim_point = arena.aim_override
	var pointer := InputEventMouseMotion.new()
	pointer.position = POINTER + Vector2(direction.x * 120, direction.z * 70)
	pointer.global_position = pointer.position
	Input.parse_input_event(pointer)

func faces(direction: Vector3, label: String) -> void:
	verify(player.facing.dot(direction.normalized()) > .999, label)

func check_idle_and_movement() -> void:
	await prepare()
	for direction in [Vector3.RIGHT, Vector3.BACK, Vector3.LEFT]:
		aim_at(direction)
		await ticks(12)
		faces(Vector3.FORWARD, "idle pointer movement preserves last facing " + str(direction))
	var keys := [KEY_W, KEY_A, KEY_S, KEY_D]
	var directions: Array[Vector3] = [arena.camera_forward(), -arena.camera_right(), -arena.camera_forward(), arena.camera_right()]
	for i in range(keys.size()):
		var start: Vector3 = player.global_position
		aim_at(-directions[i])
		key(keys[i], true)
		await ticks(8)
		faces(directions[i], "WASD sets facing regardless of opposite cursor " + OS.get_keycode_string(keys[i]))
		verify((player.global_position - start).normalized().dot(directions[i]) > .95, "WASD actually moves in facing direction " + OS.get_keycode_string(keys[i]))
		key(keys[i], false)
		await ticks(10)
		faces(directions[i], "stopping preserves heading " + OS.get_keycode_string(keys[i]))
	key(KEY_W, true)
	key(KEY_D, true)
	await ticks(4)
	faces((arena.camera_forward() + arena.camera_right()).normalized(), "diagonal movement sets diagonal facing")
	key(KEY_W, false)
	key(KEY_D, false)
	await ticks(3)
	var saved: Vector3 = player.facing
	var enemy: Node = arena.enemies[0]
	arena.locked_target = enemy
	enemy.global_position = player.global_position + Vector3.LEFT * 4
	await ticks(12)
	faces(saved, "target lock does not rotate idle character")
	enemy.global_position = player.global_position + Vector3.RIGHT * 4
	await ticks(12)
	faces(saved, "moving locked target does not rotate idle character")

func check_attack_turns() -> void:
	await prepare()
	aim_at(Vector3.RIGHT)
	await tap_mouse()
	faces(Vector3.RIGHT, "mouse attack turns toward cursor")
	verify(player.combat.action_direction.dot(Vector3.RIGHT) > .999, "hit direction snapshots aimed facing")
	aim_at(Vector3.BACK)
	key(KEY_A, true)
	await ticks(5)
	faces(Vector3.RIGHT, "mouse and WASD cannot spin a running attack")
	key(KEY_A, false)
	await ticks(40)
	faces(Vector3.RIGHT, "attack finish keeps its facing while idle")
	await tap_mouse()
	faces(Vector3.BACK, "next attack can choose new mouse facing")
	await ticks(45)
	var enemy: Node = arena.enemies[0]
	enemy.global_position = player.global_position + Vector3.LEFT * 5
	arena.locked_target = enemy
	aim_at(Vector3.RIGHT)
	await tap_mouse()
	faces(Vector3.LEFT, "attack uses locked target when cursor points elsewhere")
	await ticks(45)
	arena.locked_target = null
	aim_at(Vector3.FORWARD)
	verify(player.loadout.assign_skill(0, 0, "warrior_thrust"), "directional skill assigned")
	await tap_key(KEY_Q)
	faces(Vector3.FORWARD, "directional skill turns toward aim on execution")

func check_charge_and_defense() -> void:
	await prepare()
	aim_at(Vector3.RIGHT)
	mouse(MOUSE_BUTTON_LEFT, true)
	await ticks(20)
	verify(player.combat.state == "CHARGING", "physical hold enters charge")
	faces(Vector3.RIGHT, "charge begins toward cursor")
	aim_at(Vector3.LEFT)
	await ticks(12)
	faces(Vector3.RIGHT, "idle charging does not track pointer movement")
	key(KEY_W, true)
	await ticks(6)
	faces(arena.camera_forward(), "moving sword charge follows WASD")
	key(KEY_W, false)
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(2)
	faces((arena.aim_point - player.global_position).normalized(), "release aims charged attack at current cursor")
	await prepare("barbarian")
	verify(player.loadout.equip_weapon(0, "iron_greatsword"), "heavy weapon equipped")
	aim_at(Vector3.RIGHT)
	mouse(MOUSE_BUTTON_LEFT, true)
	await ticks(20)
	aim_at(Vector3.BACK)
	key(KEY_W, true)
	var start: Vector3 = player.global_position
	await ticks(12)
	faces(Vector3.RIGHT, "rooted heavy charge keeps facing despite movement and pointer")
	near(player.global_position.distance_to(start), 0, "rooted heavy charge stays still", .03)
	key(KEY_W, false)
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(45)
	await prepare()
	player.loadout.set_level(2)
	verify(player.loadout.select_career("soldier"), "soldier selected for shield facing")
	mouse(MOUSE_BUTTON_RIGHT, true)
	await ticks(30)
	verify(player.combat.state == "GUARD", "held shield reaches regular defense")
	aim_at(Vector3.LEFT)
	await ticks(8)
	faces(Vector3.FORWARD, "idle defense does not follow mouse")
	key(KEY_D, true)
	await ticks(6)
	faces(arena.camera_right(), "guard walking turns with WASD")
	key(KEY_D, false)
	mouse(MOUSE_BUTTON_RIGHT, false)
	await ticks(3)

func check_dodge_facing() -> void:
	await prepare()
	aim_at(Vector3.RIGHT)
	await tap_key(KEY_SPACE)
	faces(Vector3.FORWARD, "idle dodge keeps last facing instead of turning toward mouse")
	verify(player.combat.dodge_direction.dot(Vector3.FORWARD) > .999, "idle dodge travels along last facing")
	await ticks(30)
	key(KEY_A, true)
	await ticks(4)
	var direction: Vector3 = player.facing
	await tap_key(KEY_SPACE)
	faces(direction, "movement dodge keeps movement facing")
	verify(player.combat.dodge_direction.dot(direction) > .999, "movement dodge travels along WASD")
	key(KEY_A, false)
