extends Control
## A single cartographic document shared by the local radar and unfolded chart.
## Elevation and placements are read from the live WaterGarden scene.
const F=preload("res://scripts/frontend/field_guide_art.gd")
const L=preload("res://scripts/world_layout.gd")
const BOUNDS=Rect2(-32,-72,106,101)
const RESOLUTION=Vector2(1075,1024)
var world_root: Node3D
var trees: Array[Vector2]=[]
var houses: Array[Dictionary]=[]
var roads: Array[PackedVector2Array]=[]
var landmarks: Array[Dictionary]=[]
var elevation: ImageTexture
var background: TextureRect

func point(local: Vector2) -> Vector2: return (local-BOUNDS.position)/BOUNDS.size*RESOLUTION

func build(source: Node3D) -> void:
	world_root=source
	size=RESOLUTION
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	var terrain: Node3D=source.get_node("SculptableTerrain")
	var terrain_inverse: Transform3D=terrain.global_transform.affine_inverse()*source.global_transform
	var dimension: Vector2i=Vector2i(terrain.dimensions.x-1,terrain.dimensions.z-1)
	var cell: Vector2=terrain.cell_size
	var image := Image.create(384,366,false,Image.FORMAT_RF)
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var p: Vector2=BOUNDS.position+Vector2(float(x)/383,float(y)/365)*BOUNDS.size
			var local: Vector3=terrain_inverse*Vector3(p.x,0,p.y)
			var grid := Vector2(local.x,local.z)/cell
			var coord := Vector2i(floori(grid.x/dimension.x),floori(grid.y/dimension.y))
			var chunk: Node=terrain.chunks.get(coord)
			var h := -1.5
			if is_instance_valid(chunk) and not chunk.height_map.is_empty():
				var within: Vector2=grid-Vector2(coord*dimension)
				var ix := clampi(floori(within.x),0,dimension.x-1)
				var iy := clampi(floori(within.y),0,dimension.y-1)
				var top: float=lerpf(chunk.height_map[iy][ix],chunk.height_map[iy][ix+1],fract(within.x))
				var bottom: float=lerpf(chunk.height_map[iy+1][ix],chunk.height_map[iy+1][ix+1],fract(within.x))
				h=lerpf(top,bottom,fract(within.y))
			h=L.FEATURES.ground_at(p,h)
			image.set_pixel(x,y,Color((h+3)/10,0,0))
	elevation=ImageTexture.create_from_image(image)
	background=TextureRect.new()
	background.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	background.texture=elevation
	background.size=RESOLUTION
	background.mouse_filter=Control.MOUSE_FILTER_IGNORE
	background.material=ShaderMaterial.new()
	background.material.shader=preload("res://shaders/frontend/atlas_ground.gdshader")
	background.material.set_shader_parameter("elevation",elevation)
	add_child(background)
	background.show_behind_parent=true
	_collect(source)
	landmarks=[{"name":"水边遗迹","kind":"ruin","at":Vector2(-5,-2.5)}, {"name":"风铃村","kind":"village","at":Vector2(-2,-41)}, {"name":"低语森林","kind":"forest","at":Vector2(42,5)}]
	queue_redraw()

func fract(value: float) -> float: return value-floorf(value)

func _collect(node: Node) -> void:
	if node is Node3D:
		var pos: Vector3=world_root.to_local(node.global_position)
		if str(node.name).begins_with("BranchingTree_") or str(node.name).begins_with("Willow_") or str(node.name).begins_with("Aspen_"):
			trees.append(Vector2(pos.x,pos.z))
			return
		if str(node.get_parent().name)=="Buildings":
			houses.append({"at":Vector2(pos.x,pos.z),"name":str(node.name),"angle":node.rotation.y})
			return
		if node is MeshInstance3D and node.mesh and (str(node.get_parent().name) in ["RegionConnections","DoorstepLanes"] or str(node.get_meta("footstep_surface",""))=="dirt"):
			var array: Array=node.mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array=array[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array=array[Mesh.ARRAY_INDEX] if array[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
			var count: int=indices.size() if not indices.is_empty() else vertices.size()
			for i in range(0,count-2,3):
				var triangle := PackedVector2Array()
				for j in range(3):
					var p: Vector3=world_root.to_local(node.to_global(vertices[indices[i+j] if not indices.is_empty() else i+j]))
					triangle.append(point(Vector2(p.x,p.z)))
				if absf((triangle[1]-triangle[0]).cross(triangle[2]-triangle[0]))>.001: roads.append(triangle)
	for child in node.get_children(): _collect(child)

func _draw() -> void:
	if not is_instance_valid(world_root): return
	for triangle in roads: draw_colored_polygon(triangle,Color("c7b58a"))
	for route in [L.EAST_ROAD,L.NORTH_ROAD,L.WOODLAND_ROAD]:
		var line := PackedVector2Array()
		for v: Vector2 in route: line.append(point(v))
		draw_polyline(line,Color("93825d",.45),1.2,true)
	for bridge in [[Vector2(10.8,1.7),Vector2(25,1.7)],[Vector2(0,-8.8),Vector2(0,-25.1)]]:
		var a: Vector2=point(bridge[0]);var b: Vector2=point(bridge[1])
		var normal: Vector2=(b-a).normalized().orthogonal()*9
		F.pen(self,a-normal,b-normal,Color("6a5a42"),2)
		F.pen(self,a+normal,b+normal,Color("6a5a42"),2)
		for i in range(ceili(a.distance_to(b)/7)):
			var at: Vector2=a.lerp(b,float(i)/ceili(a.distance_to(b)/7))
			F.pen(self,at-normal,at+normal,Color("8a7351"),1)
	for p in trees: _tree(point(p),9+fmod(absf(p.x)*7,7))
	for house in houses: _house(point(house.at),house.name.contains("Tower"))
	var shrine := point(Vector2(-5,-2.5))
	F.ring(self,shrine,42,Color("726c50"),2)
	F.ring(self,shrine,34,Color("bbaa7b"),3)
	F.ring(self,shrine,9,Color("7c7960"),2)
	for i in range(9):
		var a: float=i*TAU/9
		F.pen(self,shrine+Vector2.from_angle(a)*35,shrine+Vector2.from_angle(a)*43,Color("716c50"),1.3)
	var island_path := PackedVector2Array()
	for z in range(-6,10): island_path.append(point(Vector2(1.6+sin(z*.43)*1.2,z)))
	draw_polyline(island_path,Color("c1b58b"),9,true)

func _tree(p: Vector2,r: float) -> void:
	F.wash(self,p+Vector2(2,5),Vector2(r*1.2,r*.8),Color("4c6d50",.8))
	F.stroke(self,p,r,[Vector2(0,.8),Vector2(0,-.6)],Color("5d6648"),1.1)
	F.shape(self,p,r,[Vector2(0,-1.3),Vector2(-.55,-.4),Vector2(-.23,-.45),Vector2(-.85,.22),Vector2(-.43,.15),Vector2(-1,.65),Vector2(.86,.65),Vector2(.40,.15),Vector2(.72,.23),Vector2(.21,-.46),Vector2(.44,-.40)],Color("8eaa79",.8),Color("5b734e",.66),.8)

func _house(p: Vector2,tower: bool) -> void:
	var r := 18.0 if not tower else 15.0
	F.wash(self,p+Vector2(7,13),Vector2(r,r*.5),Color("776953",.8))
	F.shape(self,p,r,[Vector2(-.8,.65),Vector2(-.8,-.22),Vector2(0,-.77),Vector2(.8,-.2),Vector2(.8,.65)],Color("ded3ad"),Color("685c47"),1.3)
	F.shape(self,p,r,[Vector2(-1,-.2),Vector2(0,-1.1 if tower else -.84),Vector2(1,-.2),Vector2(.85,0),Vector2(0,-.65),Vector2(-.8,0)],Color("a27b59"),Color("685c47"),1)
	F.stroke(self,p,r,[Vector2(-.16,.6),Vector2(-.16,.11),Vector2(.17,.11),Vector2(.17,.6)],Color("786548"),1.4)
	if tower: F.ring(self,p+Vector2(0,-3),4,Color("766747"),1)
