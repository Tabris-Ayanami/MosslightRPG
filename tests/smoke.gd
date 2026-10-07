extends SceneTree
## End-to-end gameplay checks, run in the actual Godot physics engine.
## godot --headless --path . --fixed-fps 60 --script res://tests/smoke.gd
const Art = preload("res://scripts/art.gd")
const Interactable = preload("res://scripts/interactable.gd")
var game: Node
var player: CharacterBody3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("PASS ", label)
	else:
		failures.append(label)
		push_error("FAIL " + label)

func _tap(action: String, held_frames: int = 2) -> void:
	Input.action_press(action)
	await _ticks(held_frames)
	Input.action_release(action)
	await _ticks(2)

func _reset(at: Vector3 = Vector3(0, 0.05, 1)) -> void:
	game._release_actions()
	player.restore(at)
	player.invulnerable = 0
	game.aim_override = at + Vector3(0, 0, -8)
	await _ticks(4)

func _clear_enemies() -> void:
	for enemy in get_nodes_in_group("enemies"):
		enemy.queue_free()
	await _ticks(2)
	game.wave_active = false

func _target(at: Vector3) -> CharacterBody3D:
	var e: CharacterBody3D = game.spawn_enemy(at)
	e.set_physics_process(false)
	e.health = 200
	e.max_health = 200
	return e

func _run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	player = game.player
	game.sound.muted = true
	# Isolated collision/interaction fixtures replace the deleted prototype map.
	# The enlarged lake now reaches the old fixture location; move scenery away.
	game.reference_map.position.z += 1000
	var fixture := Node3D.new()
	fixture.name = "GameplayTestFixture"
	game.world.add_child(fixture)
	Art.solid_box(fixture, Vector3(0, -.5, 0), Vector3(40, 1, 40), Color.WHITE, false)
	for data in [["shrine", Vector3(-8, 0, 5)], ["chest", Vector3(5.2, 0, 4.8)], ["gate", Vector3(0, 0, -5.4)], ["sign", Vector3(-2.6, 0, 7.5)]]:
		var prop := Interactable.new()
		prop.kind = data[0]
		prop.position = data[1]
		fixture.add_child(prop)
	game.encounter_origin = Vector3.ZERO
	await _ticks(10)
	await _clear_enemies()
	await _reset()
	check(player.is_on_floor(), "player settles on solid 3D terrain")
	var before := player.global_position
	var event := InputEventKey.new()
	event.physical_keycode = KEY_W
	event.pressed = true
	Input.parse_input_event(event)
	await _ticks(30)
	event.pressed = false
	Input.parse_input_event(event)
	var displacement := player.global_position - before
	var straight_distance := displacement.length()
	check(displacement.dot(game.camera_forward()) > 2, "physical W moves toward top of screen")
	await _reset()
	before = player.global_position
	Input.action_press("move_up")
	Input.action_press("move_right")
	await _ticks(30)
	game._release_actions()
	var diagonal_distance := player.global_position.distance_to(before)
	check(absf(diagonal_distance - straight_distance) < 0.25, "diagonal movement does not gain extra speed")
	await _reset()
	await _tap("jump")
	await _ticks(12)
	check(player.position.y > 0.9, "space produces a real vertical jump")
	var jump_velocity := player.velocity.y
	await _tap("jump")
	check(player.velocity.y < jump_velocity, "no unintended double jump")
	await _ticks(65)
	check(player.is_on_floor() and absf(player.position.y) < 0.12, "jump lands on terrain")
	await _reset()
	before = player.global_position
	await _tap("roll")
	var hp: float = player.health
	player.take_damage(20, Vector3.FORWARD)
	check(player.health == hp and player.invulnerable > 0, "roll blocks incoming damage during i-frames")
	check(player.stamina <= 77, "roll spends stamina")
	await _ticks(23)
	check(player.global_position.distance_to(before) > 3.5, "roll covers meaningful ground")
	await _ticks(30)
	player.invulnerable = 0
	player.take_damage(12, Vector3.FORWARD)
	check(player.health == hp - 12, "damage applies after invulnerability ends")
	await _reset()
	player.stamina = 0
	await _tap("roll")
	check(player.roll_left == 0, "exhausted player cannot roll")
	await _reset()
	var enemy := _target(Vector3(0, 0, -0.4))
	await _ticks(3)
	await _tap("sword", 3)
	check(enemy.health == 183, "short left click deals sword damage on release")
	check(player.combo == 1, "first slash starts combo")
	await _ticks(20)
	await _tap("sword", 44)
	check(enemy.health == 141, "held left click releases stronger heavy slash")
	await _ticks(40)
	enemy.position = Vector3(0, 0, 2.5)
	var old_hp: float = enemy.health
	await _tap("sword", 3)
	check(enemy.health == old_hp, "sword does not hit enemies behind the player")
	await _clear_enemies()
	await _reset()
	var wall := Art.solid_box(game.world, Vector3(0, 0.8, -0.25), Vector3(2, 1.6, 0.2), Color.WHITE, false)
	enemy = _target(Vector3(0, 0, -1))
	await _ticks(3)
	await _tap("sword", 3)
	check(enemy.health == 200, "melee cannot hit through a stone wall")
	wall.queue_free()
	await _clear_enemies()
	await _reset()
	enemy = _target(Vector3(0, 0, -3))
	await _ticks(3)
	await _tap("bow", 3)
	await _ticks(25)
	check(enemy.health == 184, "short right click fires a colliding arrow")
	await _clear_enemies()
	await _reset()
	var first := _target(Vector3(0, 0, -1))
	var second := _target(Vector3(0, 0, -3))
	await _ticks(3)
	await _tap("bow", 45)
	await _ticks(20)
	check(first.health == 162 and second.health == 162, "charged arrow pierces two enemies once each")
	await _clear_enemies()
	await _reset()
	wall = Art.solid_box(game.world, Vector3(0, 0.8, -0.25), Vector3(2, 1.6, 0.25), Color.WHITE, false)
	enemy = _target(Vector3(0, 0, -3))
	await _ticks(3)
	await _tap("bow", 44)
	await _ticks(24)
	check(enemy.health == 200, "charged arrows stop at solid walls")
	await _ticks(40)
	await _tap("skill_e")
	check(player.position.z > 0.1, "dash capsule stops at a solid wall")
	wall.queue_free()
	await _clear_enemies()
	await _reset()
	first = _target(Vector3(1.5, 0, 1))
	second = _target(Vector3(-1.5, 0, 1))
	await _ticks(3)
	await _tap("skill_q")
	check(first.health == 164 and second.health == 164, "Q hits enemies on both sides")
	check(player.mana < 76 and player.skill_cooldowns.q > 4, "Q consumes mana and starts cooldown")
	await _tap("skill_q")
	check(first.health == 164, "cooldown prevents repeated Q casting")
	await _clear_enemies()
	await _reset()
	enemy = _target(Vector3(0, 0, -1.5))
	await _ticks(3)
	await _tap("skill_e")
	check(enemy.health == 169 and player.position.z < -3, "E damages enemies along the dash path")
	await _clear_enemies()
	await _reset()
	player.health = 31
	await _tap("skill_r")
	check(player.health == 73 and player.mana < 67, "R heals and consumes mana")
	await _reset()
	await _tap("skill_r")
	check(player.mana == 100 and player.skill_cooldowns.r == 0, "full-health healing does not waste mana")
	player.mana = 0
	await _tap("skill_q")
	check(player.skill_cooldowns.q == 0, "insufficient mana prevents skill casting")
	await _reset(Vector3(5.2, 0.05, 6.0))
	var gold: int = player.gold
	await _tap("interact")
	check(player.gold == gold + 50 and game.last_interaction.kind == "chest", "F opens nearby chest and awards gold")
	await _tap("interact")
	check(player.gold == gold + 50, "opened chest cannot award twice")
	await _reset(Vector3(-6.7, 0.05, 5))
	player.health = 15
	await _tap("interact")
	check(player.health == 100 and game.checkpoint.x < -6, "F at shrine heals and records checkpoint")
	player.invulnerable = 0
	player.take_damage(200, Vector3.ZERO)
	check(player.dead, "fatal damage enters death state")
	await _ticks(160)
	check(not player.dead and player.health == 100 and player.position.distance_to(game.checkpoint) < 0.2, "death automatically respawns at saved checkpoint")
	await _reset()
	Input.action_press("sword")
	await _ticks(40)
	game._focus_lost()
	check(player.charge_kind.is_empty() and not Input.is_action_pressed("sword"), "losing focus cancels charge and releases input")
	await _reset()
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	game._unhandled_input(escape)
	check(paused and game.paused, "Escape pauses the scene tree")
	game._unhandled_input(escape)
	check(not paused and not game.paused, "Escape resumes gameplay")
	game.start_wave()
	check(game.wave == 2 and get_nodes_in_group("enemies").size() == 5, "trial creates the next wave with five enemies")
	for e in get_nodes_in_group("enemies"):
		e.take_damage(1000, Vector3.ZERO)
	check(not game.wave_active and game.defeated == 5, "defeating the wave unlocks the next trial")
	await _ticks(20)
	await _reset()
	enemy = game.spawn_enemy(Vector3(0, 0, -2))
	game.wave_active = false
	var start_distance := enemy.global_position.distance_to(player.global_position)
	await _ticks(60)
	check(enemy.global_position.distance_to(player.global_position) < start_distance, "enemy AI chases player")
	await _ticks(140)
	check(player.health < 100, "enemy windup and lunge deal real damage")
	game.queue_free()
	await process_frame
	print("TEST_RESULT %d/%d passed" % [checks - failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
