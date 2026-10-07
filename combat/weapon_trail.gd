extends MeshInstance3D
## A short world-space history of the equipped weapon's real cutting edge.
## No duplicate samples or mesh uploads while the local action clock is frozen.
const LIFETIME := .055
const MAX_SAMPLES := 8
var _surface := ImmediateMesh.new()
var _samples: Array[Dictionary] = []
var _key := ""
var _last_time := -INF
var rebuilds := 0

func _init() -> void:
	mesh = _surface
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color(.68, .90, 1.0, .48)
	material_override = material
	visible = false

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY

func clear() -> void:
	if not _samples.is_empty():
		_samples.clear()
		_surface.clear_surfaces()
	visible = false
	_key = ""
	_last_time = -INF

func sample(active: bool, key: String, time: float, a: Vector3, b: Vector3) -> void:
	if not active:
		clear()
		return
	if key != _key:
		clear()
		_key = key
	if time <= _last_time + .000001: return
	_last_time = time
	var moved := true
	if not _samples.is_empty():
		var last: Dictionary = _samples.back()
		moved = a.distance_squared_to(last.a) + b.distance_squared_to(last.b) >= .000001
	if moved: _samples.append({"a": a, "b": b, "time": time})
	# Held poses fade on the local clock; hitstop returns above without uploads.
	while not _samples.is_empty() and (_samples.size() > MAX_SAMPLES or time - float(_samples[0].time) > LIFETIME):
		_samples.pop_front()
	_surface.clear_surfaces()
	visible = _samples.size() >= 2
	if not visible: return
	_surface.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(_samples.size() - 1):
		for corner in [Vector2i(i,0), Vector2i(i,1), Vector2i(i+1,1), Vector2i(i,0), Vector2i(i+1,1), Vector2i(i+1,0)]:
			var entry: Dictionary = _samples[corner.x]
			var alpha := clampf(1.0 - (time - float(entry.time)) / LIFETIME, 0.0, 1.0)
			_surface.surface_set_color(Color(1,1,1,alpha))
			_surface.surface_add_vertex(entry.a if corner.y == 0 else entry.b)
	_surface.surface_end()
	rebuilds += 1

static func edge(family: String, weapon: Dictionary) -> PackedVector3Array:
	match family:
		"SHORT_WEAPON": return PackedVector3Array([Vector3(0,0,-.12),Vector3(0,0,-.66)])
		"POLEARM": return PackedVector3Array([Vector3(0,0,-1.20),Vector3(0,0,-1.59)])
		"HEAVY_2H":
			var kind := str(weapon.get("weapon_type", weapon.get("model_id", ""))).to_lower()
			if "sword" in kind: return PackedVector3Array([Vector3(0,0,-.425),Vector3(0,0,-1.475)])
			# Axe and hammer trails span their actual head, not a sword-sized blade.
			var half_width := .315 if "hammer" in kind else .40
			var front := -1.135 if "hammer" in kind else -1.20
			return PackedVector3Array([Vector3(-half_width,0,front),Vector3(half_width,0,front)])
	return PackedVector3Array([Vector3(0,0,-.12),Vector3(0,0,-1.07)])
