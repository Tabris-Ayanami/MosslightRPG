extends SceneTree
## Main scene, owned gear and physical InputMap events; no legacy attack facade.
const Attack = preload("res://combat/attack_instance.gd")
var game: Node
var player: CharacterBody3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	await ticks(2)

func button(code: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = code
	event.pressed = pressed
	event.position = game.world_to_screen(game.aim_position)
	event.global_position = event.position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(event)
	await ticks(2)
	print("EXPLORATION_BUTTON_TRACE pressed=", pressed, " state=", player.combat.state, " action=", player.combat.runner.current_action.get("id", ""), " facing=", player.facing)

func point_at(direction: Vector3) -> void:
	var target: Vector3 = player.global_position + direction * 5 + Vector3.UP * .3
	var event := InputEventMouseMotion.new()
	event.position = game.world_to_screen(target)
	event.global_position = event.position
	Input.parse_input_event(event)
	root.push_input(event, true)
	await ticks(2)
	var actual: Vector3 = game.aim_position - player.global_position
	actual.y = 0
	print("EXPLORATION_AIM_TRACE actual=", actual.normalized(), " wanted=", direction)
	check(actual.normalized().dot(direction.normalized()) > .99, "mouse updates world aim through actual camera projection")

func reset_player() -> void:
	game._release_actions()
	player.restore(game.checkpoint)
	game.combat_world.locked_target = null
	await ticks(15)

func create_game(career: String) -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(35)
	player = game.player
	game.sound.muted = true
	game.aim_override = null
	check(not player.loadout.sandbox_mode and player.progression.choose_career(career), "normal main-world character chooses " + career)
	check(player.inventory.count(player.loadout.sets[0].weapon) > 0, "starting weapon actually belongs to character")
	await ticks(5)

func wait_for_phase(phase: String, limit := 50) -> bool:
	for i in range(limit):
		if player.combat.runner.action_phase == phase:
			return true
		await ticks(1)
	return false

func instance_matches(direction: Vector3, projectile: bool, id := "") -> bool:
	for child in game.fx.get_children():
		if child.get_script() == Attack and child.source == player and child.projectile == projectile and (id.is_empty() or child.action.get("id", "") == id):
			if child.direction.dot(direction.normalized()) > .99:
				return true
	return false

func run() -> void:
	root.size = Vector2i(1280, 720)
	await create_game("warrior")
	await key(KEY_W, true)
	await ticks(6)
	check(player.facing.dot(game.camera_forward()) > .999, "W faces camera-relative movement")
	await key(KEY_W, false)
	var stopped: Vector3 = player.facing
	await point_at(-stopped)
	await ticks(12)
	check(player.facing.dot(stopped) > .999, "idle mouse motion preserves stopped body direction")
	await key(KEY_D, true)
	await ticks(5)
	check(player.facing.dot(game.camera_right()) > .999, "D faces movement even when cursor is elsewhere")
	await key(KEY_D, false)
	await reset_player()
	await point_at(Vector3.FORWARD)
	await button(MOUSE_BUTTON_LEFT, true)
	check(player.combat.state == "CHARGING" and player.combat.charge_action.get("animation_family", "") == "SINGLE_BLADE" and player.facing.dot(Vector3.FORWARD) > .99, "owned sword press charges toward mouse aim")
	var held_aim: Vector3 = player.facing
	await ticks(18)
	await point_at(Vector3.BACK)
	check(player.facing.dot(held_aim) > .999, "idle charging does not track the cursor")
	await button(MOUSE_BUTTON_LEFT, false)
	check(player.combat.runner.busy() and player.combat.runner.current_action.get("semantic", "") == "PRIMARY_CHARGE" and player.facing.dot(Vector3.BACK) > .99, "sword release starts real charged action using latest aim")
	check(await wait_for_phase("ACTIVE"), "charged sword reaches ACTIVE")
	check(instance_matches(Vector3.BACK, false), "actual sword AttackInstance uses release direction")
	var sword_aim: Vector3 = player.facing
	await key(KEY_D, true)
	check(player.combat.runner.busy() and player.facing.dot(sword_aim) > .999, "WASD cannot redirect executing sword action")
	await ticks(45)
	check(player.facing.dot(game.camera_right()) > .999, "movement facing resumes after action ends")
	await key(KEY_D, false)
	await reset_player()
	check(player.progression.learn_skill("warrior_sword_wave") and player.loadout.assign_skill(0, 0, "warrior_sword_wave"), "Q sword wave genuinely learned and prepared")
	check(player.progression.learn_skill("warrior_thrust") and player.loadout.assign_skill(0, 1, "warrior_thrust"), "E thrust genuinely learned and prepared")
	await point_at(Vector3.BACK)
	await key(KEY_Q, true)
	check(player.combat.runner.current_action.get("id", "") == "warrior_sword_wave" and player.combat.cooldowns.get("warrior_sword_wave", 0) > 0 and player.facing.dot(Vector3.BACK) > .99, "Q skill starts toward cursor with real cooldown")
	await key(KEY_Q, false)
	var skill_aim: Vector3 = player.facing
	await key(KEY_D, true)
	check(player.combat.runner.busy() and player.facing.dot(skill_aim) > .999, "movement cannot rotate executing Q skill")
	await key(KEY_D, false)
	check(await wait_for_phase("ACTIVE"), "sword wave reaches active phase")
	check(instance_matches(Vector3.BACK, true, "warrior_sword_wave"), "actual sword wave projectile follows aim")
	await reset_player()
	await point_at(Vector3.LEFT)
	var before_thrust: Vector3 = player.global_position
	await key(KEY_E, true)
	check(player.combat.runner.current_action.get("id", "") == "warrior_thrust" and player.facing.dot(Vector3.LEFT) > .99, "E thrust aims before displacement")
	await key(KEY_E, false)
	check(await wait_for_phase("ACTIVE"), "thrust reaches ACTIVE")
	var displacement: Vector3 = player.global_position - before_thrust
	displacement.y = 0
	check(displacement.length() > .05 and displacement.normalized().dot(Vector3.LEFT) > .99 and instance_matches(Vector3.LEFT, false, "warrior_thrust"), "actual thrust movement and attack follow aim")
	await reset_player()
	await key(KEY_D, true)
	await ticks(3)
	await key(KEY_SPACE, true)
	check(player.combat.state == "DODGE" and player.facing.dot(player.combat.dodge_direction) > .999, "Space dodge locks facing to travel")
	var dodge_aim: Vector3 = player.facing
	await key(KEY_D, false)
	await key(KEY_W, true)
	await point_at(-dodge_aim)
	check(player.combat.state == "DODGE" and player.facing.dot(dodge_aim) > .999, "movement and cursor cannot redirect running Space dodge")
	await key(KEY_W, false)
	await key(KEY_SPACE, false)
	game._release_actions()
	game.queue_free()
	await ticks(3)
	await create_game("rogue")
	check(player.inventory.count("shortbow") == 1 and player.loadout.equip_weapon(1, ""), "rogue owns bow and releases its B reservation")
	check(player.loadout.equip_weapon(0, "shortbow"), "owned bow equips into current A through normal API")
	await point_at(Vector3.LEFT)
	await button(MOUSE_BUTTON_LEFT, true)
	check(player.combat.state == "CHARGING" and player.combat.charge_action.get("animation_family", "") == "BOW" and player.facing.dot(Vector3.LEFT) > .99, "bow press charges toward current aim")
	await ticks(18)
	await point_at(Vector3.FORWARD)
	check(player.facing.dot(Vector3.LEFT) > .99, "holding bow preserves facing while idle cursor moves")
	await button(MOUSE_BUTTON_LEFT, false)
	check(player.combat.runner.current_action.get("id", "") == "bow_primary_charge_1" and player.facing.dot(Vector3.FORWARD) > .99, "bow release samples updated aim in shared runner")
	check(await wait_for_phase("ACTIVE"), "bow release reaches ACTIVE")
	check(instance_matches(Vector3.FORWARD, true, "bow_primary_charge_1"), "actual arrow AttackInstance follows release aim")
	var shot_aim: Vector3 = player.facing
	await key(KEY_A, true)
	check(player.combat.runner.busy() and player.facing.dot(shot_aim) > .999, "movement cannot redirect bow release")
	await key(KEY_A, false)
	game._release_actions()
	print("EXPLORATION_FACING: %d checks; %d failures" % [checks, failures.size()])
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
