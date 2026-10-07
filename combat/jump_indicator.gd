extends "res://combat/cast_indicator.gd"
## Concentric stamina bands use the same blue terrain geometry as skill casts.

func show_preview(data: Dictionary) -> void:
	last_preview = data
	visible = true
	var origin: Vector3 = data.origin
	var point: Vector3 = data.point
	var signature := str([data.kind, origin.snapped(Vector3.ONE * .025), point.snapped(Vector3.ONE * .025), data.cost, data.pips, data.valid])
	if signature == _signature: return
	_signature = signature
	vertices.clear()
	colors.clear()
	ground_cache.clear()
	var edge := Color(BLUE if data.valid else INVALID, .85)
	if data.kind == "crouch":
		_circle(origin, .65, Color(BLUE, .10), edge)
		_reticle(origin, Color(edge, .55), .34)
	else:
		var outer: float = float(data.step) * (int(data.pips) + 1)
		_circle(origin, outer, Color(BLUE, .025), Color(BLUE, .62))
		for cost in range(int(data.pips) + 1):
			var radius: float = float(data.step) * (cost + 1)
			if cost < int(data.pips): _circle(origin, radius, Color.TRANSPARENT, Color(BLUE, .70 if cost == data.cost else .36))
		_circle(point, maxf(.34, float(actor.definition.body.radius)), Color(BLUE, .15), edge)
		_reticle(point, edge, .55)
		_segment(origin, point, .045, Color(edge, .28))
	_commit_mesh()
