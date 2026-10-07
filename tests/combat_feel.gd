extends SceneTree
## User-facing input regression: physical keyboard and mouse events pass through
## InputMap and the live arena. No test starts player actions through command().
## Godot --headless --path . --fixed-fps 60 --script tests/combat_feel.gd

var arena: Node
var player: Node
var checks := 0
var failures: Array[String] = []
var started: Array[Dictionary] = []
var semantics: Array[String] = []
var last_skill_request: Dictionary = {}
const ORIGIN := Vector3(0, .1, 6)
const POINTER := Vector2(640, 300)
const KEYS := [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E, KEY_R, KEY_X, KEY_SPACE, KEY_SHIFT]

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

func near(actual: float, expected: float, label: String, tolerance := .01) -> void:
	verify(absf(actual - expected) <= tolerance, "%s (%.4f / %.4f)" % [label, actual, expected])

func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	if pressed and code in [KEY_Q, KEY_E, KEY_R] and is_instance_valid(player):
		last_skill_request = {"code": OS.get_keycode_string(code), "frame": Engine.get_physics_frames(), "clock": player.input_router.clock, "state": player.combat.state, "phase": player.combat.runner.action_phase}
		print("INPUT_TRACE ", JSON.stringify(last_skill_request))
	Input.parse_input_event(event)

func mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = POINTER
	event.global_position = POINTER
	event.pressed = pressed
	Input.parse_input_event(event)

func tap_key(code: Key) -> void:
	key(code, true)
	await ticks(1)
	key(code, false)
	await ticks(1)

func tap_mouse(button := MOUSE_BUTTON_LEFT) -> void:
	mouse(button, true)
	await ticks(2)
	mouse(button, false)
	await ticks(2)

func wait_phase(phase: String, budget := 90) -> bool:
	for i in range(budget):
		if player.combat.runner.busy() and player.combat.runner.action_phase == phase:
			return true
		await ticks(1)
	return false

func prepare(career := "warrior") -> void:
	for code in KEYS:
		key(code, false)
	mouse(MOUSE_BUTTON_LEFT, false)
	mouse(MOUSE_BUTTON_RIGHT, false)
	for action in InputMap.get_actions():
		Input.action_release(action)
	for effect in arena.effects.get_children():
		effect.queue_free()
	arena.warnings.clear()
	player.resources.unlimited.clear()
	player.loadout.select_career(career)
	player.combat.reset()
	player.global_position = ORIGIN
	player.velocity = Vector3.ZERO
	player.facing = Vector3.FORWARD
	arena.aim_point = ORIGIN + Vector3.FORWARD * 10
	arena.aim_override = arena.aim_point
	arena.locked_target = null
	arena.ui.toggle_menu(false)
	arena.input_blocked = false
	for enemy in arena.enemies:
		enemy.ai_enabled = false
		enemy.combat.reset()
		enemy.global_position = Vector3(18, .1, 18)
	var pointer := InputEventMouseMotion.new()
	pointer.position = POINTER
	pointer.global_position = POINTER
	Input.parse_input_event(pointer)
	await ticks(3)
	started.clear()
	semantics.clear()
	last_skill_request.clear()

func record_action(action: Dictionary) -> void:
	var recorded := action.duplicate(true)
	recorded["_observed_clock"] = player.input_router.clock
	started.append(recorded)
	var trace := {"action": action.get("id", ""), "frame": Engine.get_physics_frames(), "clock": player.input_router.clock, "energy": player.resources.current("Energy"), "stamina": player.resources.current("Stamina")}
	if action.get("is_skill", false) and not last_skill_request.is_empty():
		trace["input_to_start_frames"] = Engine.get_physics_frames() - int(last_skill_request.frame)
		trace["input_phase"] = last_skill_request.phase
		trace["input_state"] = last_skill_request.state
	print("ACTION_TRACE ", JSON.stringify(trace))

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(3)
	if not is_instance_valid(arena.get("player")) or not is_instance_valid(arena.get("ui")):
		printerr("COMBAT_FEEL: arena initialization failed")
		quit(1)
		return
	player = arena.player
	player.combat.runner.action_started.connect(record_action)
	player.input_router.command.connect(func(kind: String): semantics.append(kind))
	await check_skills_during_attacks()
	await check_buffer_cleanup()
	await check_queue_revalidation_and_skill_chain()
	await check_charging()
	for code in KEYS:
		key(code, false)
	mouse(MOUSE_BUTTON_LEFT, false)
	mouse(MOUSE_BUTTON_RIGHT, false)
	print("COMBAT_FEEL: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures:
		printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)

func check_skills_during_attacks() -> void:
	await prepare()
	await tap_mouse()
	verify(await wait_phase("RECOVERY"), "ordinary primary reaches recovery before secondary input")
	var primary_end: float = float(started[0]._observed_clock) + float(started[0].startup) + float(started[0].active) + float(started[0].recovery)
	await tap_mouse(MOUSE_BUTTON_RIGHT)
	await ticks(12)
	verify(started.size() == 2 and started[1].semantic == "SECONDARY_TAP", "real right click during primary recovery launches the secondary action")
	verify(started.size() == 2 and float(started[1]._observed_clock) < primary_end - .05, "secondary consumes the ordinary combo window before full recovery ends")
	await ticks(65)
	verify(started.size() == 2, "secondary recovery input is consumed once without ghost replay")
	for entry in [[KEY_Q, "warrior_whirlwind", 1], [KEY_E, "warrior_thrust", 0], [KEY_R, "warrior_sword_wave", 2]]:
		await prepare()
		await tap_mouse()
		verify(await wait_phase("ACTIVE"), "ordinary attack reaches ACTIVE before %s input" % entry[1])
		await tap_key(entry[0])
		await ticks(12)
		verify(started.size() == 2 and started[1].id == entry[1], "%s pressed during ordinary ACTIVE starts at next legal handoff" % entry[1])
		near(player.resources.current("Energy"), 60 - entry[2] * 20, "queued skill pays its declared Energy cost once")
		await ticks(90)
		verify(started.size() == 2, "single skill input cannot replay after recovery")
	for code in [KEY_Q, KEY_E, KEY_R]:
		await prepare()
		await tap_mouse()
		verify(await wait_phase("RECOVERY"), "ordinary attack reaches RECOVERY for QER handoff")
		await tap_key(code)
		await ticks(2)
		verify(started.size() == 2 and started[1].get("is_skill", false), "skill pressed in ordinary recovery responds within four frames")
	await prepare()
	await tap_mouse()
	await wait_phase("ACTIVE")
	await tap_key(KEY_Q)
	await ticks(12)
	await tap_key(KEY_Q)
	await ticks(75)
	verify(started.size() == 2, "repeated Q while skill cools down cannot pay or launch again")
	near(player.resources.current("Energy"), 40, "cooldown rejection preserves the single original payment")
	await prepare()
	player.resources.change("Energy", -60)
	await tap_mouse()
	await wait_phase("ACTIVE")
	await tap_key(KEY_Q)
	await ticks(50)
	verify(started.size() == 1 and not player.combat.cooldowns.has("warrior_whirlwind"), "queued skill with insufficient Energy starts neither action nor cooldown")
	player.resources.restore_all()
	await ticks(30)
	verify(started.size() == 1, "failed queued input does not revive after resources are restored")
	await prepare()
	await tap_mouse()
	await wait_phase("ACTIVE")
	await tap_key(KEY_Q)
	await tap_key(KEY_R)
	await ticks(20)
	verify(started.size() == 2 and started[1].id == "warrior_sword_wave", "latest skill request replaces older queued skill before recovery")
	near(player.resources.current("Energy"), 20, "replaced skill request never pays its obsolete Energy cost")
	await prepare()
	player.combat.engage()
	await tap_mouse()
	await wait_phase("ACTIVE")
	await tap_key(KEY_Q)
	await tap_key(KEY_SPACE)
	await ticks(32)
	verify(started.size() == 1, "dodge takes priority over a queued follow-up skill")
	near(player.resources.current("Energy"), 60, "dodge priority removes pending skill without paying it")
	near(player.resources.current("Stamina"), 2, "buffered combat dodge pays its own stamina exactly once")

func check_buffer_cleanup() -> void:
	await prepare()
	var id := "single_blade_primary_tap_1"
	var original: Dictionary = arena.database.actions[id].duplicate(true)
	# Delay the safe handoff beyond any normal input grace period using test data.
	arena.database.actions[id]["startup"] = 1.2
	await tap_mouse()
	await tap_key(KEY_Q)
	await ticks(120)
	verify(started.size() == 1, "early skill input expires before a distant recovery window")
	near(player.resources.current("Energy"), 60, "expired skill input consumes no resource")
	arena.database.actions[id] = original
	arena.database._index_actions()
	for cleanup in ["hitstun", "death", "menu"]:
		await prepare()
		await tap_mouse()
		await wait_phase("ACTIVE")
		await tap_key(KEY_Q)
		if cleanup == "menu":
			await tap_key(KEY_X)
		else:
			var packet := {"formula": {"base": 5000 if cleanup == "death" else 1}, "can_crit": false, "poise_damage": 999}
			player.combat.receive_damage(packet, arena.enemies[0], Vector3.BACK)
		await ticks(65)
		if cleanup == "menu":
			await tap_key(KEY_X)
			await ticks(20)
		verify(started.size() == 1, cleanup + " clears queued skill before it can launch")
		near(player.resources.current("Energy"), 60, cleanup + " cannot charge the cancelled queued skill")

func check_charging() -> void:
	await prepare()
	mouse(MOUSE_BUTTON_LEFT, true)
	await ticks(3)
	verify(player.combat.state == "CHARGING" and player.combat.charge_button == "PRIMARY", "mouse press immediately enters primary charging before release")
	verify(not player.combat.charge_action.is_empty() and player.combat.charge_progress() > 0, "charge action and progress are observable while button remains held")
	verify(player.animation.current_animation == "charging", "held button shows the character wind-up pose immediately")
	verify(not arena.ui.charge_indicator_visible and not player.animation._charge_aura.visible and not player.animation._charge_spark.visible, "held charge uses its pose without a progress bar or charge aura")
	for i in range(80):
		if player.combat.charge_ready:
			break
		await ticks(1)
	verify(player.combat.charge_ready and player.combat.charge_progress() >= .99, "continued hold reaches full charge")
	verify(player.animation.current_animation == "charge_ready", "full charge has a distinct ready visual state")
	verify(not player.animation.precision_glow_active and player.animation.body_flash_remaining <= 0.0, "full charge alone produces no precision glow or white flash")
	await ticks(12)
	verify(not player.animation.precision_glow_active and player.animation.body_flash_remaining <= 0.0 and player.combat.charge_ready, "full charge remains ready without a white glow")
	verify(started.is_empty(), "holding charge never releases a damaging action automatically")
	near(player.resources.current("Stamina"), 3, "holding charge does not spend stamina before release")
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(2)
	verify(started.size() == 1 and started[0].semantic == "PRIMARY_CHARGE", "full-charge release starts exactly one charged action")
	near(player.resources.current("Stamina"), 2, "charged release pays stamina exactly once")
	await ticks(60)
	verify(started.size() == 1 and semantics.count("PRIMARY_TAP") == 0, "long hold cannot emit an extra tap or replay after recovery")
	verify(not arena.ui.charge_indicator_visible and not player.animation._charge_aura.visible, "released charge leaves no progress bar or persistent aura")
	await prepare()
	mouse(MOUSE_BUTTON_RIGHT, true)
	await ticks(3)
	verify(player.combat.state == "CHARGING" and player.combat.charge_button == "SECONDARY", "right press also enters charging feedback immediately")
	await ticks(69)
	mouse(MOUSE_BUTTON_RIGHT, false)
	await ticks(2)
	verify(started.size() == 1 and started[0].semantic == "SECONDARY_CHARGE", "right full hold releases special charge once")
	await prepare()
	var start: Vector3 = player.global_position
	key(KEY_W, true)
	await ticks(15)
	key(KEY_W, false)
	var normal_distance: float = player.global_position.distance_to(start)
	await prepare()
	mouse(MOUSE_BUTTON_LEFT, true)
	await ticks(2)
	start = player.global_position
	key(KEY_W, true)
	await ticks(15)
	key(KEY_W, false)
	var charge_distance: float = player.global_position.distance_to(start)
	verify(normal_distance > .8 and charge_distance > .02 and charge_distance < normal_distance * .5, "single-blade charge allows only slow movement while held")
	await prepare("barbarian")
	mouse(MOUSE_BUTTON_LEFT, true)
	await ticks(2)
	start = player.global_position
	key(KEY_W, true)
	await ticks(20)
	key(KEY_W, false)
	near(player.global_position.distance_to(start), 0, "heavy two-handed charge roots movement while held", .03)
	await prepare()
	var enemy: Node = arena.enemies[0]
	enemy.global_position = player.global_position + Vector3.FORWARD * 2
	var hp: float = enemy.resources.current("HP")
	mouse(MOUSE_BUTTON_LEFT, true)
	await ticks(20)
	verify(not player.combat.charge_ready, "partial hold crosses tap threshold before full charge")
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(55)
	verify(enemy.resources.current("HP") < hp, "partial charged release still damages an enemy")
	var partial_raw: float = enemy.combat.last_damage.get("raw", 0)
	await prepare()
	enemy.global_position = player.global_position + Vector3.FORWARD * 2
	mouse(MOUSE_BUTTON_LEFT, true)
	await ticks(72)
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(55)
	var full_raw: float = enemy.combat.last_damage.get("raw", 0)
	verify(partial_raw > 0 and full_raw > partial_raw, "full hold has more actual attack power than early charged release")
	for failure in ["cooldown", "resource"]:
		await prepare()
		if failure == "cooldown":
			player.combat.cooldowns["warrior_whirlwind"] = 10
		else:
			player.resources.change("Energy", -60)
		mouse(MOUSE_BUTTON_LEFT, true)
		await ticks(20)
		var previous_time: float = player.combat.charge_time
		await tap_key(KEY_Q)
		verify(player.combat.state == "CHARGING" and player.combat.charge_time >= previous_time, failure + "-invalid skill does not destroy held charge")
		mouse(MOUSE_BUTTON_LEFT, false)
		await ticks(3)
		verify(started.size() == 1 and started[0].semantic == "PRIMARY_CHARGE", "charge still releases normally after rejected " + failure + " skill")
	for cancellation in ["hitstun", "death", "menu", "dodge", "skill", "focus"]:
		await prepare()
		mouse(MOUSE_BUTTON_LEFT, true)
		await ticks(20)
		match cancellation:
			"menu": await tap_key(KEY_X)
			"dodge": await tap_key(KEY_SPACE)
			"skill": await tap_key(KEY_Q)
			"focus": arena.get_window().focus_exited.emit()
			_:
				player.combat.receive_damage({"formula": {"base": 5000 if cancellation == "death" else 1}, "can_crit": false, "poise_damage": 999}, arena.enemies[0], Vector3.BACK)
		await ticks(2)
		verify(player.combat.state != "CHARGING", cancellation + " ends charging immediately")
		verify(player.combat.charge_action.is_empty() and player.input_router.held.is_empty(), cancellation + " clears charge action and held-button state")
		verify(not arena.ui.charge_indicator_visible, cancellation + " leaves no charge progress overlay")
		mouse(MOUSE_BUTTON_LEFT, false)
		await ticks(65)
		if cancellation == "menu":
			await tap_key(KEY_X)
			await ticks(15)
		var expected_actions := 1 if cancellation == "skill" else 0
		verify(started.size() == expected_actions, cancellation + " followed by mouse release cannot emit a ghost attack")
		if cancellation == "skill":
			verify(started[0].id == "warrior_whirlwind", "valid Q interrupts charge into requested skill")
			near(player.resources.current("Energy"), 40, "charge-to-skill handoff pays skill exactly once")

func check_queue_revalidation_and_skill_chain() -> void:
	await prepare()
	await tap_mouse()
	await wait_phase("ACTIVE")
	await tap_key(KEY_Q)
	verify(player.combat.queued_command.get("action_id", "") == "warrior_whirlwind", "valid skill is queued before its resource changes")
	player.resources.change("Energy", -60)
	verify(await wait_phase("RECOVERY", 15), "original attack reaches its own recovery after queued skill becomes unaffordable")
	verify(started.size() == 1 and player.combat.runner.current_action.get("id", "") == "single_blade_primary_tap_1", "resource revalidation preserves original attack instead of cancelling it")
	verify(player.combat.queued_command.is_empty() and not player.combat.cooldowns.has("warrior_whirlwind"), "resource-invalid queued request clears without cooldown")
	near(player.resources.current("Energy"), 0, "queue revalidation makes no extra resource payment")
	await ticks(35)
	player.resources.restore_all()
	await ticks(20)
	verify(started.size() == 1, "invalidated queue cannot reappear when resources later recover")
	await prepare()
	player.loadout.set_level(2)
	player.loadout.select_career("duelist")
	player.loadout.equip_weapon(0, "hunter_dagger")
	player.loadout.assign_skill(0, 0, "duelist_finisher")
	var enemy: Node = arena.enemies[0]
	enemy.global_position = player.global_position + Vector3.FORWARD * 2
	enemy.resources.change("HP", -enemy.resources.max_value("HP") * .75)
	arena.locked_target = enemy
	await tap_mouse()
	await wait_phase("ACTIVE")
	await tap_key(KEY_Q)
	verify(player.combat.queued_command.get("action_id", "") == "duelist_finisher", "low-HP target initially permits execution to queue")
	enemy.resources.change("HP", enemy.resources.max_value("HP"))
	verify(await wait_phase("RECOVERY", 15), "original dagger attack retains recovery when execution target heals")
	verify(started.size() == 1 and player.combat.runner.current_action.get("id", "") == "short_weapon_primary_tap_1", "target condition is rechecked before cancelling current attack")
	near(player.resources.current("Energy"), 60, "target-invalid execution never pays Energy")
	verify(not player.combat.cooldowns.has("duelist_finisher") and player.combat.queued_command.is_empty(), "target-invalid execution clears request without starting cooldown")
	await prepare()
	var original_impact: Dictionary = arena.database.skills.warrior_impact.duplicate(true)
	arena.database.skills.warrior_impact["cooldown"] = 0
	player.loadout.assign_skill(0, 1, "warrior_impact")
	await tap_key(KEY_Q)
	verify(await wait_phase("ACTIVE"), "first Q skill reaches ACTIVE before chaining another skill")
	await tap_key(KEY_E)
	verify(started.size() == 1 and player.combat.runner.current_action.get("id", "") == "warrior_whirlwind", "second skill cannot cancel first skill ACTIVE phase")
	verify(player.combat.queued_command.get("action_id", "") == "warrior_impact", "second skill waits in bounded queue")
	verify(await wait_phase("RECOVERY", 20), "first skill enters its own recovery before chain can start")
	verify(started.size() == 1, "skill chain cannot cancel the beginning of long recovery")
	await ticks(20)
	verify(started.size() == 2 and started[1].id == "warrior_impact", "second skill launches once the final skill-chain window opens")
	if started.size() == 2:
		var first_duration := float(started[0].startup) + float(started[0].active) + float(started[0].recovery)
		var elapsed := float(started[1]._observed_clock) - float(started[0]._observed_clock)
		verify(elapsed >= first_duration - .12 - .017 and elapsed <= first_duration + .017, "skill chain starts within final 0.12 seconds rather than arbitrary action cancellation (%.3fs / %.3fs)" % [elapsed, first_duration])
	near(player.resources.current("Energy"), 20, "two chained skills each pay their own Energy cost once")
	await ticks(90)
	verify(started.size() == 2 and player.combat.queued_command.is_empty(), "even a zero-cooldown chained skill cannot consume the same input twice")
	near(player.resources.current("Energy"), 20, "zero-cooldown follow-up is not repeatedly charged after recovery")
	arena.database.skills.warrior_impact = original_impact
