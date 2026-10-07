extends RefCounted
const Art = preload("res://scripts/art.gd")
const Place = preload("res://rpg/rest_place.gd")
const ROOM := Vector3(-300,2.2,70)
const DOOR := Vector3(-6,2.25,60.7)

static func place(parent: Node3D, id: String, label: String, kind: String, at: Vector3) -> Node3D:
	var node := Place.new()
	node.name = id
	node.persistent_id = id
	node.display_name = label
	node.rest_kind = kind
	parent.add_child(node)
	node.global_position = at
	return node

static func build(game: Node) -> Dictionary:
	var root := Node3D.new()
	root.name = "RestPlaces"
	game.world.add_child(root)
	var entrance := place(root,"rest.inn.door","风铃旅馆","inn",DOOR)
	Art.box(entrance,Vector3(-.75,.7,0),Vector3(.12,1.4,.12),Color("69533d"))
	Art.box(entrance,Vector3(-.75,1.28,0),Vector3(1.0,.5,.13),Color("b79762"))
	# Bed pictogram on the doorway sign, legible without adding a wall of text.
	Art.box(entrance,Vector3(-.75,1.23,.08),Vector3(.62,.10,.05),Color("fff0cd"))
	Art.box(entrance,Vector3(-.97,1.31,.08),Vector3(.13,.14,.05),Color("fff0cd"))
	for x in [-1.02,-.48]: Art.box(entrance,Vector3(x,1.16,.08),Vector3(.05,.18,.05),Color("fff0cd"))
	var room := Node3D.new()
	room.name = "WindbellInnRoom"
	root.add_child(room)
	room.position = ROOM
	var backdrop: MeshInstance3D = Art.box(room,Vector3(0,-.45,0),Vector3(100,.15,100),Color("25332e"))
	var backdrop_material := StandardMaterial3D.new()
	backdrop_material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	backdrop_material.albedo_color=Color("25332e")
	backdrop.material_override=backdrop_material
	backdrop.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	Art.solid_box(room,Vector3(0,-.15,0),Vector3(10,.30,9),Color("b39871"))
	for i in range(20): Art.box(room,Vector3(-4.8+i*.5,.012,0),Vector3(.025,.015,9),Color("947a58"))
	for item in [[Vector3(0,1.5,-4.5),Vector3(10,3,.25)],[Vector3(-5,1.5,0),Vector3(.25,3,9)],[Vector3(5,1.5,0),Vector3(.25,3,9)],[Vector3(0,1.5,4.5),Vector3(10,3,.25)]]:
		Art.solid_box(room,item[0],item[1],Color("b9a785"),false)
		var height: float = 2.8 if item[0].x<0 or item[0].z<0 else .48
		Art.box(room,Vector3(item[0].x,height*.5,item[0].z),Vector3(item[1].x,height,item[1].z),Color("d5c6a6"))
	Art.solid_box(room,Vector3(0,3.35,0),Vector3(10,.2,9),Color.WHITE,false)
	for x in [-4.8,0,4.8]: Art.box(room,Vector3(x,2.9,-4.3),Vector3(.18,.18,.18),Color("71573e"))
	var bed := place(room,"rest.inn.bed","温暖的客床","bed",ROOM+Vector3(-3,0,-1.7))
	Art.solid_box(bed,Vector3(0,.3,0),Vector3(1.7,.6,2.8),Color("7c6146"))
	Art.box(bed,Vector3(0,.66,0),Vector3(1.65,.22,2.6),Color("eee3cd"))
	Art.box(bed,Vector3(0,.80,.38),Vector3(1.67,.10,1.7),Color("79968a"))
	Art.box(bed,Vector3(0,.84,-.93),Vector3(1.1,.22,.55),Color("fff2d5"))
	Art.box(bed,Vector3(0,.9,-1.4),Vector3(1.85,1.25,.13),Color("856649"))
	var exit_door := place(room,"rest.inn.exit","客房门","exit",ROOM+Vector3(0,0,3.7))
	Art.box(exit_door,Vector3(0,.04,0),Vector3(1.65,.06,.7),Color("657f73"))
	Art.solid_box(room,Vector3(3,.6,-2.8),Vector3(2.2,1.2,.8),Color("826749"))
	Art.box(room,Vector3(0,.025,-.1),Vector3(3.3,.025,3.6),Color("ba7e63"))
	Art.box(room,Vector3(1.6,1.7,-4.34),Vector3(1.3,1.2,.06),Color("809daf"))
	for x in [.9,2.3]: Art.box(room,Vector3(x,1.7,-4.28),Vector3(.1,1.5,.1),Color("766047"))
	var lamp := OmniLight3D.new()
	lamp.position=Vector3(1.3,2.3,0)
	lamp.light_color=Color("ffe0a5")
	lamp.light_energy=2.2
	lamp.omni_range=10
	room.add_child(lamp)
	var trees: Array[Node3D] = []
	var available: Array[Node] = game.reference_map.find_children("BranchingTree_*","Node3D",true,false)
	available.sort_custom(func(a: Node3D,b: Node3D) -> bool: return a.global_position.distance_to(game.GARDEN_ORIGIN+Vector3(25,2.2,0))<b.global_position.distance_to(game.GARDEN_ORIGIN+Vector3(25,2.2,0)))
	for tree: Node3D in available:
		if tree.global_position.x<23 or float(tree.get_meta("tree_height",0))<6.0: continue
		var near := false
		for previous in trees:
			if previous.global_position.distance_to(tree.global_position)<10: near=true
		if near: continue
		var stop := place(root,"rest.tree.%d"%trees.size(),"老树 · 可倚靠休息","tree",tree.global_position+Vector3(.7,0,.65))
		Art.box(stop,Vector3(0,.025,0),Vector3(.72,.04,.85),Color("a79f7a"))
		trees.append(stop)
		if trees.size()>=3: break
	room.hide()
	return {"root":root,"room":room,"door":entrance,"bed":bed,"exit":exit_door,"trees":trees}
