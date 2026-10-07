extends SceneTree
## Real static map and capsules; no App, preferences, inventory or saves are used.
const Navigation = preload("res://rpg/world_navigation.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
const ORIGIN := Vector3(0, 0, 110)
var checks := 0
var failures: Array[String] = []

class Host extends Node3D:
	var reference_map: Node3D
	var world_navigation: Node
	var paused := false
	var camera_dragging := false
	var ui_pointer_blocked := false

class Walker extends CharacterBody3D:
	var navigation: Node
	var destination := Vector3.ZERO
	var active := false
	var trace: Array[Vector3] = []
	func _ready() -> void:
		collision_layer = 2
		collision_mask = 1
		floor_snap_length = .35
		floor_max_angle = deg_to_rad(65)
		var collider := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = .525
		capsule.height = 1.95
		collider.shape = capsule
		collider.position.y = .975
		add_child(collider)
	func _physics_process(delta: float) -> void:
		if not active: return
		var direction: Vector3 = navigation.direction_for(self, destination)
		velocity.x = direction.x * 5.2
		velocity.z = direction.z * 5.2
		if not is_on_floor(): velocity.y -= 22 * delta
		move_and_slide()
		trace.append(global_position)

func _initialize() -> void:
	Preferences.settings_path = OS.get_environment("TEMP").path_join("mosslight_navigation_%d.cfg" % OS.get_process_id())
	for action in ["attack_primary", "attack_secondary"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func at(local: Vector3) -> Vector3:
	return local + ORIGIN

func _path_length(path: PackedVector3Array) -> float:
	var result := 0.0
	for i in range(1, path.size()): result += path[i].distance_to(path[i - 1])
	return result

func walk(nav: Node, walker: Walker, start: Vector3, destination: Vector3, label: String) -> void:
	walker.active = false
	nav.forget(walker)
	await physics_frame
	walker.global_position = at(start)
	walker.destination = at(destination)
	walker.velocity = Vector3.ZERO
	walker.trace.clear()
	walker.active = true
	for frame in range(420):
		await physics_frame
		var flat := walker.global_position - walker.destination
		flat.y = 0
		if flat.length() < .65: break
	walker.active = false
	var remaining := walker.global_position - walker.destination
	remaining.y = 0
	verify(remaining.length() < .75, label + " capsule reaches destination (remaining %.2fm)" % remaining.length())
	var grounded := true
	for point in walker.trace:
		if point.y < 1.1: grounded = false
	verify(grounded, label + " never falls or swims under the bridge")

func run() -> void:
	var host := Host.new()
	root.add_child(host)
	host.reference_map = load("res://scenes/reference_map.tscn").instantiate()
	host.reference_map.position = ORIGIN
	host.add_child(host.reference_map)
	await host.reference_map.get_node("SculptableTerrain").load_finished
	await physics_frame
	var nav := Navigation.new()
	host.add_child(nav)
	host.world_navigation = nav
	verify(nav.setup(host), "prebaked navigation loads on real translated map")
	var publish_deadline := Time.get_ticks_msec() + 5000
	while not nav.navigation_ready() and Time.get_ticks_msec() < publish_deadline:
		await physics_frame
	verify(nav.navigation_ready(), "server map synchronizes before path queries")
	verify(nav.region.navigation_mesh.get_polygon_count() > 100, "real collision bake contains navigation polygons")
	verify(nav.region.global_position == ORIGIN, "region respects WaterGarden world transform")
	var routes := [
		{"name": "village house", "from": Vector3(-10, 2.25, -27), "to": Vector3(-10, 2.25, -36), "detour": true},
		{"name": "market well", "from": Vector3(-5, 2.25, -41), "to": Vector3(1, 2.25, -41), "detour": true},
		{"name": "east bridge", "from": Vector3(11, 2.25, 1.7), "to": Vector3(25, 2.25, 1.7), "detour": false},
		{"name": "north bridge", "from": Vector3(0, 2.25, -9), "to": Vector3(0, 2.25, -26), "detour": false}
	]
	for route in routes:
		var path: PackedVector3Array = nav.path_between(at(route.from), at(route.to))
		verify(nav.is_reachable(at(route.from), at(route.to)), route.name + " endpoints are connected")
		verify(path.size() >= 2, route.name + " has usable path")
		if route.detour:
			verify(_path_length(path) > route.from.distance_to(route.to) + .3, route.name + " path goes around actual collider")
		else:
			var on_bridge := true
			for point in path:
				if point.y < 1.2: on_bridge = false
			verify(on_bridge, route.name + " path stays on deck rather than lake bed")
	verify(not nav.is_reachable(at(Vector3(0, 2.25, -40)), at(Vector3(-10, 6, -31.5))), "disconnected roof is not reachable from ground")
	verify(not nav.is_reachable(at(Vector3(1.6, 2.25, 4.8)), at(Vector3(-25, .6, 10))), "open lake is excluded from land navigation")
	verify(nav.path_between(Vector3.INF, Vector3.ZERO).is_empty(), "non-finite inputs rejected")
	var walker := Walker.new()
	walker.navigation = nav
	host.add_child(walker)
	for route in routes:
		await walk(nav, walker, route.from, route.to, route.name)
	nav.forget(walker)
	await physics_frame
	walker.global_position = at(Vector3(0, 2.25, -40))
	var before := walker.global_position
	verify(nav.direction_for(walker, at(Vector3(-10, 6, -31.5))) == Vector3.ZERO, "unreachable destination produces no wall-chasing intent")
	verify(walker.global_position == before, "navigation service never moves an actor itself")
	await physics_frame
	var direction: Vector3 = nav.direction_for(walker, at(Vector3(4, 2.25, -40)))
	verify(nav.direction_for(walker, at(Vector3(4, 2.25, -40))) == direction, "same physics frame does not advance the path twice")
	verify(direction.y == 0, "navigation yields horizontal intent only")
	for frame in range(15): await physics_frame
	verify(nav.direction_for(walker, at(Vector3(4, 2.25, -40))).length() > .9, "valid destination recovers after unreachable request")
	var agent_id: int = walker.get_instance_id()
	walker.queue_free()
	await process_frame
	await process_frame
	verify(not nav._agents.has(agent_id), "freed units release navigation bookkeeping")
	# Actual unified AI and movement, not a replacement navigation controller.
	var arena := preload("res://combat/combat_world.gd").new()
	arena.host = host
	arena.actor_parent = host
	host.add_child(arena)
	var owner := preload("res://combat/combat_actor.gd").new()
	owner.is_player = true
	owner.arena = arena
	owner.visual_script = preload("res://combat/animation_controller.gd")
	owner.position = at(Vector3(8, 2.25, -40))
	host.add_child(owner)
	arena.player = owner
	owner.set_control_mode("none")
	owner.faction_id = "hostiles"
	var ogre: Node = arena.spawn_enemy("ogre", at(Vector3(-10, 2.25, -36)))
	ogre.global_position = at(Vector3(-10, 2.25, -27))
	var return_path: PackedVector3Array = nav.path_between(ogre.global_position, ogre.spawn_point)
	var return_budget := ceili((_path_length(return_path) / ogre.move_speed + 2.0) * Engine.physics_ticks_per_second)
	for frame in range(return_budget):
		await physics_frame
		if ogre.global_position.distance_to(ogre.spawn_point) < .65: break
	verify(ogre.global_position.distance_to(ogre.spawn_point) < .75, "real ogre UnitBrain returns around village house using shared actor movement")
	verify(ogre.get_node_or_null("WorldNavigationAgent") != null, "real AI delegates route following to NavigationAgent3D")
	ogre.set_control_mode("none")
	var stopped: Vector3 = ogre.global_position
	for frame in range(10): await physics_frame
	verify(Vector2(ogre.global_position.x - stopped.x, ogre.global_position.z - stopped.z).length() < .01, "control mode none stops navigation intent without changing identity")
	ogre.spawn_point = at(Vector3(1, 2.25, -41))
	ogre.global_position = at(Vector3(-5, 2.25, -41))
	ogre.set_control_mode("ai")
	return_path = nav.path_between(ogre.global_position, ogre.spawn_point)
	return_budget = ceili((_path_length(return_path) / ogre.move_speed + 2.0) * Engine.physics_ticks_per_second)
	for frame in range(return_budget):
		await physics_frame
		if ogre.global_position.distance_to(ogre.spawn_point) < .65: break
	verify(ogre.global_position.distance_to(ogre.spawn_point) < .75, "real ogre resumes AI and replans around market well after relocation")
	host.queue_free()
	await process_frame
	await process_frame
	print("WORLD NAVIGATION: ", checks - failures.size(), "/", checks, " passed")
	quit(1 if not failures.is_empty() else 0)
