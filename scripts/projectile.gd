extends Node3D

const Art = preload("res://scripts/art.gd")
var game: Node
var direction := Vector3.FORWARD
var heavy := false
var lifetime := 1.8
var hit_ids: Array[int] = []
var trail_time := 0.0

func _ready() -> void:
	look_at(global_position + direction, Vector3.UP)
	Art.box(self, Vector3.ZERO, Vector3(0.045, 0.045, 0.75), Color("ecd39b"))
	Art.box(self, Vector3(0, 0, -0.40), Vector3(0.11, 0.075, 0.14), Color("dce9d5"))
	Art.box(self, Vector3(0, 0, 0.3), Vector3(0.2, 0.035, 0.15), Color("a1cfc1"))

func _physics_process(delta: float) -> void:
	lifetime -= delta
	if lifetime <= 0:
		queue_free()
		return
	var next := global_position + direction * (25.0 if heavy else 18.0) * delta
	# Sweep the full segment each physics frame; fast arrows cannot tunnel.
	var excluded: Array[RID] = []
	var cursor := global_position
	for i in range(5):
		var query := PhysicsRayQueryParameters3D.create(cursor, next, 1 | 4, excluded)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			break
		var body: Object = hit.collider
		if body.has_method("take_damage") and not hit_ids.has(body.get_instance_id()):
			hit_ids.append(body.get_instance_id())
			body.take_damage(38.0 if heavy else 16.0, direction, 3.8 if heavy else 1.6)
			if heavy:
				excluded.append(body.get_rid())
				cursor = hit.position + direction * 0.02
				continue
		game.burst(hit.position, Color("efdcaa"), 4, 0.4)
		queue_free()
		return
	global_position = next
	trail_time += delta
	if heavy and trail_time > 0.045:
		trail_time = 0
		game.burst(global_position, Color("c9e6bd"), 1, 0.25)
