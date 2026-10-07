extends RefCounted
## Small, original mesh kit. All art is generated locally; no asset downloads.

const TOON = preload("res://shaders/toon.gdshader")
static var materials: Dictionary = {}

static func mat(color: Color, glow: float = 0.0, wind: float = 0.0, variation: float = 0.0) -> ShaderMaterial:
	var key := "%s/%s/%s/%s" % [color.to_html(), glow, wind, variation]
	if materials.has(key):
		return materials[key]
	var m := ShaderMaterial.new()
	m.shader = TOON
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("glow", glow)
	m.set_shader_parameter("wind", wind)
	m.set_shader_parameter("variation", variation)
	materials[key] = m
	return m

static func mesh(parent: Node3D, shape: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = shape
	node.material_override = material
	node.position = at
	parent.add_child(node)
	return node

static func box(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var shape := BoxMesh.new()
	shape.size = size
	return mesh(parent, shape, at, mat(color))

static func sphere(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var shape := SphereMesh.new()
	shape.radius = 0.5
	shape.height = 1.0
	shape.radial_segments = 8
	shape.rings = 3
	var n := mesh(parent, shape, at, mat(color))
	n.scale = size
	return n

static func cylinder(parent: Node3D, at: Vector3, radius: float, height: float, color: Color, sides: int = 10, top: float = -1.0) -> MeshInstance3D:
	var shape := CylinderMesh.new()
	shape.bottom_radius = radius
	shape.top_radius = radius if top < 0.0 else top
	shape.height = height
	shape.radial_segments = sides
	return mesh(parent, shape, at, mat(color))

static func solid_box(parent: Node3D, at: Vector3, size: Vector3, color: Color, visible_mesh: bool = true) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	body.collision_layer = 1
	parent.add_child(body)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	if visible_mesh:
		box(body, Vector3.ZERO, size, color)
	return body

static func ring(parent: Node3D, at: Vector3, radius: float, width: float, color: Color, start: float = 0.0, arc: float = TAU) -> MeshInstance3D:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(48):
		var a := start + arc * float(i) / 48.0
		var b := start + arc * float(i + 1) / 48.0
		var va := Vector3(sin(a), 0, cos(a))
		var vb := Vector3(sin(b), 0, cos(b))
		for v in [va * radius, vb * radius, va * (radius - width), vb * radius, vb * (radius - width), va * (radius - width)]:
			surface.set_normal(Vector3.UP)
			surface.add_vertex(v)
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mesh(parent, surface.commit(), at, m)

static func line(parent: Node3D, a: Vector3, b: Vector3, width: float, color: Color) -> MeshInstance3D:
	var shape := BoxMesh.new()
	shape.size = Vector3(width, width, a.distance_to(b))
	var n := mesh(parent, shape, (a + b) * 0.5, mat(color, 0.2))
	if a.distance_to(b) > 0.001:
		n.look_at_from_position((a + b) * 0.5, b, Vector3.RIGHT if abs((b-a).normalized().y) > 0.99 else Vector3.UP)
	return n
