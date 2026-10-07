extends SceneTree
## Replaces only tree visuals; keeps terrain source maps, collisions and hand-placed scenery.
const W = preload("res://scripts/woodland_art.gd")
var map: Node3D

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Vegetation authoring requires a GPU to serialize MultiMesh data.")
		quit(1)
		return
	map = load("res://scenes/reference_map.tscn").instantiate()
	# Keep the map outside SceneTree: _ready() on terrain, ladders and instanced
	# props creates runtime children/material overrides that must not be baked.
	# MultiMesh uploads still use the active GPU RenderingServer below.
	var count := 0
	for old: Node3D in map.find_children("BranchingTree_*","Node3D",true,false):
		var seed_value := int(old.name.get_slice("_",1))
		# The original collider encodes the exact authored height (no bounds estimate).
		var collision: CollisionShape3D = old.find_children("*","CollisionShape3D",true,false)[0]
		var height: float = old.get_meta("tree_height",collision.shape.height/.45)
		var variant: int=["Orchard","SilverBirch","WeepingWillow"].find(old.get_meta("tree_species",""))
		var replacement := W.tree(old.get_parent(),old.position,height,seed_value,seed_value==180,variant)
		var sibling_index := old.get_index()
		if old.has_node("TreeDecorations"):
			var previous:=old.get_node("TreeDecorations")
			var decoration:=replacement.get_node("TreeDecorations")
			decoration.fruit_kind=previous.fruit_kind
			decoration.blossoms=previous.blossoms
			decoration.blossom_color=previous.blossom_color
			decoration.rebuild()
		replacement.transform = old.transform
		var saved_name := old.name
		old.free()
		replacement.name = saved_name
		replacement.get_parent().move_child(replacement,sibling_index)
		replacement.owner = map
		_owners(replacement)
		count += 1
	print("TREES_REBUILT ",count)
	await process_frame
	await RenderingServer.frame_post_draw
	# Retain all non-tree ownership and scene-instance boundaries verbatim.
	var packed := PackedScene.new()
	var err := packed.pack(map)
	if err == OK:
		err = ResourceSaver.save(packed,"res://scenes/reference_map.tscn")
	print("VEGETATION_SAVED ",error_string(err))
	map.free()
	await process_frame
	quit(err)

func _owners(node: Node) -> void:
	for child in node.get_children():
		child.owner = map
		_owners(child)
