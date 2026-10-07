extends Node3D
## Static land navigation supplies intents; CombatActor owns all actual movement.
const MESH_PATH := "res://assets/navigation/garden_navigation.tres"
const REPATH_SECONDS := .20
const TARGET_SHIFT := .65
const END_TOLERANCE := .85
var host: Node
var region: NavigationRegion3D
var last_error := ""
var _agents: Dictionary = {}
var _initial_iteration := 0
var _ready_for_paths := false

func setup(game: Node) -> bool:
	if is_instance_valid(region):
		last_error = "导航已初始化"
		return false
	host = game
	if not is_inside_tree() or not is_instance_valid(host) or not is_instance_valid(host.reference_map):
		last_error = "导航必须在世界地图加入场景后初始化"
		return false
	var mesh := load(MESH_PATH) as NavigationMesh
	if mesh == null or mesh.get_polygon_count() == 0:
		last_error = "缺少已烘焙的地面导航数据"
		return false
	region = NavigationRegion3D.new()
	region.name = "GardenLandNavigation"
	region.navigation_mesh = mesh
	region.transform = global_transform.affine_inverse() * host.reference_map.global_transform
	add_child(region)
	var map_rid := get_world_3d().get_navigation_map()
	_initial_iteration = NavigationServer3D.map_get_iteration_id(map_rid)
	NavigationServer3D.map_set_cell_size(map_rid, mesh.cell_size)
	NavigationServer3D.map_set_cell_height(map_rid, mesh.cell_height)
	return true

func navigation_ready() -> bool:
	if _ready_for_paths: return is_instance_valid(region) and region.is_inside_tree()
	if not is_instance_valid(region) or NavigationServer3D.map_get_iteration_id(region.get_navigation_map()) <= _initial_iteration or NavigationServer3D.region_get_iteration_id(region.get_rid()) == 0: return false
	# Region and map iterations can complete on separate frames. The first map
	# iteration may still represent an empty region while its mesh is building.
	var probe: Vector3 = region.global_transform * region.navigation_mesh.vertices[0]
	_ready_for_paths = NavigationServer3D.map_get_closest_point_owner(region.get_navigation_map(), probe) == region.get_rid()
	return _ready_for_paths

func path_between(from: Vector3, to: Vector3) -> PackedVector3Array:
	if not navigation_ready() or not from.is_finite() or not to.is_finite(): return PackedVector3Array()
	return NavigationServer3D.map_get_path(region.get_navigation_map(), from, to, true)

func is_reachable(from: Vector3, to: Vector3) -> bool:
	var path := path_between(from, to)
	return not path.is_empty() and _near(path[0], from) and _near(path[path.size() - 1], to)

func direction_for(actor: Node3D, destination: Vector3) -> Vector3:
	if not navigation_ready() or not is_instance_valid(actor) or not actor.is_inside_tree() or actor.get_world_3d() != get_world_3d() or not destination.is_finite(): return Vector3.ZERO
	var id := actor.get_instance_id()
	if not _agents.has(id):
		var agent := NavigationAgent3D.new()
		agent.name = "WorldNavigationAgent"
		agent.path_desired_distance = .30
		# Recast's rasterized surface sits above physical feet. Match path height
		# to the actor origin so a horizontal walker can reach each 3D waypoint.
		agent.path_height_offset = region.navigation_mesh.cell_height * 2.0
		agent.target_desired_distance = .45
		agent.path_max_distance = 1.5
		agent.avoidance_enabled = false
		actor.add_child(agent)
		agent.set_navigation_map(region.get_navigation_map())
		_agents[id] = {"actor": weakref(actor), "agent": weakref(agent), "destination": Vector3.INF, "repath_at": 0.0, "frame": -1, "direction": Vector3.ZERO}
	var entry: Dictionary = _agents[id]
	var agent: NavigationAgent3D = entry.agent.get_ref()
	if not is_instance_valid(agent):
		_agents.erase(id)
		return Vector3.ZERO
	var frame := Engine.get_physics_frames()
	if entry.frame == frame: return entry.direction
	entry.frame = frame
	entry.direction = Vector3.ZERO
	var now := float(frame) / float(Engine.physics_ticks_per_second)
	var displaced_after_arrival := agent.is_navigation_finished() and not _near(actor.global_position, destination)
	if now >= entry.repath_at and (not entry.destination.is_finite() or entry.destination.distance_to(destination) >= TARGET_SHIFT or displaced_after_arrival):
		agent.target_position = destination
		entry.destination = destination
		entry.repath_at = now + REPATH_SECONDS
	if agent.is_navigation_finished(): return Vector3.ZERO
	var next := agent.get_next_path_position()
	# A partial path must not pull a unit into a wall, lake or disconnected roof.
	if not _near(agent.get_final_position(), destination) or not _near(NavigationServer3D.map_get_closest_point(region.get_navigation_map(), actor.global_position), actor.global_position): return Vector3.ZERO
	var offset := next - actor.global_position
	offset.y = 0
	if offset.length_squared() > .0025: entry.direction = offset.normalized()
	return entry.direction

func forget(actor: Node) -> void:
	if not is_instance_valid(actor): return
	var entry: Dictionary = _agents.get(actor.get_instance_id(), {})
	if entry.is_empty(): return
	var agent: Node = entry.agent.get_ref()
	if is_instance_valid(agent): agent.queue_free()
	_agents.erase(actor.get_instance_id())

func _near(a: Vector3, b: Vector3) -> bool:
	return Vector2(a.x - b.x, a.z - b.z).length() <= END_TOLERANCE and absf(a.y - b.y) <= .9

func _process(_delta: float) -> void:
	for id in _agents.keys():
		var actor: Node = _agents[id].actor.get_ref()
		if not is_instance_valid(actor):
			_agents.erase(id)
		elif not actor.is_inside_tree():
			forget(actor)

func _exit_tree() -> void:
	for entry in _agents.values():
		var agent: Node = entry.agent.get_ref()
		if is_instance_valid(agent) and not agent.is_queued_for_deletion(): agent.queue_free()
	_agents.clear()
