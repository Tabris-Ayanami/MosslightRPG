extends SceneTree
var failures:=0
var checks:=0
var game: Node
func _initialize(): call_deferred("run")
func check(ok: bool,label: String):
	checks+=1
	if not ok: failures+=1
	print("PASS " if ok else "FAIL ",label)
func ticks(n):
	for i in range(n): await process_frame
func run():
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(25)
	var species: Dictionary={}
	var fruit_counts: Dictionary={"Apples":0,"Pears":0,"Blossoms":0}
	var sample: Node3D
	for tree in game.reference_map.find_children("BranchingTree_*","Node3D",true,false):
		var kind: String=tree.get_meta("tree_species","")
		species[kind]=species.get(kind,0)+1
		var deco: Node3D=tree.get_node("TreeDecorations")
		for name in fruit_counts:
			if deco.has_node(name): fruit_counts[name]+=1
		if kind=="Orchard": sample=tree
	print("SPECIES ",species," DECORATED_TREES ",fruit_counts)
	check(species.get("SilverBirch",0)>=8 and species.get("WeepingWillow",0)>=8,"two additional tree silhouettes are distributed through the map")
	check(fruit_counts.Apples>0 and fruit_counts.Pears>0 and fruit_counts.Blossoms>0,"apples, pears and blossoms reload as separate geometry")
	var leaves: MultiMesh=sample.get_node("ClusteredLeaves").multimesh
	var bark: Mesh=sample.get_node("ForkedTrunk").mesh
	var deco: Node3D=sample.get_node("TreeDecorations")
	deco.fruit_kind=2
	deco.blossoms=true
	await ticks(3)
	check(deco.has_node("Pears") and not deco.has_node("Apples") and deco.has_node("Blossoms"),"fruit type switches without removing independently enabled flowers")
	deco.fruit_kind=0
	await ticks(3)
	check(not deco.has_node("Pears") and deco.has_node("Blossoms"),"fruit can be hidden independently of blossoms")
	deco.blossoms=false
	await ticks(3)
	check(deco.get_child_count()==0 and sample.get_node("ClusteredLeaves").multimesh==leaves and sample.get_node("ForkedTrunk").mesh==bark,"removing all decorations preserves the tree crown and trunk")
	var world: World3D=game.viewport.find_world_3d()
	var bank_samples:=0
	var slopes:=0
	for line in [Vector3(-18,0,4),Vector3(63,0,8),Vector3(-25,0,-42)]:
		for i in range(7):
			var p: Vector3=game.GARDEN_ORIGIN+line+Vector3(i*.65,0,0)
			var query:=PhysicsRayQueryParameters3D.create(p+Vector3.UP*20,p-Vector3.UP*10,256)
			var hit:=world.direct_space_state.intersect_ray(query)
			if not hit.is_empty() and hit.position.y>.0 and hit.position.y<2.1:
				bank_samples+=1
				if hit.normal.y>.50: slopes+=1
	check(bank_samples>=3 and slopes==bank_samples,"visible shoreline transitions have sloped collision surfaces")
	check(game.reference_map.has_node("LakeBed") and game.reference_map.has_node("SubmergedPebbles"),"clear water has a real bed and submerged detail")
	print("ENVIRONMENT_RESULT ",checks-failures,"/",checks)
	game.queue_free()
	await ticks(2)
	quit(1 if failures else 0)
