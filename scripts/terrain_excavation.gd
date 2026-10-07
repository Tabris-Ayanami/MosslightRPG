extends RefCounted
## Clip terrain triangles against convex structural footprints. The same output
## feeds rendering, grass placement, collision and baked terrain storage.
const EPSILON := 0.00001

static func apply(cell: MarchingSquaresTerrainCell, cuts: Array[Dictionary], offset: Vector3) -> void:
	for cut in cuts:
		var outline: PackedVector2Array = cut.outline
		var bounds := Rect2(outline[0], Vector2.ZERO)
		for p in outline: bounds = bounds.expand(p)
		var origin := Vector2(offset.x, offset.z) + Vector2(cell.cell_coords) * cell.chunk.cell_size
		if not bounds.intersects(Rect2(origin, cell.chunk.cell_size), true): continue
		_carve(cell, outline, cut.floor, offset)

static func _vertex(cell: MarchingSquaresTerrainCell, i: int, offset: Vector3) -> Dictionary:
	return {"p": cell.pts[i] + offset, "uv": cell.uvs[i], "uv2": cell.uv2s[i],
		"c0": cell.color_0s[i], "c1": cell.color_1s[i], "custom": cell.custom_1_values[i],
		"blend": cell.mat_blends[i], "floor": cell.floors[i]}

static func _interpolate(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	return {"p": a.p.lerp(b.p, t), "uv": a.uv.lerp(b.uv, t), "uv2": a.uv2.lerp(b.uv2, t),
		"c0": a.c0.lerp(b.c0, t), "c1": a.c1.lerp(b.c1, t), "custom": a.custom.lerp(b.custom, t),
		"blend": a.blend.lerp(b.blend, t), "floor": a.floor}

static func _distance(vertex: Dictionary, a: Vector2, edge: Vector2) -> float:
	var p: Vector3 = vertex.p
	return edge.cross(Vector2(p.x, p.z) - a)

static func _clip(poly: Array, a: Vector2, edge: Vector2, inside: bool) -> Array:
	var result: Array = []
	if poly.is_empty(): return result
	var previous: Dictionary = poly[-1]
	var previous_d := _distance(previous, a, edge)
	var previous_in := previous_d >= 0.0 if inside else previous_d <= 0.0
	for current: Dictionary in poly:
		var current_d := _distance(current, a, edge)
		var current_in := current_d >= 0.0 if inside else current_d <= 0.0
		if current_in != previous_in:
			result.append(_interpolate(previous, current, previous_d / (previous_d - current_d)))
		if current_in: result.append(current)
		previous = current
		previous_d = current_d
		previous_in = current_in
	return result

static func _append(cell: MarchingSquaresTerrainCell, poly: Array, offset: Vector3) -> void:
	for i in range(1, poly.size() - 1):
		var a: Vector3 = poly[0].p
		var b: Vector3 = poly[i].p
		var c: Vector3 = poly[i + 1].p
		if (b - a).cross(c - a).length_squared() < 1e-14: continue
		for vertex: Dictionary in [poly[0], poly[i], poly[i + 1]]:
			cell.pts.append(vertex.p - offset)
			cell.uvs.append(vertex.uv)
			cell.uv2s.append(vertex.uv2)
			cell.color_0s.append(vertex.c0)
			cell.color_1s.append(vertex.c1)
			cell.custom_1_values.append(vertex.custom)
			cell.mat_blends.append(vertex.blend)
			cell.floors.append(vertex.floor)

static func _lower(vertex: Dictionary, floor_height: float) -> Dictionary:
	var lowered := vertex.duplicate()
	var p: Vector3 = lowered.p
	p.y = minf(p.y, floor_height)
	lowered.p = p
	return lowered

static func _wall(vertex: Dictionary) -> Dictionary:
	var wall := vertex.duplicate()
	var p: Vector3 = wall.p
	wall.uv = Vector2.ONE
	wall.uv2 = Vector2(p.x + p.z, p.y * 2.0)
	wall.floor = 0
	return wall

static func _carve(cell: MarchingSquaresTerrainCell, outline: PackedVector2Array, floor_height: float, offset: Vector3) -> void:
	var source: Array = []
	for i in range(cell.pts.size()): source.append(_vertex(cell, i, offset))
	cell.pts = PackedVector3Array()
	cell.uvs = PackedVector2Array()
	cell.uv2s = PackedVector2Array()
	cell.color_0s = PackedColorArray()
	cell.color_1s = PackedColorArray()
	cell.custom_1_values = PackedColorArray()
	cell.mat_blends = PackedColorArray()
	cell.floors = PackedByteArray()
	for i in range(0, source.size(), 3):
		var interior: Array = [source[i], source[i + 1], source[i + 2]]
		# Each half-plane emits a disjoint outside piece, preserving source data.
		for j in range(outline.size()):
			var a := outline[j]
			var edge := (outline[(j + 1) % outline.size()] - a).normalized()
			_append(cell, _clip(interior, a, edge, false), offset)
			interior = _clip(interior, a, edge, true)
			if interior.size() < 3: break
		if interior.size() < 3: continue
		var bottom: Array = []
		for vertex: Dictionary in interior: bottom.append(_lower(vertex, floor_height))
		_append(cell, bottom, offset)
		# Close only the footprint boundary, never internal triangle/chunk edges.
		for j in range(interior.size()):
			var a: Dictionary = interior[j]
			var b: Dictionary = interior[(j + 1) % interior.size()]
			for k in range(outline.size()):
				var edge := (outline[(k + 1) % outline.size()] - outline[k]).normalized()
				if absf(_distance(a, outline[k], edge)) < EPSILON and absf(_distance(b, outline[k], edge)) < EPSILON:
					_append(cell, [_wall(a), _wall(b), _wall(_lower(b, floor_height)), _wall(_lower(a, floor_height))], offset)
					break
