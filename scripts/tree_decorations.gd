@tool
extends Node3D
## Detachable fruit and blossom layer. Crown/trunk geometry is independent.
const FRUIT_SHADER = preload("res://shaders/orchard_fruit.gdshader")
const BLOSSOM_SHADER = preload("res://shaders/tree_blossom.gdshader")
@export_enum("None", "Apple", "Pear", "Mixed") var fruit_kind: int = 1:
	set(value):
		fruit_kind=value
		request_rebuild()
@export var blossoms: bool = false:
	set(value):
		blossoms=value
		request_rebuild()
@export var blossom_color:=Color("fff0d2"):
	set(value):
		blossom_color=value
		request_rebuild()
@export var decoration_seed:=0
@export var fruit_sockets:=PackedVector3Array()
@export var blossom_sockets:=PackedVector3Array()
var _queued:=false
func _ready():
	if get_child_count()==0: request_rebuild()
func request_rebuild():
	if not is_inside_tree() or _queued: return
	_queued=true
	call_deferred("rebuild")
func rebuild():
	_queued=false
	for child in get_children(): child.free()
	var rng:=RandomNumberGenerator.new()
	rng.seed=decoration_seed+761
	var apples: Array[Transform3D]=[]
	var pears: Array[Transform3D]=[]
	var stems: Array[Transform3D]=[]
	if fruit_kind!=0:
		for i in range(fruit_sockets.size()):
			var pear:=fruit_kind==2 or (fruit_kind==3 and i%2==0)
			var size:=rng.randf_range(.38,.48)
			var p:=fruit_sockets[i]
			var xf:=Transform3D(Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3.ONE*size),p)
			if pear: pears.append(xf)
			else: apples.append(xf)
			stems.append(Transform3D(Basis.IDENTITY,p+Vector3.UP*size*(.71 if pear else .58)))
	if not apples.is_empty(): instances("Apples",fruit_mesh(false),apples)
	if not pears.is_empty(): instances("Pears",fruit_mesh(true),pears)
	if not stems.is_empty():
		var stem:=CylinderMesh.new()
		stem.top_radius=.012
		stem.bottom_radius=.019
		stem.height=.16
		stem.radial_segments=5
		var mat:=StandardMaterial3D.new()
		mat.albedo_color=Color("654627")
		mat.roughness=1
		stem.material=mat
		instances("FruitStems",stem,stems)
	if blossoms and not blossom_sockets.is_empty():
		var flowers: Array[Transform3D]=[]
		for p in blossom_sockets:
			var size:=rng.randf_range(.17,.26)
			flowers.append(Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*size),p))
		var quad:=QuadMesh.new()
		quad.size=Vector2.ONE
		var mat:=ShaderMaterial.new()
		mat.shader=BLOSSOM_SHADER
		mat.set_shader_parameter("petal_color",blossom_color)
		quad.material=mat
		instances("Blossoms",quad,flowers)
	if Engine.is_editor_hint():
		var scene:=get_tree().edited_scene_root
		if scene and scene.is_ancestor_of(self):
			for child in get_children(): child.owner=scene
func instances(label: String, mesh: Mesh, transforms: Array[Transform3D]):
	var node:=MultiMeshInstance3D.new()
	node.name=label
	node.multimesh=MultiMesh.new()
	node.multimesh.transform_format=MultiMesh.TRANSFORM_3D
	node.multimesh.mesh=mesh
	node.multimesh.instance_count=transforms.size()
	for i in range(transforms.size()): node.multimesh.set_instance_transform(i,transforms[i])
	node.extra_cull_margin=.4
	if label=="Blossoms": node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
static func fruit_mesh(pear: bool) -> ArrayMesh:
	var st:=SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array[Vector3]=[]
	for j in range(9):
		var t:=PI*float(j)/8
		for i in range(10):
			var a:=TAU*float(i)/10
			var r:=sin(t)*((.46-.20*cos(t)) if pear else (.48+.055*cos(t)))
			var y:=cos(t)*(.63 if pear else .45)
			if not pear and j==0: y=.35
			if not pear and j==8: y=-.38
			rings.append(Vector3(cos(a)*r,y,sin(a)*r))
	for j in range(8):
		for i in range(10):
			var k:=j*10+i
			var next:=j*10+(i+1)%10
			for p in [rings[k],rings[k+10],rings[next+10],rings[k],rings[next+10],rings[next]]:
				st.set_normal(p.normalized())
				st.add_vertex(p)
	var mesh:=st.commit()
	var mat:=ShaderMaterial.new()
	mat.shader=FRUIT_SHADER
	if pear:
		mat.set_shader_parameter("red",Color("c9b43d"))
		mat.set_shader_parameter("red_shadow",Color("797330"))
		mat.set_shader_parameter("red_light",Color("f2d966"))
	mesh.surface_set_material(0,mat)
	return mesh
