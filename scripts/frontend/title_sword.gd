extends Node3D
## A single prop persists from the grass to the hand and the back attachment.
const A=preload("res://scripts/reference_art.gd")
func _ready() -> void:
	var silver := A.material(Color("9cbbb9"))
	var dark := A.material(Color("25333c"))
	var grip := A.material(Color("202b30"))
	var shape := PackedVector2Array([Vector2(-.11,.14),Vector2(-.12,1.38),Vector2(0,1.70),Vector2(.12,1.38),Vector2(.11,.14)])
	var mesh := ArrayMesh.new()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for side in [-1.0,1.0]:
		var base := vertices.size()
		for point in shape:
			vertices.append(Vector3(point.x,point.y,side*.026))
			normals.append(Vector3(0,0,side))
		for i in range(1,shape.size()-1):
			indices.append_array(PackedInt32Array([base,base+i,base+i+1] if side<0 else [base,base+i+1,base+i]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices
	arrays[Mesh.ARRAY_NORMAL]=normals
	arrays[Mesh.ARRAY_INDEX]=indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var blade := MeshInstance3D.new()
	blade.mesh=mesh
	blade.material_override=dark
	add_child(blade)
	for side in [-1.0,1.0]:
		A.block(self,Vector3(side*.107,.77,0),Vector3(.025,1.25,.047),silver,false)
	A.block(self,Vector3(0,.11,0),Vector3(.53,.07,.10),dark,false)
	A.block(self,Vector3(0,.11,.003),Vector3(.08,.15,.115),silver,false)
	A.block(self,Vector3(0,-.09,0),Vector3(.075,.30,.075),grip,false)
	A.block(self,Vector3(0,-.26,0),Vector3(.11,.075,.10),silver,false)
