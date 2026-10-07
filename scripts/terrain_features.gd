extends RefCounted
## Structural footprints share dimensions with the visible architecture.
## Cuts are applied after landmass composition and after terrain triangulation.
const SHRINE_CENTER := Vector2(-5.0, -2.5)
const SHRINE_WALL_RADIUS := 3.67
const SHRINE_WALL_WIDTH := 0.48
const SHRINE_WALL_SEGMENTS := 28
const SHRINE_FLOOR := 0.1

static func excavations() -> Array[Dictionary]:
	var outline := PackedVector2Array()
	for i in range(SHRINE_WALL_SEGMENTS * 2):
		outline.append(SHRINE_CENTER + Vector2.from_angle(TAU * i / (SHRINE_WALL_SEGMENTS * 2)) * SHRINE_WALL_RADIUS)
	return [{"outline": outline, "floor": SHRINE_FLOOR}]

static func ground_at(p: Vector2, base_height: float) -> float:
	# Same regular polygon as the mesh cut; avoid allocating it for every sample.
	var relative := p - SHRINE_CENTER
	var half_sector := PI / (SHRINE_WALL_SEGMENTS * 2)
	var sector_angle := fposmod(relative.angle(), 2.0 * half_sector) - half_sector
	var edge_radius := SHRINE_WALL_RADIUS * cos(half_sector) / cos(sector_angle)
	return minf(base_height, SHRINE_FLOOR) if relative.length() <= edge_radius else base_height
