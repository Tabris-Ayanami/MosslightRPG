extends SceneTree
## Isolated arena fixtures: real AI, controller, input movement and projectiles.
## Not a chapter playthrough or a human difficulty verdict.
const Attack = preload("res://combat/attack_instance.gd")
var arena: Node
var player: Node
var enemy: Node
var checks := 0
var failures: Array[String] = []
var capture_directory := ""

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="): capture_directory = argument.trim_prefix("--capture=")
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func ticks(count: int) -> void:
	for index in range(count):
		await physics_frame
		await process_frame

func prepare(ai := true) -> void:
	for action in ["move_left", "move_right", "move_up", "move_down"]: Input.action_release(action)
	for old in arena.enemies:
		old.ai_enabled = false
		old.combat.reset()
		old.set_physics_process(false)
		old.global_position = Vector3(100, .1, 100)
	for child in arena.effects.get_children():
		if child.get_script() == Attack: child.queue_free()
	player.form.restore()
	player.loadout.select_career("mage")
	player.loadout.set_level(3)
	player.combat.reset()
	player.global_position = Vector3(0, .1, 6)
	player.velocity = Vector3.ZERO
	player.set_physics_process(true)
	enemy = arena.spawn_enemy("ogre", Vector3(0, .1, -2))
	enemy.ai_enabled = false
	enemy.ai_cooldown = 0
	arena.locked_target = enemy
	arena.aim_override = enemy.global_position
	await ticks(1)
	enemy.ai_enabled = ai

func await_throw() -> bool:
	for frame in range(120):
		if enemy.combat.runner.current_action.get("id", "") == "ogre_stone_throw": return true
		await ticks(1)
	return false

func capture(name: String) -> void:
	if capture_directory.is_empty() or DisplayServer.get_name() == "headless": return
	DirAccess.make_dir_recursive_absolute(capture_directory)
	await RenderingServer.frame_post_draw
	verify(root.get_texture().get_image().save_png(capture_directory.path_join(name + ".png")) == OK, "captured " + name)

func stationary_target() -> void:
	await prepare()
	var before: float = player.resources.current("HP")
	verify(await await_throw(), "real AI opens with its native ranged skill against a visible distant target")
	var direction: Vector3 = enemy.combat.action_direction
	var clock: float = enemy.combat.input_time
	for frame in range(120):
		if enemy.combat.runner.action_time >= .65: break
		await ticks(1)
	verify(player.resources.current("HP") == before and enemy.combat.runner.action_phase == "STARTUP", "stone cannot damage during its one-second telegraph")
	verify(enemy.animation._throw_stone.visible and enemy.animation.current_animation == "throw_windup", "raised stone distinguishes the throw windup from a sword swing")
	await capture("01-throw-windup")
	var projectile: Node
	for frame in range(120):
		for child in arena.effects.get_children():
			if child.get_script() == Attack and child.action.get("id", "") == "ogre_stone_throw": projectile = child
		if is_instance_valid(projectile): break
		await ticks(1)
	verify(is_instance_valid(projectile), "active phase creates an actual travelling projectile")
	if is_instance_valid(projectile):
		verify(projectile.direction.is_equal_approx(direction), "projectile retains the committed windup direction")
		verify(not enemy.animation._throw_stone.visible, "held stone is hidden when the projectile is released")
		await ticks(12)
		await capture("02-stone-flight")
	for frame in range(180):
		if player.resources.current("HP") < before: break
		await ticks(1)
	verify(player.resources.current("HP") < before and is_equal_approx(float(enemy.combat.last_damage.get("raw", 0)), 140.0), "standing in the lane takes the real 140-raw physical attack")
	verify(enemy.combat.input_time - clock >= 1.6, "damage arrives after startup and travel, never as instant ranged damage")
	await ticks(40)
	verify(enemy.combat.action_failure(enemy.skill_at(1)).contains("冷却"), "the normal controller refuses a second throw before its cooldown")

func sidestep_target() -> void:
	await prepare()
	verify(await await_throw(), "sidestep fixture starts the same real windup")
	var before: float = player.resources.current("HP")
	var origin: Vector3 = player.global_position
	var direction: Vector3 = enemy.combat.action_direction
	Input.action_press("move_right")
	await ticks(42)
	Input.action_release("move_right")
	verify(player.global_position.distance_to(origin) > 2.0, "ordinary movement crosses the shot lane during the telegraph")
	verify(enemy.combat.action_direction.is_equal_approx(direction), "AI does not retarget the windup onto the moving player")
	await capture("03-sidestep")
	await ticks(140)
	verify(is_equal_approx(player.resources.current("HP"), before), "sidestepping avoids the whole projectile without invulnerability or a resource grant")

func wall_blocks_shot() -> void:
	await prepare(false)
	var wall := StaticBody3D.new()
	wall.position = Vector3(0, 2, 2)
	wall.collision_layer = 1
	wall.collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(6, 4, .4)
	collision.shape = shape
	wall.add_child(collision)
	arena.actor_parent.add_child(wall)
	await ticks(3)
	var starts: Array[String] = []
	enemy.combat.runner.action_started.connect(func(action: Dictionary): starts.append(action.id))
	verify(not arena.line_clear(enemy.global_position, player.global_position), "fixture wall blocks sight in the actors' actual physics world")
	verify(enemy.combat.action_failure(enemy.skill_at(1)).is_empty(), "occlusion test starts with a ready, payable throw")
	enemy.ai_enabled = true
	await ticks(100)
	verify(starts.is_empty(), "AI does not start a ranged attack through an opaque wall")
	enemy.ai_enabled = false
	enemy.combat.reset()
	enemy.current_target = player
	enemy.facing = Vector3.BACK
	var before: float = player.resources.current("HP")
	verify(enemy.combat.request_skill(1), "controller can issue a deliberately wall-blocked shot for the collision fixture")
	var projectile: Node
	for frame in range(120):
		for child in arena.effects.get_children():
			if child.get_script() == Attack and child.action.get("id", "") == "ogre_stone_throw": projectile = child
		if is_instance_valid(projectile): break
		await ticks(1)
	verify(is_instance_valid(projectile), "wall fixture launches a real projectile before it collides")
	await ticks(170)
	verify(not is_instance_valid(projectile) and player.resources.current("HP") == before, "actual projectile collides with the wall and cannot hit beyond it")
	wall.queue_free()
	await ticks(3)

func shield_blocks_shot() -> void:
	await prepare(false)
	verify(player.form.apply_enemy_form("heavy_guard", 30), "shield fixture uses the catalog guard body")
	player.facing = (enemy.global_position - player.global_position).normalized()
	verify(player.combat.defense.start_guard(false), "defender raises its real shield before the throw")
	var before: float = player.resources.current("HP")
	var stamina: float = player.resources.current("Stamina")
	enemy.ai_enabled = true
	verify(await await_throw(), "AI throws at the shielded target through the same action path")
	for frame in range(180):
		if player.combat.defense.last_outcome != "none": break
		await ticks(1)
	# A fully blocked hit is recorded on the defender, not damage_dealt on the source.
	verify(player.combat.defense.last_outcome == "block" and player.combat.last_damage.get("guarded", false) and player.combat.last_damage.get("raw", 0) == 140 and player.resources.current("HP") == before, "ordinary shield guard stops the actual physical projectile")
	verify(is_equal_approx(stamina - player.resources.current("Stamina"), 1), "ordinary block pays one real stamina instead of a perfect-block refund")
	player.form.restore()

func player_uses_natural_throw() -> void:
	await prepare()
	enemy.ai_enabled = false
	enemy.combat.reset()
	verify(player.form.apply_enemy_form("ogre", 30), "temporary ogre body exposes its natural abilities through the existing form system")
	verify(player.skill_at(0).id == "ogre_grab" and player.skill_at(1).id == "ogre_stone_throw" and player.action_for("SECONDARY_TAP").id == "ogre_heavy_sweep", "Q grab, E stone and right mouse sweep remain separate")
	var before: float = enemy.resources.current("HP")
	arena.locked_target = enemy
	arena.aim_override = enemy.global_position
	verify(player.combat.request_skill(1), "human-controlled body uses the normal E skill request")
	await ticks(150)
	verify(enemy.resources.current("HP") < before, "human-controlled natural throw creates real projectile damage")
	player.form.restore()

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(3)
	player = arena.player
	arena.sound.muted = true
	arena.ui.toggle_menu(false)
	arena.input_blocked = false
	arena.pointer_blocked = false
	arena.set_physics_process(false)
	await stationary_target()
	await sidestep_target()
	await wall_blocks_shot()
	await shield_blocks_shot()
	await player_uses_natural_throw()
	print("BOSS_RANGED: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures: printerr("FAIL: ", failure)
	for action in ["move_left", "move_right", "move_up", "move_down"]: Input.action_release(action)
	arena.queue_free()
	await ticks(3)
	quit(0 if failures.is_empty() else 1)
