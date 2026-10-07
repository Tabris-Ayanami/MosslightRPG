extends SceneTree
## Real village scene, physical-key InputMap events and actual capsule landing.
var game: Node
var player: CharacterBody3D
var ladder: Node3D
var checks := 0
var failures: Array[String] = []
var actions: Array[String] = []

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func key(code: Key, down: bool, frames := 2) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)
	await ticks(frames)
func tap(code: Key) -> void:
	await key(code, true)
	await key(code, false)
func to_bottom() -> void:
	player.restore(ladder.bottom_exit())
	await ticks(4)
func enter_bottom() -> void:
	await to_bottom()
	await tap(KEY_F)
func obstacle(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	ladder.get_parent().add_child(body)
	body.global_transform = Transform3D(ladder.global_basis, at)
	body.collision_layer = 1
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	return body

func run() -> void:
	root.size = Vector2i(1280, 720)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(18)
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	player = game.player
	ladder = game.reference_map.get_node("NorthernVillage/VillageHouseLadder")
	player.combat.runner.action_started.connect(func(action: Dictionary): actions.append(action.get("id", "")))
	var original_mask: int = player.collision_mask
	var original_layer: int = player.collision_layer
	check(game.reference_map.get_node("NorthernVillage/Buildings").get_child_count() == 7, "existing seven village houses are preserved")
	check(ladder.is_in_group("interactables") and ladder.landing is StaticBody3D, "one interactive ladder has a visible colliding rooftop landing")
	check(ladder.top_exit().y - ladder.bottom_exit().y > 5.0, "ladder reaches the existing house roof")
	print("LADDER_SITE bottom=", ladder.bottom_exit(), " top=", ladder.top_exit(), " anchor=", ladder.top_anchor())
	check(not player.ladder.try_interact(ladder), "faraway player cannot teleport onto ladder")
	await to_bottom()
	var barrier := obstacle(ladder.bottom_exit().lerp(ladder.bottom_anchor(), .5) + Vector3.UP, Vector3(1.5, 2, .10))
	await ticks(2)
	var entry_start: Vector3 = player.global_position
	await tap(KEY_F)
	check(not player.ladder.active and player.ladder.last_reason == "entry_blocked" and player.global_position.distance_to(entry_start) < .04, "full capsule entry sweep rejects nearby ladder through an intervening wall")
	barrier.queue_free()
	await ticks(2)
	check(player.combat.weapon_action("PRIMARY_TAP"), "ordinary civilian punch can begin before traversal")
	await tap(KEY_F)
	check(not player.ladder.active and player.combat.runner.busy(), "F cannot cancel an active combat move to enter ladder")
	await ticks(50)
	await enter_bottom()
	check(player.ladder.active and game.last_interaction == ladder, "physical F enters nearby bottom through world interaction")
	check(player.get_meta("traversal_locked", false) and not player.input_router.is_physics_processing(), "climb blocks combat input generation")
	check(player.animation.climbing_active and player.animation.weapons_stowed, "shared character uses held climbing pose with weapons stowed")
	check(player.collision_mask == original_mask and player.collision_layer == original_layer, "climb keeps original capsule collision filters")
	var bottom: Vector3 = player.global_position
	await key(KEY_W, true, 60)
	await key(KEY_W, false)
	check(player.global_position.y > bottom.y + 1.6 and player.global_position.y < bottom.y + 2.1, "physical W climbs at configured speed")
	check(player.facing.dot(ladder.facing_direction()) > .99, "actor remains facing the actual ladder plane")
	var held: Vector3 = player.global_position
	var phase: float = player.ladder.phase
	await ticks(25)
	check(player.global_position.is_equal_approx(held) and is_equal_approx(phase, player.ladder.phase), "no input holds position and exact rung pose")
	var count := actions.size()
	var stamina: float = player.resources.current("Stamina")
	var group: int = player.loadout.current_set
	await tap(KEY_SPACE)
	await tap(KEY_SHIFT)
	await tap(KEY_Q)
	check(player.ladder.active and actions.size() == count and player.loadout.current_set == group and player.resources.current("Stamina") == stamina, "Space Shift and Q cannot act or spend while climbing")
	check(not player.combat.weapon_action("PRIMARY_TAP"), "direct weapon command is blocked by traversal state")
	await key(KEY_S, true, 18)
	await key(KEY_S, false)
	check(player.global_position.y < held.y - .45, "physical S descends rather than walking off the ladder")
	var middle: Vector3 = player.global_position
	var stable: Vector3 = player.ladder.stable_position()
	check(stable.distance_to(ladder.bottom_exit()) < .01, "save projection chooses ground endpoint from lower half")
	await tap(KEY_F)
	check(not player.ladder.active and not player.get_meta("traversal_locked", false) and player.input_router.is_physics_processing(), "mid-ladder physical F restores normal input")
	check(player.global_position.y > ladder.bottom_exit().y + .4 and player.global_position.y <= middle.y + .03, "mid-ladder F releases at current height without endpoint teleport")
	await ticks(65)
	check(player.is_on_floor() and absf(player.global_position.y - ladder.bottom_exit().y) < .18, "released capsule falls safely to the unchanged village ground")
	await enter_bottom()
	await key(KEY_W, true)
	var reached := false
	for i in range(240):
		await ticks(1)
		if not player.ladder.active:
			reached = true
			break
	await key(KEY_W, false)
	await ticks(30)
	check(reached and player.ladder.last_reason == "top", "holding W reaches and automatically exits at the roof")
	check(player.is_on_floor() and absf(player.global_position.y - ladder.top_exit().y) < .13, "actual capsule remains supported by roof landing collision")
	check(player.global_position.distance_to(ladder.top_exit()) < .55, "roof exit lies on the small landing")
	check(player.collision_mask == original_mask and player.collision_layer == original_layer, "end exit preserves original collision filters")
	await tap(KEY_F)
	await key(KEY_S, true, 20)
	await key(KEY_S, false)
	barrier = obstacle(ladder.top_exit() + Vector3.UP * .7, Vector3(.7, 1.4, .7))
	await ticks(2)
	await key(KEY_W, true, 28)
	await key(KEY_W, false)
	check(player.ladder.active and player.ladder.last_reason == "exit_blocked" and player.global_position.distance_to(ladder.top_anchor()) < .04, "blocked roof clearance keeps climber at top anchor without wall penetration")
	check(player.ladder.stable_position().distance_to(ladder.bottom_exit()) < .01, "save projection avoids obstructed rooftop endpoint")
	barrier.queue_free()
	await ticks(2)
	await tap(KEY_W)
	await ticks(12)
	check(not player.ladder.active and player.is_on_floor(), "clearing roof obstacle permits normal W dismount without reset")
	await tap(KEY_F)
	await key(KEY_S, true, 20)
	await key(KEY_S, false)
	ladder.landing.collision_layer = 0
	await ticks(2)
	await key(KEY_W, true, 28)
	await key(KEY_W, false)
	check(player.ladder.active and player.ladder.last_reason == "exit_blocked", "missing roof support rejects dismount onto steep original roof")
	ladder.landing.collision_layer = 1
	await ticks(2)
	await tap(KEY_W)
	await ticks(12)
	check(not player.ladder.active and player.is_on_floor(), "restored landing support unlocks safe roof exit")
	await tap(KEY_F)
	check(player.ladder.active and player.ladder.last_reason == "entered_top", "physical F enters from reachable rooftop endpoint")
	await key(KEY_S, true, 30)
	await key(KEY_S, false)
	check(player.ladder.active and player.global_position.y < ladder.top_anchor().y - .7, "roof entry can descend using S")
	check(player.ladder.stable_position().distance_to(ladder.top_exit()) < .01, "save projection chooses rooftop endpoint from upper half")
	await key(KEY_S, true)
	for i in range(240):
		await ticks(1)
		if not player.ladder.active: break
	await key(KEY_S, false)
	await ticks(15)
	check(not player.ladder.active and player.ladder.last_reason == "bottom" and player.is_on_floor(), "S reaches ground and safely restores walking")
	await enter_bottom()
	await key(KEY_W, true, 20)
	await key(KEY_W, false)
	held = player.global_position
	game.paused = true
	paused = true
	await ticks(6)
	check(player.ladder.active and player.global_position.is_equal_approx(held), "menu pause holds ladder without gravity or progress")
	paused = false
	game.paused = false
	await key(KEY_W, true, 12)
	await key(KEY_W, false)
	check(player.ladder.active and player.global_position.y > held.y + .25, "closing menu resumes climbing normally")
	player.combat.force_control("HITSTUN", .3)
	await ticks(2)
	check(not player.ladder.active and not player.animation.climbing_active and player.input_router.is_physics_processing(), "real combat control interrupts traversal and releases pose and input")
	await ticks(35)
	check(player.combat.state in ["NORMAL", "MOVE"], "control expires without a traversal state lock")
	await enter_bottom()
	await key(KEY_W, true, 20)
	await key(KEY_W, false)
	player.restore(game.checkpoint)
	check(not player.ladder.active and not player.get_meta("traversal_locked", false) and player.global_position.distance_to(game.checkpoint) < .001, "restore cleanup leaves caller's destination intact")
	check(not player.animation.climbing_active and player.input_router.is_physics_processing(), "restore removes climbing IK and restores input router")
	await enter_bottom()
	player.health.receive(100000)
	await ticks(2)
	check(not player.ladder.active and not player.get_meta("traversal_locked", false), "death clears traversal lock without manufacturing HP")
	check(player.resources.current("HP") == 0 and player.collision_layer == 0, "death still retains combat health and collision semantics")
	await ticks(165)
	check(not player.ladder.active and player.combat.state != "DEAD" and player.resources.current("HP") > 0, "ordinary respawn returns a living, unclimbed player")
	print("LADDER_TRAVERSAL_RESULT checks=", checks, " failures=", failures.size())
	game.queue_free()
	await process_frame
	quit(1 if not failures.is_empty() else 0)
