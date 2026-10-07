extends Node3D
## Terrain-following blue geometry shares the action's real range/area dimensions.
## It is local to the selected actor and never changes the world's render pipeline.
const BLUE := Color(.20, .62, 1.0)
const INVALID := Color(.95, .43, .40)
const SEGMENTS := 64
var actor: Node
var mesh_instance: MeshInstance3D
var vertices := PackedVector3Array()
var colors := PackedColorArray()
var ground_cache: Dictionary = {}
var last_preview: Dictionary = {}
var _signature := ""

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh_instance = MeshInstance3D.new()
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 8
	mesh_instance.material_override = material
	add_child(mesh_instance)

func show_preview(data: Dictionary) -> void:
	last_preview = data
	visible = true
	var action: Dictionary = data.action
	var origin: Vector3 = data.origin
	var point: Vector3 = data.intent.point
	var direction: Vector3 = data.intent.direction
	var signature := "%s:%s:%s:%s:%s:%s" % [action.get("id", ""), origin.snapped(Vector3.ONE * .025), point.snapped(Vector3.ONE * .025), direction.snapped(Vector3.ONE * .004), data.valid, str([action.get("range"), action.get("radius"), action.get("width")])]
	if signature == _signature: return
	_signature = signature
	vertices.clear()
	colors.clear()
	ground_cache.clear()
	var fill := Color(BLUE, .24 if data.valid else .09)
	var edge := Color(BLUE if data.valid else INVALID, .88)
	var reach := maxf(0, float(action.get("range", 3)))
	var radius := maxf(.1, float(action.get("radius", reach)))
	var targeting := CombatTargeting.shape_for(action)
	match targeting:
		"CIRCLE", "SELF/CIRCLE": _circle(point if action.get("center_on_point", false) else origin, radius, fill, edge)
		"SELF": _circle(origin, .65, Color(BLUE, .07), edge)
		"POINT", "POINT/CIRCLE", "POINT/LINE":
			_range(origin, reach)
			if targeting == "POINT/LINE":
				_line_area(point - direction * float(action.get("length", 7)) * .5, direction, float(action.get("length", 7)), float(action.get("width", 1)), fill, edge)
			else: _circle(point, maxf(.55, radius) if action.get("presentation_type", "") == "VFX_ONLY" else radius, fill, edge)
			_reticle(point, edge)
		"TARGET":
			_range(origin, reach)
			var reference: Variant = data.intent.get("target")
			var target: Node = reference.get_ref() if reference is WeakRef else null
			var target_radius: float = maxf(.5, float(target.definition.body.radius) * float(target.definition.body.scale.x) + .15) if is_instance_valid(target) else .5
			_circle(point, target_radius, Color(BLUE, .10), edge)
			_reticle(point, edge, target_radius + .2)
			_segment(origin, point, .055, Color(edge, .55))
		"CONE": _sector(origin, direction, reach, float(action.get("angle_degrees", action.get("angle", 90))), fill, edge)
		"LINE", "DIRECTION":
			var line_origin := point - direction * reach * .5 if action.get("center_on_point", action.get("point_origin", false)) else origin
			if line_origin != origin: _range(origin, reach)
			var projectiles := maxi(1, int(action.get("projectiles", 1)))
			for i in range(projectiles):
				var forward := direction.rotated(Vector3.UP, (float(i) - float(projectiles - 1) * .5) * .18)
				var width := CombatTargeting.projectile_radius(action) * 2.0 if float(action.get("projectile_speed", 0)) > 0 else float(action.get("width", 1))
				_line_area(line_origin, forward, reach, width, fill, edge)
				_arrow(line_origin + forward * reach, forward, edge)
			if float(action.get("explosion_radius", 0)) > 0:
				_circle(origin + direction * reach, float(action.explosion_radius), Color(BLUE, .06), Color(edge, .45))
	_commit_mesh()

func _commit_mesh() -> void:
	if vertices.is_empty():
		mesh_instance.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_instance.mesh = mesh

func _ground(at: Vector3) -> Vector3:
	var key := Vector2(at.x, at.z)
	if ground_cache.has(key): return ground_cache[key]
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 14, at - Vector3.UP * 20, 1)
	var hit: Dictionary = actor.get_world_3d().direct_space_state.intersect_ray(query)
	var result := at
	if not hit.is_empty(): result.y = float(hit.position.y)
	if is_instance_valid(actor.arena.host) and actor.arena.host.has_method("water_surface_at"):
		var water: float = actor.arena.host.water_surface_at(at)
		if is_finite(water): result.y = maxf(result.y, water)
	result.y += .055
	ground_cache[key] = result
	return result

func _triangle(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	for at in [a, b, c]:
		vertices.append(_ground(at))
		colors.append(color)

func _segment(a: Vector3, b: Vector3, width: float, color: Color) -> void:
	var direction := Vector3(b.x - a.x, 0, b.z - a.z).normalized()
	var side := direction.cross(Vector3.UP) * width * .5
	_triangle(a + side, b + side, b - side, color)
	_triangle(a + side, b - side, a - side, color)

func _circle(center: Vector3, radius: float, fill: Color, edge: Color) -> void:
	for i in range(SEGMENTS):
		var a := center + Vector3(sin(TAU * i / SEGMENTS), 0, cos(TAU * i / SEGMENTS)) * radius
		var b := center + Vector3(sin(TAU * (i + 1) / SEGMENTS), 0, cos(TAU * (i + 1) / SEGMENTS)) * radius
		if fill.a > 0: _triangle(center, a, b, fill)
		_segment(a, b, .075, edge)

func _range(center: Vector3, radius: float) -> void:
	for i in range(SEGMENTS):
		if i % 4 >= 3: continue
		var a := center + Vector3(sin(TAU * i / SEGMENTS), 0, cos(TAU * i / SEGMENTS)) * radius
		var b := center + Vector3(sin(TAU * (i + 1) / SEGMENTS), 0, cos(TAU * (i + 1) / SEGMENTS)) * radius
		_segment(a, b, .055, Color(BLUE, .42))

func _sector(origin: Vector3, direction: Vector3, reach: float, angle: float, fill: Color, edge: Color) -> void:
	if angle >= 359.9:
		_circle(origin, reach, fill, edge)
		return
	var arc := deg_to_rad(angle)
	var steps := maxi(8, ceili(SEGMENTS * angle / 360.0))
	for i in range(steps):
		var a := origin + direction.rotated(Vector3.UP, -arc * .5 + arc * i / steps) * reach
		var b := origin + direction.rotated(Vector3.UP, -arc * .5 + arc * (i + 1) / steps) * reach
		_triangle(origin, a, b, fill)
		_segment(a, b, .075, edge)
	_segment(origin, origin + direction.rotated(Vector3.UP, -arc * .5) * reach, .075, edge)
	_segment(origin, origin + direction.rotated(Vector3.UP, arc * .5) * reach, .075, edge)

func _line_area(origin: Vector3, direction: Vector3, length: float, width: float, fill: Color, edge: Color) -> void:
	var side := direction.cross(Vector3.UP) * maxf(.1, width) * .5
	# Subdivide long strips so the transparent surface follows slopes/steps.
	var steps := maxi(1, ceili(length / .65))
	for i in range(steps):
		var a := origin + direction * length * i / steps
		var b := origin + direction * length * (i + 1) / steps
		_triangle(a + side, b + side, b - side, fill)
		_triangle(a + side, b - side, a - side, fill)
		_segment(a + side, b + side, .075, edge)
		_segment(a - side, b - side, .075, edge)
	_segment(origin + side, origin - side, .075, edge)
	_segment(origin + direction * length + side, origin + direction * length - side, .075, edge)

func _arrow(tip: Vector3, direction: Vector3, edge: Color) -> void:
	var side := direction.cross(Vector3.UP) * .32
	_segment(tip, tip - direction * .60 + side, .09, edge)
	_segment(tip, tip - direction * .60 - side, .09, edge)

func _reticle(center: Vector3, edge: Color, radius := .22) -> void:
	for axis in [Vector3.RIGHT, Vector3.FORWARD]:
		_segment(center - axis * radius, center + axis * radius, .075, edge)
