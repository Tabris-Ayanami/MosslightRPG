extends Node
## Count travelled distance after the character has resolved walls and stairs.
signal foot_contact(surface: StringName, landing: bool)
@export_range(.8, 2.5, .05) var step_distance := 1.65
var player: CharacterBody3D
var sound: Node
var surfaces: Node
var _last_position := Vector3.ZERO
var _distance := 0.0
var _next_step := .24
var _was_grounded := false
var _ground_established := false
var _air_time := 0.0
var _fall_speed := 0.0
var _roll_grace := 0.0
var _surface := &"grass"

func setup(character: CharacterBody3D, audio: Node, detector: Node) -> void:
	player = character
	sound = audio
	surfaces = detector
	process_physics_priority = 20
	reset()

func reset() -> void:
	_last_position = player.global_position
	_distance = 0
	_next_step = .24
	_was_grounded = false
	_ground_established = false
	_air_time = 0
	_fall_speed = 0
	_roll_grace = 0
	_surface = &"grass"

func _physics_process(delta: float) -> void:
	if player == null:
		return
	var travel := player.global_position - _last_position
	_last_position = player.global_position
	# Respawns and the blink skill must not emit a burst of queued steps.
	if player.dead or travel.length() > maxf(1.5, 22.0 * delta):
		reset()
		return
	var grounded := player.is_on_floor()
	_roll_grace = .12 if player.roll_left > 0 else maxf(0, _roll_grace - delta)
	if not grounded:
		_air_time += delta
		_fall_speed = maxf(_fall_speed, -travel.y / maxf(delta, .001))
		_distance = 0
		_next_step = .24
	elif not _was_grounded:
		if _ground_established and _air_time > .16 and _roll_grace == 0:
			_contact(true, clampf(_fall_speed / 8.0, .4, 1.15))
		_ground_established = true
		_surface = surfaces.surface_at(player.global_position)
		_air_time = 0
		_fall_speed = 0
		_distance = 0
		_next_step = step_distance * .8
	elif _roll_grace == 0:
		var distance := Vector2(travel.x, travel.z).length()
		if distance < .08 * delta:
			_distance = 0
			_next_step = .24
		else:
			var surface: StringName = surfaces.surface_at(player.global_position)
			if surface == &"water" and _surface != &"water":
				# Shallow shore bands can be shorter than a stride: entry still splashes.
				_contact(false, .75)
				_distance = 0
				_next_step = step_distance
			else:
				_distance += distance
			if _distance >= _next_step:
				_contact(false, clampf(distance / maxf(delta, .001) / player.move_speed, .5, 1.0))
				_distance = fmod(_distance - _next_step, step_distance)
				_next_step = step_distance
			_surface = surface
	else:
		_distance = 0
		_next_step = step_distance * .7
	_was_grounded = grounded

func _contact(landing: bool, strength: float) -> void:
	var surface: StringName = surfaces.surface_at(player.global_position)
	sound.play_footstep(surface, strength, landing)
	foot_contact.emit(surface, landing)
