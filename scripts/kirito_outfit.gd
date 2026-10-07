extends RefCounted
## Instance-local fabric dyes/patterns on the original skinned Kirito surfaces.
const SHADER = preload("res://shaders/kirito_outfit.gdshader")
const Database = preload("res://combat/combat_database.gd")
const SLOTS := ["torso", "legs", "feet", "head", "belt", "neck", "ring1", "ring2"]
const PATTERNS := {"tunic": 1, "armor": 2, "pants": 3, "greaves": 4, "shoes": 5, "boots": 6, "hood": 1, "helm": 2}
var surfaces: Array[Dictionary] = []
var equipment: Dictionary = {}
var prepared := false
var _catalog: Dictionary = {}

func apply(body: Node3D, items: Dictionary) -> void:
	if not prepared:
		_prepare(body)
		prepared = true
	equipment.clear()
	for key in items:
		var value: Variant = items[key]
		if value is String:
			if _catalog.is_empty():
				_catalog = Database.new().equipment
			value = _catalog.get(value, {})
		equipment[str(key).to_lower()] = value.duplicate(true) if value is Dictionary else {}
	var has_outfit := equipment.values().any(func(item): return not item.is_empty())
	for entry in surfaces:
		var material: ShaderMaterial = entry.material
		for slot: String in SLOTS:
			var item: Dictionary = equipment.get(slot, {})
			var visual: Dictionary = item.get("visual", {})
			var color := Color(str(visual.get("color", item.get("color", "#ffffff")))) if not item.is_empty() else Color(0, 0, 0, 0)
			material.set_shader_parameter(slot + "_color", color)
			if slot in ["torso", "legs", "feet", "head"]:
				material.set_shader_parameter(slot + "_pattern", int(PATTERNS.get(str(visual.get("style", "")), 0)))
		entry.mesh.set_surface_override_material(entry.surface, material if has_outfit else entry.original)

func _prepare(body: Node3D) -> void:
	for node: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
		var source: Mesh = node.mesh
		var layers: Dictionary = {}
		for surface in range(source.get_surface_count()):
			var original: Material = source.surface_get_material(surface)
			var label := original.resource_name.to_lower() if original else ""
			if "shen_ti" in label: layers[surface] = 0
			elif "fushi1" in label: layers[surface] = 1
			elif "fu_shi2" in label: layers[surface] = 2
		if layers.is_empty():
			continue
		var masked := ArrayMesh.new()
		for surface in range(source.get_surface_count()):
			var arrays: Array = source.surface_get_arrays(surface)
			var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var mask := PackedVector2Array()
			for point in positions:
				mask.append(Vector2(point.x, point.y))
			arrays[Mesh.ARRAY_TEX_UV2] = mask
			var flags: int = source.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
			masked.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays, [], {}, flags)
			masked.surface_set_material(surface, source.surface_get_material(surface))
		# Only the new UV2 mask differs. Vertex/index/skin arrays and the node's
		# Skeleton/Skin bindings remain exact copies of the original garment.
		node.mesh = masked
		for surface: int in layers:
			var original: ShaderMaterial = node.get_surface_override_material(surface)
			var material := ShaderMaterial.new()
			material.shader = SHADER
			for parameter: String in ["albedo_texture", "has_texture", "tint"]:
				material.set_shader_parameter(parameter, original.get_shader_parameter(parameter))
			material.set_shader_parameter("cloth_layer", layers[surface])
			surfaces.append({"mesh": node, "surface": surface, "original": original, "material": material})
