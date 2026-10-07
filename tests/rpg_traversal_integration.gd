extends SceneTree
## Main-world input, save safety, and real hit delivery across different heights.
const Repository = preload("res://rpg/save_repository.gd")
var game: Node
var actor: Node
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func press_f() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_F
	event.pressed = true
	root.push_input(event, true)
	await ticks(2)
	event = InputEventKey.new()
	event.physical_keycode = KEY_F
	event.pressed = false
	root.push_input(event, true)
	await ticks(2)

func hit(action: Dictionary, foe: Node, at: Vector3) -> float:
	game.combat_world.clear_attacks()
	foe.combat.reset()
	var before: float = foe.resources.current("HP")
	game.combat_world.perform_action(actor, action, actor.global_position, Vector3.FORWARD, at, foe)
	await ticks(3)
	return before - foe.resources.current("HP")

func run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(15)
	actor = game.player
	game.sound.muted = true
	game.combat_world.encounters_started = true
	var ladder: Node3D = game.reference_map.get_node("NorthernVillage/VillageHouseLadder")
	actor.restore(ladder.bottom_exit() + Vector3.UP * .02)
	await ticks(8)
	verify(game.nearest_interactable() == ladder, "main world finds the nearby ladder bottom")
	await press_f()
	verify(actor.ladder.active and actor.get_meta("traversal_locked", false), "physical F key enters ladder through normal game input")
	verify(game.combat_world.input_blocked and not actor.combat.can_start(), "climbing locks the combat input and direct action gate")
	verify(not actor.combat.request_guard() and not actor.combat.switch_set() and not actor.combat.start_dodge(), "direct guard, switch, and dodge calls cannot bypass ladder lock")
	verify(not actor.combat.action_failure({"id": "probe", "animation_family": "UNARMED"}, true).is_empty(), "queued action validation cannot bypass traversal lock")
	var entry: Vector3 = actor.global_position
	Input.action_press("move_up")
	await ticks(55)
	Input.action_release("move_up")
	verify(actor.ladder.active and actor.global_position.y > entry.y + .5, "real W movement climbs instead of walking into the wall")
	game.paused = true
	var paused_at: Vector3 = actor.global_position
	Input.action_press("move_up")
	await ticks(15)
	Input.action_release("move_up")
	verify(actor.global_position.distance_to(paused_at) < .01, "pause freezes an attached climber")
	game.paused = false
	var temporary := OS.get_temp_dir().path_join("mosslight-traversal-save-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var repository := Repository.new(temporary)
	var created: Dictionary = repository.create("攀爬测试", 0)
	var safe: Vector3 = actor.ladder.stable_position()
	var saved: Dictionary = repository.save(0, "攀爬测试", actor, game)
	verify(created.ok and saved.ok, "mid-climb saving commits a valid adventure")
	var stored := Vector3(float(saved.snapshot.world.position[0]), float(saved.snapshot.world.position[1]), float(saved.snapshot.world.position[2]))
	verify(stored.distance_to(safe) < .001, "save stores a supported endpoint rather than midair ladder coordinates")
	var before_detach: Vector3 = actor.global_position
	await press_f()
	verify(not actor.ladder.active and absf(actor.global_position.y - before_detach.y) < .5, "F releases the ladder at current height without teleporting to the roof")
	actor.restore(ladder.bottom_exit() + Vector3.UP * .02)
	await ticks(5)
	await press_f()
	verify(actor.ladder.active, "ladder can be entered again after release")
	var restored: Dictionary = repository.restore(saved.snapshot, actor, game)
	verify(restored.ok and not actor.ladder.active and not actor.get_meta("traversal_locked", false), "loading clears the active ladder and combat lock")
	await ticks(12)
	verify(actor.is_on_floor() and actor.global_position.distance_to(stored) < .3, "loaded character stands on the saved safe landing")
	verify(actor.combat.can_start() and actor.input_router.is_physics_processing(), "loading restores ordinary movement and combat input")
	var directory := DirAccess.open(temporary)
	for file in directory.get_files():
		DirAccess.remove_absolute(temporary.path_join(file))
	DirAccess.remove_absolute(temporary)

	# Real AttackInstance delivery, placed above empty space to isolate height
	# filtering from wall occlusion. Movement is disabled, hit processing remains.
	actor.set_physics_process(false)
	actor.global_position = Vector3(150, 25, 150)
	var foe: Node = game.combat_world.spawn_enemy("soldier", actor.global_position + Vector3(0, 4, -1))
	foe.set_physics_process(false)
	foe.resources.configure("HP", 2000)
	var swing := {"id": "height_probe", "targeting": "CONE", "range": 3, "angle": 120, "formula": {"base": 20}, "can_crit": false, "animation_family": "UNARMED"}
	verify(await hit(swing, foe, foe.global_position) == 0, "actual melee cannot damage a target four meters above")
	foe.global_position = actor.global_position + Vector3(0, .7, -1)
	verify(await hit(swing, foe, foe.global_position) > 0, "actual melee still hits across a walkable slope height")
	foe.global_position = actor.global_position + Vector3(0, -4, -1)
	verify(await hit(swing, foe, foe.global_position) == 0, "actual melee cannot damage a target on the floor below")
	var impact: Vector3 = actor.global_position + Vector3(0, 4, -1)
	foe.global_position = impact
	var area := {"id": "impact_probe", "targeting": "POINT", "radius": 2, "formula": {"base": 20}, "can_crit": false}
	verify(await hit(area, foe, impact) > 0, "aimed area damage follows its elevated impact surface")
	foe.global_position.y -= 4
	verify(await hit(area, foe, impact) == 0, "aimed area damage does not leak into the floor below")
	game._release_actions()
	game.queue_free()
	await ticks(4)
	print("RPG_TRAVERSAL_INTEGRATION: %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
