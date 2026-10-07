extends RefCounted
## Shared by the full-map authoring tool and the focused lake-bed update.
const L = preload("res://scripts/world_layout.gd")
const A = preload("res://scripts/reference_art.gd")

static func build(map: Node3D) -> int:
	if map.has_node("LakeBed"): map.get_node("LakeBed").free()
	var bed:=MeshInstance3D.new()
	bed.name="LakeBed"
	var plane:=PlaneMesh.new()
	plane.size=Vector2(220,220)
	bed.mesh=plane
	# Join the editable terrain's -1.5 m underwater floor. A deep backdrop
	# leaves a straight 2 m drop that casts a visible line across clear water.
	bed.position.y=-1.55
	bed.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat:=ShaderMaterial.new()
	mat.shader=preload("res://shaders/reference_terrain.gdshader")
	bed.material_override=mat
	map.add_child(bed)
	if map.has_node("SubmergedPebbles"): map.get_node("SubmergedPebbles").free()
	var pebbles:=MultiMeshInstance3D.new()
	pebbles.name="SubmergedPebbles"
	pebbles.multimesh=MultiMesh.new()
	pebbles.multimesh.transform_format=MultiMesh.TRANSFORM_3D
	var stone:=SphereMesh.new()
	stone.radius=1
	stone.height=2
	stone.radial_segments=7
	stone.rings=3
	stone.material=A.material(Color("93a293"))
	pebbles.multimesh.mesh=stone
	var rng:=RandomNumberGenerator.new()
	rng.seed=2256
	var transforms: Array[Transform3D]=[]
	for i in range(700):
		var x:=rng.randf_range(-24,67)
		var z:=rng.randf_range(-69,24)
		var h:=L.ground(x,z)
		if h>-.25 or h< -1.5: continue
		var size:=rng.randf_range(.18,.45)
		transforms.append(Transform3D(Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(size,size*.38,size*.8)),Vector3(x,h+.055,z)))
	pebbles.multimesh.instance_count=transforms.size()
	for i in range(transforms.size()): pebbles.multimesh.set_instance_transform(i,transforms[i])
	pebbles.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	map.add_child(pebbles)
	return transforms.size()
