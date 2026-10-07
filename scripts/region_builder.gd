extends RefCounted
## Authoring only: bakes the eastern woodland and northern hamlet into the scene.
const A = preload("res://scripts/reference_art.gd")
const W = preload("res://scripts/woodland_art.gd")
const L = preload("res://scripts/world_layout.gd")
const Roads = preload("res://scripts/road_art.gd")

static func group(parent: Node,name: String) -> Node3D:
	var node := Node3D.new()
	node.name=name
	parent.add_child(node)
	return node

static func ribbon(parent: Node, points: Array, width: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var smooth: Array[Vector2]=[]
	for segment in range(points.size()-1):
		var a: Vector2=points[segment]
		var b: Vector2=points[segment+1]
		var before: Vector2=points[maxi(0,segment-1)]
		var after: Vector2=points[mini(points.size()-1,segment+2)]
		var count := ceili(a.distance_to(b)*2)
		for i in range(count): smooth.append(a.cubic_interpolate(b,before,after,float(i)/count))
	smooth.append(points[-1])
	var distance := 0.0
	for i in range(smooth.size()-1):
		var p := smooth[i]
		var q := smooth[i+1]
		var next_distance := distance + p.distance_to(q)
		if L.ground(p.x,p.y)<1.5 or L.ground(q.x,q.y)<1.5:
			distance = next_distance
			continue
		var side_p := (q-smooth[maxi(i-1,0)]).normalized().orthogonal()
		var side_q := (smooth[mini(i+2,smooth.size()-1)]-p).normalized().orthogonal()
		var wp := width*.5+sin(p.x*1.8+p.y)*.10
		var wq := width*.5+sin(q.x*1.8+q.y)*.10
		var corners := [p+side_p*wp,q+side_q*wq,q-side_q*wq,p-side_p*wp]
		var uv := [Vector2(0,distance),Vector2(0,next_distance),Vector2(1,next_distance),Vector2(1,distance)]
		for j in [0,1,2,0,2,3]:
			var v: Vector2=corners[j]
			st.set_normal(Vector3.UP)
			st.set_uv(uv[j])
			st.add_vertex(Vector3(v.x,maxf(2.2,L.ground(v.x,v.y))+.026,v.y))
		distance = next_distance
	var node := MeshInstance3D.new()
	node.name="WindingPath"
	node.mesh=st.commit()
	node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.material_override=Roads.material()
	node.set_meta(&"footstep_surface", &"dirt")
	parent.add_child(node)

static func bridge(parent: Node, start: Vector2, end: Vector2, width: float, label: String) -> void:
	var bridge := group(parent,label)
	var delta := end-start
	var length := delta.length()
	var middle := (start+end)*.5
	bridge.position=Vector3(middle.x,0,middle.y)
	bridge.rotation.y=atan2(delta.x,delta.y)
	var wood := A.material(Color("a18961"))
	var edge := A.material(Color("6c6650"))
	var gold := A.material(Color("baa57b"))
	var deck := A.block(bridge,Vector3(0,2.13,0),Vector3(width,.14,length+.2),wood)
	deck.name="ContinuousWalkableDeck"
	for i in range(ceili(length/.38)):
		var z := -length*.5+i*.38
		A.block(bridge,Vector3(0,2.205,z),Vector3(width,.035,.34),gold if i%5==0 else wood,false)
	for x in [-width*.5,width*.5]:
		# Tall enough for the camera to read, low enough to keep the route visible.
		A.block(bridge,Vector3(x,2.85,0),Vector3(.11,.12,length),edge,false)
		A.block(bridge,Vector3(x,2.46,0),Vector3(.08,.07,length),wood,false)
		for i in range(ceili(length/1.65)+1):
			var z := clampf(-length*.5+i*1.65,-length*.5,length*.5)
			A.block(bridge,Vector3(x,2.43,z),Vector3(.16,1.06,.16),wood,false)
		for z in [-length*.36,length*.36]:
			A.block(bridge,Vector3(x,1.05,z),Vector3(.28,2.0,.34),edge,false)

static func build(map: Node3D) -> void:
	var roads := group(map,"RegionConnections")
	bridge(roads,Vector2(10.8,1.7),Vector2(25,1.7),3.1,"EastWoodenBridge")
	bridge(roads,Vector2(0,-8.8),Vector2(0,-25.1),3.1,"NorthVillageBridge")
	ribbon(roads,L.EAST_ROAD,2.1)
	ribbon(roads,L.NORTH_ROAD,2.6)
	ribbon(roads,L.WOODLAND_ROAD,1.8)
	forest(map)
	village(map)
	map.add_child(Roads.flagstones())
	var flowers := group(map,"GardenWildflowers")
	var placements := [Vector2(-5,5),Vector2(-8,3),Vector2(-2,6.6),Vector2(6,4.5),Vector2(8,1.7),Vector2(-11,-1),Vector2(8,-7.2)]
	for i in range(placements.size()):
		var p: Vector2=placements[i]
		W.flowers(flowers,Vector3(p.x,L.ground(p.x,p.y),p.y),400+i,i%4,.85,15)

static func forest(map: Node3D) -> void:
	var forest := group(map,"EasternForest")
	var trees := group(forest,"Trees")
	var rng := RandomNumberGenerator.new()
	rng.seed=926
	var positions: Array[Vector2]=[]
	# Break up a regular lattice; preserve the winding trail and a central clearing.
	for row in range(8):
		for column in range(9):
			var p := Vector2(19+column*5.25+rng.randf_range(-1.7,1.7),-20+row*5.3+rng.randf_range(-1.7,1.7))
			if L.ground(p.x,p.y)<2 or L.road_distance(p.x,p.y)<3.4: continue
			if Vector2((p.x-42)/6.0,(p.y-5)/4.5).length()<1: continue
			if Vector2((p.x-40)/24.0,(p.y+2)/21.0).length()>1: continue
			positions.append(p)
			W.tree(trees,Vector3(p.x,L.ground(p.x,p.y),p.y),rng.randf_range(5.3,8.2),1000+row*9+column)
	# A few saplings soften the entrance and foreground without hiding the path.
	for p in [Vector2(24,6.5),Vector2(26,-3.5),Vector2(35,9),Vector2(53,8),Vector2(23,-22)]:
		W.tree(trees,Vector3(p.x,L.ground(p.x,p.y),p.y),rng.randf_range(3.6,4.3),1200+trees.get_child_count())
	var understory := group(forest,"FernsFlowersAndRocks")
	for i in range(110):
		var p := Vector2(rng.randf_range(18,63),rng.randf_range(-21,17))
		if L.ground(p.x,p.y)<2 or L.road_distance(p.x,p.y)<2.1: continue
		var at := Vector3(p.x,L.ground(p.x,p.y),p.y)
		if i%5==0:
			A.model(understory,"res://assets/nature/Rock_Medium_%d.gltf"%[1+i%3],at-Vector3.UP*.15,rng.randf_range(.45,1.2),rng.randf()*TAU,Color("899b86"),true)
		elif i%3==0:
			W.flowers(understory,at,1500+i,i%4,rng.randf_range(.6,1.15),rng.randi_range(8,18))
		else:
			A.model(understory,"res://assets/nature/Fern_1.gltf",at,rng.randf_range(.32,.65),rng.randf()*TAU)
	# A quiet meeting point in the forest clearing.
	var clearing := group(forest,"Clearing")
	A.model(clearing,"res://assets/ruins/Column_Round_Short.fbx",Vector3(42,2.2,5),1.9,.4,Color("a9bca4"),true)
	A.model(clearing,"res://assets/nature/Rock_Medium_2.gltf",Vector3(44,2.2,6.2),1.4,.7,Color("8fa28e"),true)
	W.flowers(clearing,Vector3(40,2.2,6.2),1901,0,1.2,24)
	W.flowers(clearing,Vector3(43.5,2.2,3.4),1902,1,.9,16)
	print("FOREST_TREES ",trees.get_child_count())

static func village(map: Node3D) -> void:
	var village := group(map,"NorthernVillage")
	var buildings := group(village,"Buildings")
	# Heights in metres; keep room for the player between buildings and central square.
	A.village_model(buildings,"House_2",Vector3(-10,2.2,-31.5),6.2,-.18,Color("487c77"))
	A.village_model(buildings,"House_3",Vector3(9.8,2.2,-31.5),6.0,.2,Color("b67b57"))
	A.village_model(buildings,"House_3",Vector3(-12,2.2,-43),7.0,.28,Color("66845e"))
	A.village_model(buildings,"House_2",Vector3(12,2.2,-48),6.7,-.28,Color("587e8a"))
	A.village_model(buildings,"Inn",Vector3(-6,2.2,-54),8.0,.12,Color("a9604e"))
	A.village_model(buildings,"Blacksmith",Vector3(16,2.2,-39),5.3,-PI*.5,Color("657f83"))
	A.village_model(buildings,"Bell_Tower",Vector3(3.7,2.2,-53),9.8,0,Color("668a78"))
	var lanes := group(village,"DoorstepLanes")
	for route in [[Vector2(-1,-29),Vector2(-5,-28),Vector2(-10,-28)],[Vector2(0,-32),Vector2(5,-28),Vector2(9.8,-28)],[Vector2(-4,-40),Vector2(-8,-40),Vector2(-12,-39.5)],[Vector2(4,-42),Vector2(8,-44),Vector2(12,-44.5)],[Vector2(2,-49),Vector2(-2,-49),Vector2(-6,-49.5)],[Vector2(5,-38),Vector2(10,-37),Vector2(13,-38)]]:
		ribbon(lanes,route,1.2)
	var plaza := group(village,"MarketSquare")
	var paving := Roads.material(true)
	var ground := A.cylinder(plaza,Vector3(0,2.23,-40),6.3,.045,paving,false)
	ground.set_meta(&"footstep_surface", &"dirt")
	ground.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Grouped cobbles give the square scale, without a noisy full checkerboard.
	for i in range(24):
		var a := i*TAU/24
		var slab := A.block(plaza,Vector3(sin(a)*5.8,2.27,-40+cos(a)*5.8),Vector3(.64,.065,.9),A.material(Color("bac0a7")),false)
		slab.rotation.y=a
	A.village_model(plaza,"Well",Vector3(-2,2.27,-41),2.45,0,Color("a27956"))
	A.village_model(plaza,"Market_Stand",Vector3(3.7,2.27,-42.5),2.7,.15,Color("bd805c"))
	A.village_model(plaza,"Market_Stand_2",Vector3(-4.3,2.27,-37.4),2.4,-.25,Color("7f99b1"))
	A.village_model(plaza,"Bench",Vector3(2.5,2.27,-36),.65,PI*.5)
	var props := group(village,"Yards")
	A.village_model(props,"Cart",Vector3(13,2.2,-34.5),1.8,-.6)
	for p in [Vector2(5.8,-43),Vector2(6.5,-42),Vector2(-6,-37),Vector2(13,-41),Vector2(-13,-29)]:
		A.village_model(props,"Barrel",Vector3(p.x,2.2,p.y),.8,p.x)
	for p in [Vector2(6,-40),Vector2(-7,-36),Vector2(13,-42)]:
		A.village_model(props,"Crate",Vector3(p.x,2.2,p.y),.64,p.y)
	A.village_model(props,"Bags",Vector3(4.8,2.2,-43),.7,0)
	A.village_model(props,"Hay",Vector3(16,2.2,-43),.9,.2)
	# Fenced vegetable garden with a real opening towards the square.
	for x in range(-17,-8,2):
		A.village_model(props,"Fence",Vector3(x,2.2,-36.3),.8,0)
	for z in [-34.5,-32.5]:
		A.village_model(props,"Fence",Vector3(-17.5,2.2,z),.8,PI*.5)
	for z in range(3):
		A.block(props,Vector3(-14,2.23,-35+z*.75),Vector3(4,.035,.43),A.material(Color("806f4c")),false)
		for x in range(9):
			A.model(props,"res://assets/nature/Fern_1.gltf",Vector3(-15.8+x*.45,2.25,-35+z*.75),.24+z*.05,x*.8)
	var greenery := group(village,"VillageGardens")
	var tree_spots := [Vector2(-17,-26),Vector2(15,-26),Vector2(-18,-47),Vector2(19,-53),Vector2(-14,-56),Vector2(8,-59),Vector2(20,-32),Vector2(-8,-22)]
	for i in range(tree_spots.size()):
		var p: Vector2=tree_spots[i]
		if L.ground(p.x,p.y)>1:
			W.tree(greenery,Vector3(p.x,L.ground(p.x,p.y),p.y),4.6+(i%3)*.6,2000+i)
	for i in range(18):
		var a := i*2.399963
		var p := Vector2(cos(a)*8,-40+sin(a)*8)
		if L.road_distance(p.x,p.y)<2.4:continue
		W.flowers(greenery,Vector3(p.x,2.2,p.y),2300+i,i%4,.65,12)
	for p in [Vector2(-7,-28),Vector2(7,-29),Vector2(-8,-47),Vector2(7,-50)]:
		W.flowers(greenery,Vector3(p.x,2.2,p.y),2400+greenery.get_child_count(),3,1.2,24)
	print("VILLAGE_BUILDINGS ",buildings.get_child_count())
