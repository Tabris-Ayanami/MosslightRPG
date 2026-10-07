extends Node3D
var display_name := ""
var kind := "rest"
var rest_kind := "tree"
var persistent_id := ""

func _ready() -> void:
	add_to_group("interactables")

func interaction_distance(at: Vector3) -> float:
	return global_position.distance_to(at)
