extends SceneTree
## Physics and load checks for the water garden after removing the prototype map.
var game: Node
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func move_in_world(direction: Vector3, frames: int) -> void:
	var horizontal: float = direction.dot(game.camera_right())
	var vertical: float = direction.dot(game.camera_forward())
	Input.action_press("move_right" if horizontal >= 0 else "move_left", absf(horizontal))
	Input.action_press("move_up" if vertical >= 0 else "move_down", absf(vertical))
	await ticks(frames)
	game._release_actions()
	await ticks(8)

func tap_key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await ticks(2)
	event.pressed = false
	Input.parse_input_event(event)
	await ticks(16)

func _run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(18)
	var player: CharacterBody3D = game.player
	var terrain: MarchingSquaresTerrain = game.reference_map.get_node("SculptableTerrain")
	check(not game.hud.visible, "all HUD, prompts, damage text and cursor overlays are hidden")
	check(player.global_position.z > 100, "default spawn is in the water garden")
	check(not game.world.has_node("OldGarden") and not ResourceLoader.exists("res://scenes/world.tscn"), "old map is absent from disk and the running world")
	check(get_nodes_in_group("enemies").is_empty() and get_nodes_in_group("interactables").is_empty(), "no old-map encounters or props remain active")
	check(terrain.chunks.size() == 16, "sixteen editable terrain chunks cover the garden, forest and village")
	var geometry_loaded := true
	var grass_loaded := true
	for chunk: MarchingSquaresTerrainChunk in terrain.chunks.values():
		geometry_loaded = geometry_loaded and chunk.height_map.size() == 33 and chunk.mesh != null
		grass_loaded = grass_loaded and chunk.grass_planter != null and chunk.grass_planter.multimesh.instance_count > 0
	check(geometry_loaded, "height maps and baked terrain meshes reload")
	check(grass_loaded, "paintable grass MultiMeshes reload")
	var leaf_nodes: Array[Node] = game.reference_map.get_node("AncientTrees").find_children("ClusteredLeaves", "MultiMeshInstance3D", true, false)
	check(leaf_nodes.size() == 5, "all five garden trees use branching trunks and open leaf clusters")
	var leaves_loaded := true
	for leaves: MultiMeshInstance3D in leaf_nodes:
		leaves_loaded = leaves_loaded and leaves.multimesh.instance_count > 0 and leaves.multimesh.use_custom_data and leaves.multimesh.mesh is ArrayMesh
		var leaf_material: ShaderMaterial = leaves.multimesh.mesh.surface_get_material(0)
		leaves_loaded = leaves_loaded and leaf_material.get_shader_parameter("leaf_mask") is Texture2D
		var decorations: Node3D=leaves.get_parent().get_node("TreeDecorations")
		if decorations.fruit_kind!=0:
			var fruit: MultiMeshInstance3D=decorations.get_node("Pears" if decorations.fruit_kind==2 else "Apples")
			leaves_loaded=leaves_loaded and fruit.multimesh.instance_count>0 and fruit.multimesh.mesh!=null
	check(leaves_loaded, "alpha leaf masks, crown normals and independent fruit instances survive scene serialization")
	terrain.pixel_materials = false
	check(terrain.terrain_material.shader.resource_path.ends_with("mst_terrain.gdshader"), "editor switch restores the plugin's full texture material")
	terrain.pixel_materials = true
	check(terrain.terrain_material.shader.resource_path.ends_with("reference_terrain.gdshader"), "pixel material can be restored without replacing terrain data")
	check(player.is_on_floor() and absf(player.global_position.y - 2.2) < .12, "player settles on the raised garden terrain")
	check(game.reflection_viewport.find_world_3d() == game.viewport.find_world_3d(), "reflection uses the same physical world")
	check(game.garden_sun.visible and game.world.find_children("*", "DirectionalLight3D").size() == 1, "garden has only one directional light")
	check(game.nearest_interactable() == null, "old-map interaction targets do not leak across regions")
	# World-forward movement up the lower half of the stone staircase.
	player.restore(game.GARDEN_ORIGIN + Vector3(5.4, 2.5, -.1))
	await ticks(10)
	var start_y := player.global_position.y
	await move_in_world(Vector3(0, 0, -1), 42)
	check(player.global_position.y > start_y + .6, "player can walk up the tree terrace stairs")
	check(player.is_on_floor(), "stairs retain a continuous walkable collision surface")
	player.restore(game.GARDEN_ORIGIN + Vector3(2.5, 2.3, 7.5))
	await ticks(10)
	await move_in_world(Vector3(0, 0, 1), 24)
	check(player.global_position.z > 119.0 and player.global_position.y < 1.8, "shore stairs descend without a blocking rock or cliff")
	var location := player.global_position
	await tap_key(KEY_F3)
	await tap_key(KEY_F4)
	check(player.global_position.distance_to(location) < .25 and not InputMap.has_action("old_map"), "removed F3/F4 shortcuts cannot teleport to the deleted map")
	player.global_position = game.GARDEN_ORIGIN + Vector3(24, -1, 0)
	await ticks(12)
	check(player.global_position.distance_to(game.checkpoint) < .5, "falling into deep water returns to shore")
	check(not game.hud.visible, "respawn does not re-enable interface text")
	print("REFERENCE_TEST_RESULT %d/%d passed" % [checks - failures.size(), checks])
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
