extends SceneTree
const Batches = preload("res://rpg/static_prop_batches.gd")
var checks := 0
var failures: Array[String] = []

func verify(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
	print("PASS " if value else "FAIL ", label)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var map := Node3D.new()
	map.position = Vector3(0, 0, 110)
	root.add_child(map)
	var material := ShaderMaterial.new()
	material.shader = Batches.PROP_SHADER
	var sources: Array[MeshInstance3D] = []
	var original_bounds := AABB()
	for i in range(5):
		var node := MeshInstance3D.new()
		node.mesh = BoxMesh.new()
		node.material_override = material
		node.position = Vector3(i + 1, 1, 1)
		node.rotation.y = i * .2
		node.scale = Vector3.ONE * (1.0 + i * .1)
		map.add_child(node)
		sources.append(node)
		var bounds: AABB = node.transform * node.mesh.get_aabb()
		original_bounds = bounds if i == 0 else original_bounds.merge(bounds)
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	body.add_child(collision)
	sources[0].add_child(body)
	var roof := MeshInstance3D.new()
	roof.mesh = BoxMesh.new()
	roof.material_override = material.duplicate()
	roof.material_override.set_shader_parameter("roof_tiles", true)
	map.add_child(roof)
	var stretched := MeshInstance3D.new()
	stretched.mesh = BoxMesh.new()
	stretched.material_override = material
	stretched.scale = Vector3(2, 1, 1)
	map.add_child(stretched)
	var tree := Node3D.new()
	tree.set_meta("tree_seed", 12)
	map.add_child(tree)
	for i in range(4):
		var trunk := MeshInstance3D.new()
		trunk.mesh = BoxMesh.new()
		trunk.material_override = material
		tree.add_child(trunk)
	var result := Batches.build(map)
	verify(result.source_meshes == 5 and result.batches == 1, "five compatible static draws merge into one")
	var batch: MeshInstance3D = map.get_node("StaticPropBatches").get_child(0)
	verify(batch.mesh.get_surface_count() == 1 and batch.get_active_material(0) == material, "batch retains the exact material")
	verify(batch.mesh.get_aabb().position.is_equal_approx(original_bounds.position) and batch.mesh.get_aabb().size.is_equal_approx(original_bounds.size), "rotations and uniform scale preserve geometry bounds")
	verify(not sources[0].visible and is_instance_valid(body) and not collision.disabled, "source path and live collision survive batching")
	verify(roof.visible and stretched.visible, "origin-dependent roof and nonuniform normals remain separate")
	verify(tree.get_child(0).visible, "per-tree wind shader instances remain independent")
	verify(batch.layers == sources[0].layers and batch.cast_shadow == sources[0].cast_shadow, "render layers and shadows are preserved")
	map.queue_free()
	await process_frame
	print("STATIC_PROP_BATCHES_RESULT checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
