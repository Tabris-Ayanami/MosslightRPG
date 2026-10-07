extends SceneTree
## Real map, real CombatActors and UnitBrain. No frontend or adventure repository.
const ORIGIN := Vector3(0, 0, 110)
const Navigation = preload("res://rpg/world_navigation.gd")
const Actor = preload("res://combat/combat_actor.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
var checks := 0
var failures: Array[String] = []
var host: Node3D
var arena: Node
var player: Node
var nav: Node
var enemies: Array[Node] = []

class Host extends Node3D:
	var reference_map: Node3D
	var world_navigation: Node
	var paused := false
	var camera_dragging := false
	var ui_pointer_blocked := false
	func notify(_message: String) -> void: pass

class SilentSound extends Node:
	func play_tone(_tone: String) -> void: pass

func _initialize() -> void:
	Preferences.settings_path = OS.get_environment("TEMP").path_join("mosslight_chase_%d.cfg" % OS.get_process_id())
	for action in ["attack_primary", "attack_secondary"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func at(local: Vector3) -> Vector3: return local + ORIGIN
func flat_distance(a: Vector3, b: Vector3) -> float: return Vector2(a.x - b.x, a.z - b.z).length()
func ticks(count: int) -> void:
	for frame in range(count): await physics_frame

func relocate_target(local: Vector3) -> void:
	player.combat.reset()
	player.global_position = at(local)
	player.velocity = Vector3.ZERO
	player.surface_traversal.clear()

func spawn(local: Vector3) -> Node:
	var enemy: Node = arena.spawn_enemy("soldier", at(local))
	# Suppress attack cadence only in motion fixtures so the target stays still.
	# Separate assertions below enable real controller attacks again.
	enemy.ai_cooldown = 100000
	enemies.append(enemy)
	return enemy

func clear_enemies() -> void:
	for enemy in enemies:
		if is_instance_valid(enemy):
			nav.forget(enemy)
			host.remove_child(enemy)
			enemy.queue_free()
	enemies.clear()
	arena.clear_attacks()
	await ticks(2)

func run() -> void:
	host = Host.new()
	root.add_child(host)
	host.reference_map = load("res://scenes/reference_map.tscn").instantiate()
	host.reference_map.position = ORIGIN
	host.add_child(host.reference_map)
	await host.reference_map.get_node("SculptableTerrain").load_finished
	await physics_frame
	nav = Navigation.new()
	host.add_child(nav)
	host.world_navigation = nav
	verify(nav.setup(host), "real map navigation initializes")
	# Async publication uses wall time; fixed-fps can advance many simulation
	# frames before the navigation worker publishes its first complete map.
	var publish_deadline := Time.get_ticks_msec() + 5000
	while not nav.navigation_ready() and Time.get_ticks_msec() < publish_deadline:
		await physics_frame
	verify(nav.navigation_ready(), "navigation mesh published before pursuit")
	arena = preload("res://combat/combat_world.gd").new()
	arena.host = host
	arena.actor_parent = host
	host.add_child(arena)
	arena.effects = Node3D.new()
	host.add_child(arena.effects)
	arena.sound = SilentSound.new()
	host.add_child(arena.sound)
	player = Actor.new()
	player.arena = arena
	player.is_player = true
	player.visual_script = preload("res://combat/animation_controller.gd")
	player.position = at(Vector3(4, 2.25, -40))
	host.add_child(player)
	arena.player = player
	player.set_control_mode("none")
	player.resources.configure("HP", 100000, true)
	await ticks(4)

	# Stationary target: motion stops at attack range rather than oscillating.
	var enemy := spawn(Vector3(4, 2.25, -33))
	await ticks(5)
	verify(enemy.current_target == player, "visible hostile is acquired by the real perception query")
	await ticks(240)
	var settled: Vector3 = enemy.global_position
	var max_motion := 0.0
	for frame in range(600):
		await physics_frame
		max_motion = maxf(max_motion, flat_distance(enemy.global_position, settled))
	verify(flat_distance(enemy.global_position, player.global_position) <= 2.4, "stationary target is approached to melee range")
	verify(max_motion < .12, "stationary target remains stable for 10 seconds (%.3fm)" % max_motion)
	enemy.ai_cooldown = 0
	var attacks: int = enemy.attacks_made
	await ticks(150)
	verify(enemy.attacks_made > attacks and player.resources.current("HP") < 100000, "arrived enemy executes a real attack and deals damage")
	await clear_enemies()

	# The target disappears behind the well: pursue the last visible point only.
	relocate_target(Vector3(-3.8, 2.25, -38))
	enemy = spawn(Vector3(-6.5, 2.25, -39.5))
	await ticks(8)
	verify(enemy.current_target == player, "well fixture starts with confirmed sight")
	var last_seen: Vector3 = enemy.brain._last_seen
	relocate_target(Vector3(1, 2.25, -42.5))
	verify(not arena.line_clear(enemy.global_position, player.global_position), "real well blocks the new target position")
	await ticks(60)
	verify(enemy.current_target == player and enemy.brain._sight_memory > 1.8 and enemy.brain._sight_memory < 2.1, "lost sight retains a bounded three-second investigation")
	verify(enemy.brain._last_seen.distance_to(last_seen) < .02, "occluded target's new position is not tracked")
	var investigated: Vector3 = enemy.global_position
	verify(flat_distance(investigated, last_seen) < flat_distance(enemy.spawn_point, last_seen), "investigation physically advances toward last visible position")
	# Put target far away so sight cannot be reacquired during the expiry phase.
	relocate_target(Vector3(30, 2.25, 4))
	await ticks(125)
	verify(enemy.current_target == null and enemy.brain._sight_memory <= .02, "out-of-range target is forgotten after sight memory expires")
	await ticks(240)
	verify(flat_distance(enemy.global_position, enemy.spawn_point) < .65, "enemy returns home after investigation expires")
	await clear_enemies()

	# Continuous moving target over the actual east bridge.
	relocate_target(Vector3(16, 2.3, 1.7))
	enemy = spawn(Vector3(11.5, 2.3, 1.7))
	await ticks(10)
	var acquired: bool = enemy.current_target == player
	var stayed_dry := true
	for frame in range(600):
		if player.global_position.x < 26:
			player.safe_displace(Vector3(1.0 / 60.0, 0, 0))
		await physics_frame
		stayed_dry = stayed_dry and enemy.global_position.y > 1.1
	verify(acquired and enemy.global_position.x > 22, "real enemy continuously pursues a moving target across east bridge")
	verify(stayed_dry, "bridge pursuit stays above lake bed throughout")
	verify(flat_distance(enemy.global_position, player.global_position) < 2.6, "pursuit reaches the target on the opposite bank")
	await clear_enemies()

	# The target walks around the rear of a real village house while the pursuer
	# approaches from its west side. Its footprint must stay outside the wall.
	relocate_target(Vector3(-14, 2.25, -36))
	enemy = spawn(Vector3(-14, 2.25, -27))
	await ticks(8)
	acquired = enemy.current_target == player
	var house: Node3D = host.reference_map.get_node("NorthernVillage/Buildings/House_2")
	var wall_clear := true
	var had_detour := false
	for frame in range(660):
		if player.global_position.x < -6.8:
			player.safe_displace(Vector3(1.5 / 60.0, 0, 0))
		await physics_frame
		var relative: Vector3 = house.to_local(enemy.global_position)
		# Actual house collider footprint is 1.6293815 x 1.9143548 local units.
		wall_clear = wall_clear and not (absf(relative.x) < .8146 and absf(relative.z) < .9571)
		had_detour = had_detour or enemy.global_position.x < -12.5 and enemy.global_position.z < at(Vector3(0, 0, -32)).z
	verify(acquired and had_detour and wall_clear, "continuous pursuit follows the west/rear side of real house without entering wall")
	verify(flat_distance(enemy.global_position, player.global_position) < 2.6, "enemy catches moving target around house")
	await clear_enemies()

	# Three simultaneous enemies use ordinary units and the real separation term.
	relocate_target(Vector3(4, 2.25, -40))
	for local in [Vector3(3.5, 2.25, -34), Vector3(4.5, 2.25, -34), Vector3(4, 2.25, -33.5)]: spawn(local)
	await ticks(420)
	var stable_positions: Array[Vector3] = []
	for unit in enemies: stable_positions.append(unit.global_position)
	var max_drift := 0.0
	var min_separation := INF
	for frame in range(600):
		await physics_frame
		for i in range(enemies.size()):
			max_drift = maxf(max_drift, flat_distance(enemies[i].global_position, stable_positions[i]))
			for j in range(i + 1, enemies.size()): min_separation = minf(min_separation, flat_distance(enemies[i].global_position, enemies[j].global_position))
	var all_close := true
	for unit in enemies: all_close = all_close and flat_distance(unit.global_position, player.global_position) < 3.0
	verify(all_close, "three enemies reach a usable melee ring around the same target")
	verify(min_separation >= .68, "three 0.35m capsules do not remain interpenetrating (%.3fm)" % min_separation)
	verify(max_drift < .2, "settled group does not jitter for 10 seconds (%.3fm)" % max_drift)
	await clear_enemies()

	# Narrow bridge and coincident starting bodies: same path cannot preserve a
	# stack of three units forever simply because a zero vector has no direction.
	relocate_target(Vector3(24, 2.25, 1.7))
	for i in range(3): spawn(Vector3(16, 2.25, 1.7))
	await ticks(600)
	min_separation = INF
	stayed_dry = true
	all_close = true
	for i in range(enemies.size()):
		stayed_dry = stayed_dry and enemies[i].global_position.y > 1.1
		all_close = all_close and flat_distance(enemies[i].global_position, player.global_position) < 3.0
		for j in range(i + 1, enemies.size()): min_separation = minf(min_separation, flat_distance(enemies[i].global_position, enemies[j].global_position))
	verify(stayed_dry, "crowded bridge pursuit does not fall into lake")
	verify(min_separation >= .68, "coincident units resolve overlap during real pursuit (%.3fm)" % min_separation)
	verify(all_close, "separated bridge group still reaches the target")
	await clear_enemies()

	# Last sight behind a house is investigated once, then the actor returns.
	relocate_target(Vector3(-10, 2.25, -27))
	enemy = spawn(Vector3(-10, 2.25, -23))
	await ticks(12)
	verify(enemy.current_target == player, "house fixture acquires the visible target before occlusion")
	relocate_target(Vector3(-10, 2.25, -36))
	verify(not arena.line_clear(enemy.global_position, player.global_position), "house collider hides target from the enemy")
	await ticks(1200)
	verify(enemy.current_target == null and flat_distance(enemy.global_position, enemy.spawn_point) < .65 and enemy.move_direction.length() < .01, "house occlusion does not cause endless wall pushing over twenty seconds")
	await clear_enemies()

	host.queue_free()
	await process_frame
	await process_frame
	print("WORLD CHASE: ", checks - failures.size(), "/", checks, " passed")
	quit(1 if not failures.is_empty() else 0)
