extends SceneTree
## Real map + real UnitBrain/CombatActor movement; no App or player saves.
const ORIGIN := Vector3(0, 0, 110)
const Preferences = preload("res://rpg/game_preferences.gd")
const Navigation = preload("res://rpg/world_navigation.gd")
var checks := 0
var failures: Array[String] = []

class Host extends Node3D:
	var reference_map: Node3D
	var world_navigation: Node
	var paused := false
	var camera_dragging := false
	var ui_pointer_blocked := false
	func notify(_message: String) -> void: pass

func _initialize() -> void:
	Preferences.settings_path = OS.get_environment("TEMP").path_join("mosslight_fountain_%d.cfg" % OS.get_process_id())
	for action in ["attack_primary", "attack_secondary"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
	print("PASS " if ok else "FAIL ", message)

func flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func check_body(unit: Node, radius: float, height: float, label: String) -> void:
	var collider := unit.get_node("CollisionShape3D") as CollisionShape3D
	var capsule := collider.shape as CapsuleShape3D
	check(collider.scale.is_equal_approx(Vector3.ONE) and is_equal_approx(capsule.radius, radius) and is_equal_approx(capsule.height, height) and is_equal_approx(collider.position.y, height * .5), label + " uses physical capsule dimensions with unit node scale")

func run() -> void:
	var host := Host.new()
	root.add_child(host)
	host.reference_map = load("res://scenes/reference_map.tscn").instantiate()
	host.reference_map.position = ORIGIN
	host.add_child(host.reference_map)
	await host.reference_map.get_node("SculptableTerrain").load_finished
	await physics_frame
	var camera := Camera3D.new()
	camera.position = ORIGIN + Vector3(14, 28, 18)
	host.add_child(camera)
	camera.look_at(ORIGIN + Vector3(0, 2, -10))
	camera.current = true
	var nav := Navigation.new()
	host.add_child(nav)
	host.world_navigation = nav
	check(nav.setup(host), "real translated map navigation initializes")
	var deadline := Time.get_ticks_msec() + 5000
	while not nav.navigation_ready() and Time.get_ticks_msec() < deadline: await physics_frame
	check(nav.navigation_ready(), "complete navigation map published before movement")
	var arena := preload("res://combat/combat_world.gd").new()
	arena.host = host
	arena.actor_parent = host
	host.add_child(arena)
	var player := preload("res://combat/combat_actor.gd").new()
	player.is_player = true
	player.arena = arena
	player.visual_script = preload("res://combat/animation_controller.gd")
	player.position = ORIGIN + Vector3(8, 2.25, -40)
	host.add_child(player)
	arena.player = player
	player.set_control_mode("none")
	player.faction_id = "hostiles"
	check_body(player, .27, 1.3, "normal human")
	for body_scale in [Vector3.ONE, Vector3(1.2, 1.6, 1.2), Vector3.ONE * 1.4]:
		var template: Dictionary = preload("res://combat/unit_definition.gd").for_enemy(arena.database, "soldier")
		template.body.scale = body_scale
		var probe: Node = arena.spawn_unit(template, ORIGIN + Vector3(8, 2.25, -44), "none")
		check_body(probe, .35 * body_scale.x, 1.5 * body_scale.y, "soldier scale " + str(body_scale))
		host.remove_child(probe)
		probe.queue_free()
	await process_frame
	var routes := [
		{"name": "garden start to warden", "from": Vector3(1.6, 2.35, 4.8), "to": Vector3(-2.8, 2.3, -31.2)},
		{"name": "warden back to garden start", "from": Vector3(-2.8, 2.3, -31.2), "to": Vector3(1.6, 2.35, 4.8)},
		# Retain chapter one's already walkable forest route, without artificial
		# waypoints or movement shortcuts.
		{"name": "forest entrance to chapter ogre", "from": Vector3(27, 2.3, -2), "to": Vector3(42, 2.4, -25)}
	]
	for route in routes:
		var start: Vector3 = ORIGIN + route.from
		var goal: Vector3 = ORIGIN + route.to
		var enemy: Node = arena.spawn_enemy("ogre", goal)
		check_body(enemy, .525, 1.95, route.name + " ogre")
		enemy.global_position = start
		var path: PackedVector3Array = nav.path_between(start, goal)
		if not path.is_empty(): print("FOUNTAIN_ENDPOINTS ", route.name, " first=", host.reference_map.to_local(path[0]), " last=", host.reference_map.to_local(path[-1]))
		check(nav.is_reachable(start, goal), route.name + " has connected endpoints")
		var length := 0.0
		for i in range(1, path.size()): length += path[i].distance_to(path[i - 1])
		var budget := ceili((length / enemy.move_speed + 6.0) * Engine.physics_ticks_per_second)
		var dry := true
		var last_sample: Vector3 = enemy.global_position
		var stalled_frames := 0
		var contacts: Dictionary = {}
		var maximum_motion := 0.0
		var previous: Vector3 = enemy.global_position
		for frame in range(budget):
			await physics_frame
			dry = dry and enemy.global_position.y > 1.1
			maximum_motion = maxf(maximum_motion, enemy.global_position.distance_to(previous))
			previous = enemy.global_position
			for index in range(enemy.get_slide_collision_count()):
				var hit: KinematicCollision3D = enemy.get_slide_collision(index)
				if absf(hit.get_normal().y) < .95:
					contacts[str(hit.get_collider().get_path())] = str(hit.get_normal())
			if frame % 60 == 59:
				if flat_distance(enemy.global_position, last_sample) < .03: stalled_frames += 60
				else: stalled_frames = 0
				last_sample = enemy.global_position
			var distance := flat_distance(enemy.global_position, goal)
			# A projected endpoint can stop slightly before the requested position.
			# This is arrival only inside the same .75m physical tolerance below.
			if distance < .5 or (distance < .75 and enemy.move_direction.length_squared() < .001) or stalled_frames >= 180: break
		var remaining := flat_distance(enemy.global_position, goal)
		var agent := enemy.get_node("WorldNavigationAgent") as NavigationAgent3D
		var live_path := agent.get_current_navigation_path()
		var index := agent.get_current_navigation_path_index()
		if index < live_path.size():
			print("FOUNTAIN_WAYPOINT actor=", host.reference_map.to_local(enemy.global_position), " point=", host.reference_map.to_local(live_path[index]), " horizontal=", flat_distance(enemy.global_position, live_path[index]), " vertical=", absf(enemy.global_position.y - live_path[index].y), " desired=", agent.path_desired_distance, " intent=", enemy.move_direction)
		print("FOUNTAIN_ROUTE ", route.name, " remaining=", remaining, " local=", host.reference_map.to_local(enemy.global_position), " contacts=", contacts)
		print("FOUNTAIN_MOTION velocity=", enemy.velocity, " real_velocity=", enemy.get_real_velocity(), " floor=", enemy.is_on_floor(), " state=", enemy.combat.state, " steps=", enemy.surface_traversal.steps, " step_active=", enemy.surface_traversal.active, " step_reason=", enemy.surface_traversal.last_reason)
		var hit := KinematicCollision3D.new()
		if enemy.test_move(enemy.global_transform, enemy.move_direction * .1, hit):
			print("FOUNTAIN_FORWARD_HIT ", hit.get_collider().get_path(), " normal=", hit.get_normal(), " at=", host.reference_map.to_local(hit.get_position()))
		check(remaining < .75, route.name + " real ogre physically arrives (%.2fm remaining)" % remaining)
		check(stalled_frames < 180, route.name + " has no persistent wall pushing")
		check(dry, route.name + " remains above lake bed")
		check(enemy.get_node_or_null("WorldNavigationAgent") != null, route.name + " uses shared AI/navigation")
		check(maximum_motion < .25, route.name + " arrives through continuous physical motion without teleport (%.3fm/frame)" % maximum_motion)
		if remaining < .75:
			var arrived: Vector3 = enemy.global_position
			var idle_motion := 0.0
			for frame in range(120):
				await physics_frame
				idle_motion = maxf(idle_motion, flat_distance(arrived, enemy.global_position))
			check(idle_motion < .08, route.name + " stops stably at home for two seconds")
		nav.forget(enemy)
		host.remove_child(enemy)
		enemy.queue_free()
		await process_frame
	host.queue_free()
	await process_frame
	await process_frame
	print("FOUNTAIN NAVIGATION: ", checks - failures.size(), "/", checks, " passed")
	quit(0 if failures.is_empty() else 1)
