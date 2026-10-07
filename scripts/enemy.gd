extends CharacterBody3D

const Art = preload("res://scripts/art.gd")
var game: Node
var max_health := 58.0
var health := 58.0
var elite := false
var spawn_point := Vector3.ZERO
var state := "idle"
var state_time := 0.0
var attack_cooldown := 1.0
var knockback := Vector3.ZERO
var model: Node3D
var warning: MeshInstance3D
var phase := 0.0
var hit_flash := 0.0
var hit_direction := Vector3.ZERO

func _ready() -> void:
	spawn_point = position
	phase = position.x * 1.7
	if elite:
		max_health = 95
		health = 95
	model = Node3D.new()
	add_child(model)
	var color := Color("bd8166") if elite else Color("8db47b")
	Art.sphere(model, Vector3(0, 0.42, 0), Vector3(1.05, 0.85, 0.9), color)
	Art.sphere(model, Vector3(0, 0.67, 0.10), Vector3(0.72, 0.50, 0.55), color.lightened(0.12))
	for side in [-1.0, 1.0]:
		Art.box(model, Vector3(side * 0.17, 0.49, -0.42), Vector3(0.08, 0.10, 0.06), Color("293e3f"))
		Art.box(model, Vector3(side * 0.15, 0.51, -0.455), Vector3(0.025, 0.035, 0.015), Color("e4e1b9"))
		var leaf := Art.sphere(model, Vector3(side * 0.18, 0.97, 0), Vector3(0.23, 0.65, 0.15), Color("5c855c"))
		leaf.rotation.z = side * -0.5
	warning = Art.ring(self, Vector3(0, 0.07, 0), 1.2, 0.09, Color("ecaa6f"))
	warning.visible = false

func _physics_process(delta: float) -> void:
	if game == null or state == "dead" or game.player.dead:
		return
	phase += delta * 5
	state_time -= delta
	attack_cooldown = maxf(0, attack_cooldown - delta)
	hit_flash = maxf(0, hit_flash - delta)
	var offset: Vector3 = game.player.global_position - global_position
	offset.y = 0
	var distance := offset.length()
	var dir := offset.normalized()
	var desired := Vector3.ZERO
	match state:
		"idle", "chase":
			warning.visible = false
			if distance < 9.0 and distance > 1.3:
				state = "chase"
				desired = dir * (2.5 if elite else 1.9)
			elif distance <= 1.5 and attack_cooldown <= 0:
				state = "windup"
				state_time = 0.65
				hit_direction = dir
			elif distance > 11 and global_position.distance_to(spawn_point) > 0.7:
				desired = (spawn_point - global_position).normalized() * 1.2
		"windup":
			warning.visible = true
			warning.scale = Vector3.ONE * (1.0 - maxf(state_time, 0) * 0.5)
			if state_time <= 0:
				state = "lunge"
				state_time = 0.22
				attack_cooldown = 1.5
		"lunge":
			warning.visible = false
			desired = hit_direction * 7
			if distance < 1.35 and abs(game.player.global_position.y - global_position.y) < 0.9:
				game.player.take_damage(18 if elite else 12, hit_direction)
			if state_time <= 0:
				state = "recover"
				state_time = 0.7
		"recover":
			if state_time <= 0:
				state = "chase"
		"stunned":
			warning.visible = false
			if state_time <= 0:
				state = "chase"
	# Soft separation avoids a single overlapping pile of enemies.
	if state == "chase":
		for other in get_tree().get_nodes_in_group("enemies"):
			if other == self or other.state == "dead":
				continue
			var apart: Vector3 = global_position - other.global_position
			apart.y = 0
			if apart.length_squared() < 1.4 and apart.length_squared() > 0.001:
				desired += apart.normalized() * 1.1
	velocity.x = desired.x + knockback.x
	velocity.z = desired.z + knockback.z
	knockback = knockback.move_toward(Vector3.ZERO, delta * 18)
	if not is_on_floor():
		velocity.y -= 22 * delta
	move_and_slide()
	if dir.length_squared() > 0.1 and state != "windup":
		model.rotation.y = lerp_angle(model.rotation.y, atan2(-dir.x, -dir.z), delta * 8)
	var squash := sin(phase) * 0.07
	model.scale = Vector3(1 + squash, 1 - squash, 1 + squash)
	model.position.y = maxf(0, sin(phase * 2)) * 0.08 if desired.length() > 0.1 else 0.0
	if state == "windup":
		model.scale.y = 0.68
	model.visible = hit_flash <= 0 or int(hit_flash * 35) % 2 == 0

func take_damage(amount: float, direction: Vector3, force: float = 2.0) -> void:
	if state == "dead":
		return
	health -= amount
	knockback = direction * force
	hit_flash = 0.18
	state = "stunned"
	state_time = 0.24
	game.float_text(global_position + Vector3(0, 1.3, 0), str(int(amount)), Color("fff0b5") if amount >= 30 else Color("edf1db"))
	game.burst(global_position + Vector3(0, 0.5, 0), Color("d4dfa8"), 7, 0.8)
	game.sound.play_tone("hit")
	if health <= 0:
		state = "dead"
		collision_layer = 0
		warning.visible = false
		game.enemy_defeated(self)
		var tween := create_tween()
		tween.tween_property(model, "scale", Vector3(1.4, 0.02, 1.4), 0.18)
		tween.tween_callback(queue_free)
