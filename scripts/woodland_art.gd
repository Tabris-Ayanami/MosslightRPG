extends RefCounted
## Deterministic authoring geometry: branching trees and small meadow flowers.
## Foliage technique references and mask license: assets/foliage/eduardo/SOURCE.md.
const A = preload("res://scripts/reference_art.gd")
const LEAVES = preload("res://shaders/reference_canopy.gdshader")
const FLOWERS = preload("res://shaders/meadow_flower.gdshader")
const DECORATIONS = preload("res://scripts/tree_decorations.gd")
const BIRCH_BARK = preload("res://shaders/birch_bark.gdshader")
const CANOPY_SHADOW = preload("res://shaders/canopy_shadow.gdshader")

static func leaf_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Broad blades alternate along a short, diagonal shoot. Blunt shoulders and
	# tips survive the distant pixel grid without forming a repeated radial stamp.
	var shoots := [
		[Vector2(-.10,-.30),Vector2(-.48,-.12),.135],
		[Vector2(-.06,-.20),Vector2(.30,-.16),.125],
		[Vector2(.00,-.05),Vector2(-.34,.30),.145],
		[Vector2(.04,.13),Vector2(.38,.36),.130],
		[Vector2(.05,.20),Vector2(-.06,.56),.125],
	]
	for i in range(shoots.size()):
		var base: Vector2 = shoots[i][0]
		var tip: Vector2 = shoots[i][1]
		var side := (tip-base).normalized().orthogonal()*float(shoots[i][2])
		# Broad trapezoidal shoulders read as leaves rather than round beads.
		# The shallow side notch breaks the contour without subpixel teeth.
		var contour := PackedVector2Array([Vector2(.46,0),Vector2(.08,.28),Vector2(.03,.60),Vector2(.18,.64),Vector2(.16,.86),Vector2(.53,1),Vector2(.84,.80),Vector2(.97,.47),Vector2(.74,.20)])
		var indices := Geometry2D.triangulate_polygon(contour)
		# Geometry2D produces counter-clockwise faces; Godot's 3D front is clockwise.
		indices.reverse()
		for j in indices:
			var uv := contour[j]
			var p := base.lerp(tip,uv.y)+side*(uv.x-.5)*2.0
			st.set_normal(Vector3.BACK)
			var blade_axis := (tip-base).normalized()*.5+Vector2.ONE*.5
			st.set_color(Color(float(i)/6.0,blade_axis.x,blade_axis.y,1))
			st.set_uv(uv)
			st.add_vertex(Vector3(p.x,p.y,0))
	st.index()
	return st.commit()

static func shadow_lobe(st: SurfaceTool, center: Vector3, axes: Basis, size: Vector3, phase: float) -> void:
	# A shadow-only volume gives coherent occlusion without a second visible shell.
	# Its mild lobes follow the same organic contour as the leaf distribution.
	for ring in range(12):
		for segment in range(24):
			for corner: Vector2 in [Vector2(0,0),Vector2(1,0),Vector2(1,1),Vector2(0,0),Vector2(1,1),Vector2(0,1)]:
				var latitude := PI*(float(ring)+corner.y)/12.0
				var longitude := TAU*(float(segment)+corner.x)/24.0
				var d := Vector3(sin(latitude)*cos(longitude),cos(latitude),sin(latitude)*sin(longitude))
				var warp := .88+.10*sin(d.x*4.0+phase)+.07*cos(d.z*5.0-d.y*3.0)
				warp += .14*sin(longitude*7.0+phase*1.3)*sin(latitude)+.085*sin(latitude*9.0+longitude*3.0)
				st.set_normal(axes*d)
				st.add_vertex(center+axes*(d*size*warp*.84))

static func branch(st: SurfaceTool, points: Array[Vector3], radii: Array[float], sides := 7) -> void:
	for k in range(points.size()-1):
		var axis := (points[k+1]-points[k]).normalized()
		var right := axis.cross(Vector3.FORWARD).normalized()
		if right.length_squared() < .01: right = Vector3.RIGHT
		var up := right.cross(axis).normalized()
		for i in range(sides):
			var a := TAU*float(i)/sides
			var b := TAU*float(i+1)/sides
			var na := right*cos(a)+up*sin(a)
			var nb := right*cos(b)+up*sin(b)
			var v := [points[k]+na*radii[k], points[k+1]+na*radii[k+1], points[k+1]+nb*radii[k+1], points[k]+nb*radii[k]]
			for j in [0,1,2,0,2,3]:
				st.set_normal((na+nb).normalized())
				st.add_vertex(v[j])

static func tree(parent: Node3D, at: Vector3, height: float, random_seed: int, ancient := false, species: int = -1) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	# Keep trunk, fruit sockets and branch positions stable when leaf density changes.
	var leaf_rng := RandomNumberGenerator.new()
	leaf_rng.seed = random_seed+49157
	if species<0: species=0 if ancient else (1 if random_seed%5==1 else (2 if random_seed%5==3 else 0))
	var tree := Node3D.new()
	tree.name = "BranchingTree_%d" % random_seed
	parent.add_child(tree)
	tree.position = at
	tree.set_meta("tree_height",height)
	tree.set_meta("tree_seed",random_seed)
	tree.set_meta("ancient",ancient)
	tree.set_meta("tree_species",["Orchard","SilverBirch","WeepingWillow"][species])
	var h := height
	var radius := h*(.038 if ancient else .023)
	var lean := Vector3(rng.randf_range(-.07,.07),0,rng.randf_range(-.07,.07))*h
	var trunk: Array[Vector3] = [Vector3.ZERO,Vector3(0,h*.25,0)+lean*.18,Vector3(0,h*.48,0)+lean*.5,Vector3(0,h*.70,0)+lean*.85,Vector3(0,h*.90,0)+lean]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	branch(st,trunk,[radius*1.6,radius,radius*.69,radius*.35,.025])
	# Visible roots and asymmetrical forks, not hidden inside spherical shells.
	for i in range(5):
		var a := i*TAU/5.0+rng.randf_range(-.25,.25)
		branch(st,[Vector3(0,h*.075,0),Vector3(cos(a)*radius*3.4,.04,sin(a)*radius*3.4)],[radius*.57,.018])
	var centers: Array[Vector3] = []
	var sizes: Array[Vector3] = []
	var directions: Array[Vector3] = []
	var fruit_positions: Array[Vector3] = []
	var branch_count := 7 if ancient else (6 if species>0 else 5)
	var rotation := rng.randf()*TAU
	for i in range(branch_count):
		var angle := rotation+i*2.399963+rng.randf_range(-.45,.45)
		var level := (.43 if species==1 else .31)+float(i)/branch_count*(.34 if species==1 else .43)+rng.randf_range(-.025,.025)
		var start := Vector3(0,h*level,0)+lean*(level/.9)
		var spread := h*rng.randf_range(.27,.37)*(1.12 if ancient else 1.0)*(1.0-float(i)/branch_count*.22)
		if species==1: spread*=.62
		if species==2: spread*=1.18
		var dir := Vector3(cos(angle),0,sin(angle))
		var end := start+dir*spread+Vector3.UP*h*rng.randf_range(.11,.18)
		var elbow := start.lerp(end,.53)+Vector3.UP*h*(.045 if species==2 else -.035)
		branch(st,[start,elbow,end],[radius*.53,radius*.31,.018])
		for fork in range(2):
			var fangle := angle+(-1.02 if fork==0 else 1.02)+rng.randf_range(-.12,.12)
			var reach := h*rng.randf_range(.105,.16)
			var tip := end+Vector3(cos(fangle)*reach,h*(.055 if fork==0 else .105),sin(fangle)*reach)
			if species==2: tip.y-=h*.19
			branch(st,[elbow.lerp(end,.42),end,tip],[radius*.20,.035,.010],6)
			centers.append(tip+Vector3.UP*h*.012)
			var crown:=Vector3(rng.randf_range(.09,.12),rng.randf_range(.065,.09),rng.randf_range(.10,.14))*h
			if species==1: crown*=Vector3(.73,1.45,.70)
			if species==2: crown*=Vector3(1.0,1.75,.75)
			sizes.append(crown)
			directions.append((tip-end).normalized())
			var side := Vector3(cos(fangle),-.50,sin(fangle)).normalized()
			fruit_positions.append(centers[-1]+side*sizes[-1]*.98)
			if (i+fork)%3==0:
				fruit_positions.append(centers[-1]+Vector3(-sin(fangle),-.62,cos(fangle))*sizes[-1]*.84)
	for k in range(3):
		var a := rotation+TAU*k/3.0
		centers.append(trunk[-1]+Vector3(cos(a)*.07,.025,sin(a)*.07)*h)
		sizes.append(Vector3(.075,.12,.085)*h if species==1 else Vector3(.10,.075,.12)*h)
		directions.append(Vector3(cos(a),.45,sin(a)).normalized())
	var leaf_transforms: Array[Transform3D] = []
	var normals: Array[Vector3] = []
	var shadow_st := SurfaceTool.new()
	shadow_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in range(centers.size()):
		var c := centers[k]
		var crown_size := sizes[k]*Vector3(1.08,1.45,1.05)
		var twig_size := crown_size
		# Give paired branch crowns a shared role, with a smaller secondary fork.
		# Keep authored branch endpoints and fruit sockets, but avoid equal pom-poms.
		var branch_index := k/2 if k<centers.size()-3 else branch_count
		var mass: float = [1.23,.87,1.10,.76,1.04][(branch_index+random_seed)%5]
		if species==0:
			crown_size *= Vector3(mass,lerpf(1.0,mass,.45),mass)
			if k<centers.size()-3 and k%2==1: crown_size*=Vector3(.88,.94,.90)
		var forward := directions[k]
		if species==2: forward=Vector3(forward.x,0,forward.z).normalized()
		var right := forward.cross(Vector3.UP).normalized()
		var up := right.cross(forward).normalized()
		shadow_lobe(shadow_st,c,Basis(right,up,forward),crown_size,float(k))
		branch(st,[c-forward*twig_size.z*.75,c,c+forward*twig_size.z*.5],[.022,.012,.004],5)
		# Rejection sampling sets a minimum distance between leaf sprays.
		# Asymmetric, warped volumes produce the crown; sprites only shape its edge.
		var accepted: Array[Vector3] = []
		var count := roundi(40.0*crown_size.x*crown_size.z)
		if species==1: count=roundi(count*1.7)
		if species==2: count=roundi(count*1.85)
		var spacing := .25*pow(h/6.5,.35)
		for attempt in range(count*15):
			if accepted.size()>=count: break
			var y := leaf_rng.randf_range(-1,1)
			var a := leaf_rng.randf()*TAU
			var d := Vector3(sqrt(1-y*y)*cos(a),y,sqrt(1-y*y)*sin(a))
			var warp := .88+.14*sin(d.x*4.0+k)+.10*cos(d.z*5.0-d.y*3.0)
			# A shallow volume avoids the hollow shell / ring of repeated leaf cards.
			var local := d*crown_size*warp*leaf_rng.randf_range(.91,1.0)
			if species==2: local.y-=crown_size.y*.35*(1.0-absf(d.x))
			# Keep a cut into the silhouette, rather than an unbroken round contour.
			if d.x>.45 and d.z>.40 and d.y<.25: continue
			var offset := right*local.x+up*local.y+forward*local.z
			var crowded := false
			for previous in accepted:
				if offset.distance_squared_to(previous)<spacing*spacing:
					crowded=true
					break
			if crowded: continue
			accepted.append(offset)
			var size := leaf_rng.randf_range(.72,.92)*pow(h/6.5,.35)
			var width:=size*leaf_rng.randf_range(.94,1.08)
			if species==1: size*=.86
			if species==2:
				width*=.65
				size*=1.14
			var basis := Basis.IDENTITY.scaled(Vector3(width,size,1))
			leaf_transforms.append(Transform3D(basis,c+offset))
			# Blend local volume with the entire crown: neighbouring branch clusters
			# share a light side rather than each looking like a separately lit ball.
			var local_normal := (right*d.x+up*d.y+forward*d.z).normalized()
			var crown_normal := ((c+offset-Vector3(lean.x,h*.61,lean.z))/Vector3(h*.38,h*.43,h*.38)).normalized()
			var n := (local_normal*.48+crown_normal*.52+Vector3.UP*.06).normalized()
			normals.append(n)
	var bark := MeshInstance3D.new()
	bark.name = "ForkedTrunk"
	bark.mesh = st.commit()
	bark.material_override = A.material(Color("583d2e") if ancient else Color("573b2c"))
	if species==1:
		var bark_mat:=ShaderMaterial.new()
		bark_mat.shader=BIRCH_BARK
		bark.material_override=bark_mat
	tree.add_child(bark)
	var leaves := MultiMeshInstance3D.new()
	leaves.name = "ClusteredLeaves"
	leaves.multimesh = MultiMesh.new()
	leaves.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	leaves.multimesh.use_custom_data = true
	var leaf := leaf_mesh()
	var mat := ShaderMaterial.new()
	mat.shader = LEAVES
	mat.set_shader_parameter("sprig_geometry",true)
	mat.set_shader_parameter("directional_leaflets",true)
	mat.set_shader_parameter("leaf_mask",load("res://assets/foliage/eduardo/leaf_alpha.png"))
	if species==1:
		mat.set_shader_parameter("leaf_light",Color("aec56e"))
		mat.set_shader_parameter("leaf_mid",Color("668d40"))
		mat.set_shader_parameter("leaf_dark",Color("2e4f2e"))
	if species==2:
		mat.set_shader_parameter("hanging_leaves",true)
		mat.set_shader_parameter("leaf_light",Color("73a35c"))
		mat.set_shader_parameter("leaf_mid",Color("40754d"))
		mat.set_shader_parameter("leaf_dark",Color("21473b"))
	leaf.surface_set_material(0,mat)
	leaves.multimesh.mesh = leaf
	leaves.multimesh.instance_count = leaf_transforms.size()
	for i in range(leaf_transforms.size()):
		var transform := leaf_transforms[i]
		leaves.multimesh.set_instance_transform(i,transform)
		# Store the crown-volume normal independently of the camera-facing alpha card.
		var n := (transform.basis.inverse()*normals[i]).normalized()*.5+Vector3.ONE*.5
		leaves.multimesh.set_instance_custom_data(i,Color(n.x,n.y,n.z,rng.randf()))
	leaves.extra_cull_margin = .65
	leaves.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tree.add_child(leaves)
	var shadow := MeshInstance3D.new()
	shadow.name = "CanopyShadow"
	shadow_st.index()
	shadow.mesh = shadow_st.commit()
	var shadow_material := ShaderMaterial.new()
	shadow_material.shader = CANOPY_SHADOW
	shadow.material_override = shadow_material
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	shadow.extra_cull_margin = .65
	tree.add_child(shadow)
	var decorations:=DECORATIONS.new()
	decorations.name="TreeDecorations"
	decorations.decoration_seed=random_seed
	decorations.fruit_kind=(2 if random_seed%3==1 else 1) if species==0 else 0
	decorations.blossoms=species==0 and random_seed%4==0
	decorations.blossom_color=Color("f2c7d1") if random_seed%8==0 else Color("fff0d2")
	decorations.fruit_sockets=PackedVector3Array(fruit_positions)
	var flower_sockets:=PackedVector3Array()
	for i in range(leaf_transforms.size()):
		if i%11==0 and normals[i].y>.1: flower_sockets.append(leaf_transforms[i].origin+normals[i]*.10)
	decorations.blossom_sockets=flower_sockets
	tree.add_child(decorations)
	decorations.rebuild()
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius*1.2
	shape.height = h*.45
	collision.shape = shape
	collision.position.y = shape.height*.5
	body.add_child(collision)
	tree.add_child(body)
	return tree

static func flowers(parent: Node3D, at: Vector3, random_seed: int, style: int, radius := 1.0, count := 14) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var clump := MultiMeshInstance3D.new()
	clump.name = ["IvoryDaisies","BlueBells","GoldenButtons","RoseClover"][style]+"_%d"%random_seed
	clump.position = at
	clump.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	clump.multimesh = MultiMesh.new()
	clump.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	clump.multimesh.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2(.38,.64) if style==1 else Vector2(.40,.47)
	quad.center_offset.y = quad.size.y*.5
	var mat := ShaderMaterial.new()
	mat.shader = FLOWERS
	mat.set_shader_parameter("flower_kind",style)
	mat.set_shader_parameter("petals",[Color("fff4cd"),Color("a6acf5"),Color("eac858"),Color("eab1ce")][style])
	quad.material = mat
	clump.multimesh.mesh = quad
	clump.multimesh.instance_count = count
	for i in range(count):
		var a := rng.randf()*TAU
		var r := sqrt(rng.randf())*radius
		var pos := Vector3(cos(a)*r,0,sin(a)*r*.68)
		var scale := rng.randf_range(.7,1.15)
		clump.multimesh.set_instance_transform(i,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*scale),pos))
		clump.multimesh.set_instance_custom_data(i,Color(rng.randf(),0,0,1))
	parent.add_child(clump)
