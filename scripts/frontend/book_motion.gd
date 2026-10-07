extends Control
## Cylindrical curl with two printed faces. See docs/frontend/page-curl-sources.md.
## CPU tessellation keeps real Control snapshots together with their illustrations.
const A=preload("res://scripts/frontend/ui_art.gd")
const F=preload("res://scripts/frontend/field_guide_art.gd")
const SHEET=preload("res://shaders/frontend/book_sheet.gdshader")
const COLUMNS=80
const ROWS=16
var mode := "open"
var direction := 1
var progress := 0.0
var book_rect := Rect2(120,79,1120,550)
var canvas_size := Vector2(1280,720)
var current: Texture2D
var previous: Texture2D
var cover_view: SubViewport
var sheet: MeshInstance2D
var shader: ShaderMaterial

class Cover extends Control:
	func _draw() -> void:
		var leather=preload("res://scripts/frontend/leather_art.gd")
		leather.draw(self,Rect2(0,0,560,550),Color("785037"),14)
		leather.draw(self,Rect2(6,6,32,538),Color("62452e"),8,false)
		for y in [98,267,436]: leather.draw(self,Rect2(2,y,39,20),Color("79593c"),4,false)
		F.centered(self,Vector2(300,184),"冒 险 手 记",35,Color("3e2b1f"),600)
		F.centered(self,Vector2(300,182),"冒 险 手 记",35,Color("c3a27b"),600)
		F.sprig(self,Vector2(307,313),75,Color("33281f",.7))
		F.sprig(self,Vector2(307,312),74,Color("ac8f6e",.7))
		leather.draw(self,Rect2(505,245,55,47),Color("67462f"),6)
		draw_circle(Vector2(527,268),5,Color("b08c55"))

func _ready() -> void:
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	cover_view=SubViewport.new()
	cover_view.size=Vector2i(560,550)
	cover_view.transparent_bg=true
	cover_view.disable_3d=true
	cover_view.render_target_update_mode=SubViewport.UPDATE_ONCE
	add_child(cover_view)
	cover_view.add_child(Cover.new())
	sheet=MeshInstance2D.new()
	shader=ShaderMaterial.new()
	shader.shader=SHEET
	sheet.material=shader
	add_child(sheet)

func release() -> void:
	previous=null
	current=null
	visible=false
	if is_instance_valid(sheet): sheet.mesh=null
	if is_instance_valid(shader):
		shader.set_shader_parameter("front_texture",null)
		shader.set_shader_parameter("back_texture",null)

func _region(tex: Texture2D,rect: Rect2) -> Vector4:
	var sz := Vector2(tex.get_size())
	return Vector4(rect.position.x/sz.x,rect.position.y/sz.y,rect.size.x/sz.x,rect.size.y/sz.y)

func _curl(uv: Vector2,t: float,width: float,height: float) -> Vector4:
	var x := uv.x*width
	var y := (uv.y-.5)*height
	var radius := maxf(.001,width*.135*sin(PI*t))
	var normal := Vector2.from_angle(-.14*pow(sin(PI*t),2))
	var crease := width*(1-t)-PI*radius*.5
	var distance := Vector2(x,y).dot(normal)-crease
	var theta := clampf(distance/radius,0,PI)
	var offset := 0.0
	var z := 0.0
	if distance>0:
		if distance<PI*radius:
			offset=radius*sin(theta)-distance
			z=radius*(1-cos(theta))
		else:
			offset=PI*radius-2*distance
			z=2*radius
	var point := Vector2(x,y)+normal*offset
	return Vector4(point.x,point.y-z*.16,z,theta)

func _vertex(uv: Vector2,t: float,width: float,height: float,hard: bool) -> Vector4:
	if not hard: return _curl(uv,t,width,height)
	var angle := PI*t
	var z := sin(angle)*uv.x*width
	var perspective := 1700.0/(1700.0-z*.22)
	return Vector4(cos(angle)*uv.x*width*perspective,(uv.y-.5)*height*perspective-z*.09,z,angle)

func _make_sheet(front: Texture2D,back: Texture2D,front_rect: Rect2,back_rect: Rect2,spine: Vector2,width: float,height: float,t: float,hard := false,alpha := 1.0) -> void:
	if not front or not back: sheet.mesh=null; return
	var sign_x := float(direction) if not hard else 1.0
	var columns := 12 if hard else COLUMNS
	var rows := 2 if hard else ROWS
	var vertices: Array[Vector4]=[]
	var texture_uv: Array[Vector2]=[]
	for row in range(rows+1):
		for col in range(columns+1):
			var uv := Vector2(float(col)/columns,float(row)/rows)
			vertices.append(_vertex(uv,t,width,height,hard))
			texture_uv.append(uv)
	# Painter order is based on height, rather than switching the entire sheet at 50%.
	var triangles: Array[Vector4]=[]
	for row in range(rows):
		for col in range(columns):
			var a := row*(columns+1)+col
			var b := a+1
			var c := a+columns+2
			var d := c-1
			triangles.append(Vector4(a,b,c,(vertices[a].z+vertices[b].z+vertices[c].z)/3))
			triangles.append(Vector4(a,c,d,(vertices[a].z+vertices[c].z+vertices[d].z)/3))
	triangles.sort_custom(func(a: Vector4,b: Vector4): return a.w<b.w)
	var positions := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	for triangle: Vector4 in triangles:
		var ids := [int(triangle.x),int(triangle.y),int(triangle.z)]
		var theta: float=(vertices[ids[0]].w+vertices[ids[1]].w+vertices[ids[2]].w)/3
		var rear := theta>PI*.5
		for index: int in ids:
			var v: Vector4=vertices[index]
			positions.append(Vector3(spine.x+sign_x*v.x,spine.y+v.y,0))
			var shade := 1.0-.19*pow(absf(sin(v.w)),1.5)
			colors.append(Color(shade,1.0 if rear else 0.0,0,1))
			uvs.append(texture_uv[index])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=positions
	arrays[Mesh.ARRAY_COLOR]=colors
	arrays[Mesh.ARRAY_TEX_UV]=uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	sheet.mesh=mesh
	shader.set_shader_parameter("front_texture",front)
	shader.set_shader_parameter("back_texture",back)
	shader.set_shader_parameter("front_region",_region(front,front_rect))
	shader.set_shader_parameter("back_region",_region(back,back_rect))
	shader.set_shader_parameter("mirror_front",direction<0 and not hard)
	shader.set_shader_parameter("mirror_back",direction>0 or hard)
	shader.set_shader_parameter("canvas_size",canvas_size)
	shader.set_shader_parameter("sheet_origin",book_rect.position)
	shader.set_shader_parameter("opacity",alpha)
	# Soft penumbra is cast onto the resting sheets, and broadens with page height.
	var outline := PackedVector2Array()
	for row in [0,rows]:
		for col in range(columns+1):
			var v: Vector4=vertices[row*(columns+1)+col]
			outline.append(spine+Vector2(sign_x*v.x+v.z*.15,v.y+v.z*.24))
	var hull := Geometry2D.convex_hull(outline)
	if hull.size()<3: return
	var center := Vector2.ZERO
	for point in hull: center+=point
	center/=hull.size()
	var clip := PackedVector2Array([book_rect.position,book_rect.position+Vector2(book_rect.size.x,0),book_rect.end,book_rect.position+Vector2(0,book_rect.size.y)])
	for layer in range(7,0,-1):
		var shadow := PackedVector2Array()
		for point in hull: shadow.append(point+(point-center).normalized()*layer*1.8*sin(PI*t))
		var areas: Array=Geometry2D.intersect_polygons(shadow,clip) if not hard else [shadow]
		for area: PackedVector2Array in areas:
			if area.size()>2: draw_colored_polygon(area,Color(.16,.12,.07,.023*sin(PI*t)*alpha))

func _draw() -> void:
	if not current or not is_instance_valid(sheet): return
	var p := book_rect.position
	var left := Rect2(p+Vector2(8,16),Vector2(552,524))
	var right := Rect2(p+Vector2(560,16),Vector2(552,524))
	var t := smoothstep(0,1,progress)
	if mode=="turn":
		# Book covers, external tabs and the newly exposed sheet never deform.
		draw_texture_rect(current,Rect2(Vector2.ZERO,canvas_size),false)
		if not previous: return
		var resting := left if direction>0 else right
		draw_texture_rect_region(previous,resting,resting)
		_make_sheet(previous,current,right if direction>0 else left,left if direction>0 else right,p+Vector2(560,278),552,524,t)
	else:
		var alpha := smoothstep(0,.08,progress)
		# The closed folio is presented at a slight three-quarter angle, then
		# settles flat as the cover opens; avoid a square floating menu card.
		var w := 552*lerpf(.76,1,t)
		var h := 524*lerpf(1.025,1,t)
		var spine := p+Vector2(560-w*.5*(1-t),278+24*(1-t))
		if t>.74: draw_texture_rect(current,Rect2(Vector2.ZERO,canvas_size),false,Color(1,1,1,smoothstep(.74,1,t)))
		A.plate(self,Rect2(spine+Vector2(-9,-h*.5-9),Vector2(w+18,h+35)),Color(.32,.21,.13,alpha),Color.TRANSPARENT,10)
		draw_texture_rect_region(current,Rect2(spine-Vector2(0,h*.5),Vector2(w,h)),right,Color(1,1,1,alpha))
		_make_sheet(cover_view.get_texture(),current,Rect2(0,0,560,550),left,spine,w,h,t,true,alpha)
