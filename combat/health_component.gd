extends Node

signal damage_received(amount: float)
signal died

var resources: Node
var shield := 0.0

func setup(pool: Node) -> void:
	resources = pool
	resources.died.connect(func() -> void: died.emit())

func receive(amount: float) -> float:
	var absorbed := minf(shield, maxf(0.0, amount))
	shield -= absorbed
	var dealt := minf(resources.current("HP"), maxf(0.0, amount - absorbed))
	resources.change("HP", -dealt)
	damage_received.emit(dealt)
	return dealt

func ratio() -> float:
	return resources.current("HP") / maxf(1.0, resources.max_value("HP"))
