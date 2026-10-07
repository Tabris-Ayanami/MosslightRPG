extends "res://combat/combat_actor.gd"
## Main-world integration; all attacks, resources and movement live in CombatActor.
var game: Node
var aim: Vector3:
	get: return facing
	set(value): facing = value
var moving: bool:
	get: return move_direction.length_squared() > .01
var roll_left: float:
	get: return maxf(0, .42 - combat.dodge_time) if combat and combat.state == "DODGE" else 0.0
var character: Node3D:
	get: return animation.kirito if animation else null

func _ready() -> void:
	is_player = true
	sandbox_mode = false
	arena = game.combat_world
	super._ready()
	display_name = "桐人"
	combat.died.connect(game.on_player_died)
	progression.leveled_up.connect(func(new_level: int): arena.notify("升至 Lv%d · 点击头像查看职业进阶，K 查看可学技能" % new_level))

func cancel_charge() -> void:
	for unit in arena.units():
		if unit.input_router: unit.input_router.cancel()

func restore(at: Vector3) -> void:
	arena.control.cancel_all()
	form.clear_for_load()
	ladder.cleanup()
	surface_traversal.clear()
	swimming=false
	wading=false
	global_position = at
	velocity = Vector3.ZERO
	combat.reset()
	if game.sound and game.sound.footsteps:
		game.sound.footsteps.reset()
