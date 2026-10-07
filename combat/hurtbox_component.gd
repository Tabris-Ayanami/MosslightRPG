extends Node

var actor: Node

func receive(action: Dictionary, source: Node, direction: Vector3) -> Dictionary:
	return actor.combat.receive_damage(action, source, direction)
