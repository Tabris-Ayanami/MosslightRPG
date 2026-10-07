extends SceneTree
## Physical key and mouse events exercise the live InputMap/router. Enemy hits
## are real AttackInstance nodes. Exact endpoint checks also call resolve.
## Godot --headless --path . --fixed-fps 60 --script tests/combat_defense.gd

const Attack = preload("res://combat/attack_instance.gd")
const ORIGIN := Vector3(0, .1, 6)
var arena: Node
var player: Node
var foe: Node
var checks := 0
var failures: Array[String] = []
var started: Array[Dictionary] = []

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
	Input.parse_input_event(event)

func mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = Vector2(640, 300)
	event.global_position = event.position
	event.pressed = pressed
	Input.parse_input_event(event)

func tap(code: Key) -> void:
	key(code, true)
	await ticks(1)
	key(code, false)
	await ticks(1)

func click(button := MOUSE_BUTTON_LEFT) -> void:
	mouse(button, true)
	await ticks(2)
	mouse(button, false)
	await ticks(2)

func prepare(career := "soldier") -> void:
	for code in [KEY_CTRL, KEY_W, KEY_SPACE, KEY_Q, KEY_E, KEY_R, KEY_X]:
		key(code, false)
	mouse(MOUSE_BUTTON_LEFT, false)
	mouse(MOUSE_BUTTON_RIGHT, false)
	for action in InputMap.get_actions():
		Input.action_release(action)
	for effect in arena.effects.get_children():
		effect.queue_free()
	arena.warnings.clear()
	player.loadout.select_career("warrior" if career == "soldier" else career)
	if career == "soldier":
		player.loadout.set_level(2)
		player.loadout.select_career("soldier")
	player.combat.reset()
	player.global_position = ORIGIN
	player.velocity = Vector3.ZERO
	player.facing = Vector3.FORWARD
	arena.aim_point = ORIGIN + Vector3.FORWARD * 10
	arena.aim_override = arena.aim_point
	arena.locked_target = null
	arena.ui.toggle_menu(false)
	arena.input_blocked = false
	arena.pointer_blocked = false
	for enemy in arena.enemies:
		enemy.ai_enabled = false
		enemy.combat.reset()
		enemy.global_position = Vector3(18, .1, 18)
	foe = arena.enemies[0]
	foe.global_position = ORIGIN + Vector3.FORWARD * 1.8
	foe.facing = Vector3.BACK
	var pointer := InputEventMouseMotion.new()
	pointer.position = Vector2(640, 300)
	pointer.global_position = pointer.position
	Input.parse_input_event(pointer)
	await ticks(3)
	started.clear()

func packet(overrides: Dictionary = {}) -> Dictionary:
	var action := {"id": "defense_test_hit", "formula": {"base": 100}, "can_crit": false,
		"damage_type": "PHYSICAL", "targeting": "CONE", "range": 3.0, "angle": 90,
		"active": .1, "poise_damage": 40, "knockback_force": 0, "effects": []}
	action.merge(overrides, true)
	return action

func impact(overrides: Dictionary = {}, offset := Vector3(0, 0, -1.8)) -> void:
	foe.global_position = player.global_position + offset
	foe.facing = -offset.normalized()
	var attack: Node3D = Attack.new()
	attack.arena = arena
	attack.source = foe
	attack.action = packet(overrides)
	attack.origin = foe.global_position
	attack.direction = foe.facing
	attack.aim_point = player.global_position
	attack.target = player
	arena.effects.add_child(attack)

func raise_guard(frames := 2) -> void:
	key(KEY_CTRL, true)
	await ticks(frames)

func prepare_fujian() -> void:
	await prepare("warrior")
	player.loadout.set_level(2)
	player.loadout.select_career("duelist")
	started.clear()

func wait_action_time(time: float) -> void:
	for i in range(160):
		if not player.combat.runner.busy() or player.combat.runner.action_time >= time:
			return
		await ticks(1)

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(3)
	if not is_instance_valid(arena.get("player")) or not is_instance_valid(arena.get("ui")):
		printerr("COMBAT_DEFENSE: arena initialization failed")
		quit(1)
		return
	player = arena.player
	player.combat.runner.action_started.connect(func(action: Dictionary): started.append(action.duplicate(true)))
	verify(InputMap.has_action("guard"), "guard is wired into InputMap")
	await check_shield_guard()
	await check_precision_and_direction()
	await check_action_guard()
	await check_fujian()
	await check_hyper_armor_and_grab()
	await check_grab_lifecycle_and_guard_resume()
	await check_ogre_ai_grab_reach()
	await check_window_boundaries()
	for action in InputMap.get_actions():
		Input.action_release(action)
	print("COMBAT_DEFENSE: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures:
		printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)

func check_shield_guard() -> void:
	await prepare()
	await raise_guard(20)
	verify(player.combat.state == "GUARD" and player.combat.defense.guard_held, "physical Ctrl hold raises equipped shield")
	var hp: float = player.resources.current("HP")
	impact({"effects": [{"type": "status", "status": "burn", "duration": 3}]})
	verify(player.combat.defense.last_outcome == "block", "late frontal hit uses ordinary shield block")
	near(player.resources.current("HP"), hp, "wood shield blocks all physical HP damage")
	near(player.resources.current("Stamina"), 2, "ordinary block pays one stamina")
	near(player.combat.current_poise, player.combat.max_poise(), "block prevents incoming poise damage")
	verify(not player.combat.statuses.has_status("burn"), "block suppresses incoming status effects")
	impact()
	near(player.resources.current("Stamina"), 1, "second ordinary block costs exactly one more stamina")
	impact()
	verify(player.combat.defense.last_outcome == "guard_break" and player.combat.state == "GUARD_BROKEN", "hit consuming final stamina breaks guard")
	near(player.resources.current("Stamina"), 0, "guard break never drives stamina negative")
	near(player.resources.current("HP"), hp - 100, "guard-breaking hit deals full physical damage")
	verify(not player.combat.defense.guard_held, "guard break clears held defense intent")
	await ticks(55)
	verify(player.combat.state in ["NORMAL", "MOVE"], "guard-break control expires after its recovery")
	await prepare()
	await raise_guard(20)
	hp = player.resources.current("HP")
	impact({"damage_type": "FIRE"})
	near(player.resources.current("HP"), hp - 50, "wood shield reduces elemental damage by half")
	key(KEY_CTRL, false)
	await ticks(2)
	verify(player.combat.state == "NORMAL" and not player.combat.defense.guard_held, "Ctrl release lowers the shield")
	await prepare()
	player.loadout.equip_weapon(1, "buckler")
	await raise_guard(20)
	hp = player.resources.current("HP")
	impact()
	near(player.resources.current("HP"), hp - 15, "buckler leaves fifteen percent physical chip damage")
	await prepare()
	key(KEY_W, true)
	await ticks(15)
	var normal_distance: float = player.global_position.distance_to(ORIGIN)
	await prepare()
	await raise_guard(20)
	key(KEY_W, true)
	await ticks(15)
	var guard_distance: float = player.global_position.distance_to(ORIGIN)
	verify(guard_distance > .1 and guard_distance < normal_distance * .5, "held shield permits only its reduced movement speed")
	await prepare("barbarian")
	await raise_guard()
	verify(player.combat.state != "GUARD", "two-handed weapon cannot raise an incompatible shield")
	await prepare()
	await raise_guard(20)
	impact({"poise_damage": 41})
	near(player.resources.current("Stamina"), 1, "ordinary guard rounds forty-one poise damage up to two stamina")
	await prepare()
	await raise_guard(20)
	impact({"poise_damage": 400, "guard_damage": 1})
	near(player.resources.current("Stamina"), 2, "explicit guard damage overrides poise-derived guard cost")
	await prepare()
	player.resources.configure("Stamina", 0)
	await raise_guard(20)
	impact()
	verify(player.combat.state == "GUARD_BROKEN", "present zero-capacity stamina pool remains finite and cannot block freely")
	for rule in ["unlimited", "missing_pool"]:
		await prepare()
		if rule == "unlimited":
			player.resources.unlimited["Stamina"] = true
		else:
			player.resources.pools.erase("Stamina")
		await raise_guard(20)
		impact({"poise_damage": 400})
		verify(player.combat.defense.last_outcome == "block", rule + " stamina permits guard without false break")
		if rule == "unlimited":
			near(player.resources.current("Stamina"), 3, "unlimited guard does not spend a finite pool")
	await prepare()
	await raise_guard()
	await tap(KEY_X)
	verify(player.combat.state != "GUARD" and not player.combat.defense.guard_held, "opening menu clears held guard")
	await tap(KEY_X)
	await ticks(3)
	verify(player.combat.state != "GUARD", "closing menu does not resurrect an uncleared Ctrl hold")
	await prepare()
	await raise_guard()
	arena.get_window().focus_exited.emit()
	await ticks(2)
	verify(player.combat.state != "GUARD" and not player.combat.defense.guard_held, "losing focus clears defense intent")

func check_precision_and_direction() -> void:
	await prepare()
	await raise_guard()
	impact()
	verify(player.combat.defense.last_outcome == "parry", "fresh Ctrl raise precisely defends a frontal hit")
	near(player.resources.current("Stamina"), 3, "precise defense pays no stamina")
	verify(foe.combat.state == "EXPOSED", "melee precise defense exposes the attacker")
	verify(started.is_empty(), "precise defense does not launch an automatic counter attack")
	impact()
	verify(player.combat.defense.last_outcome == "block", "one shield raise cannot precisely defend repeated hits")
	key(KEY_CTRL, false)
	await ticks(1)
	await raise_guard()
	impact()
	verify(player.combat.defense.last_outcome == "block", "rapid shield re-raise cannot refresh precision before cooldown")
	key(KEY_CTRL, false)
	await ticks(30)
	await raise_guard()
	impact()
	verify(player.combat.defense.last_outcome == "parry", "a fresh raise regains precision after the anti-spam cooldown")
	await prepare()
	for enemy in arena.enemies:
		if enemy.is_boss:
			foe = enemy
			break
	await raise_guard()
	impact()
	verify(foe.is_boss and foe.combat.state == "EXPOSED", "precise defense can expose the actual boss actor")
	near(foe.combat.control_time, .55, "boss exposure has its shorter control duration")
	near(float(foe.combat.target_data().vulnerability.get("ALL", 0)), .25, "exposed boss takes the configured quarter extra incoming damage")
	await prepare()
	await raise_guard(20)
	impact()
	await click()
	verify(started.size() == 1 and started[0].id == "guard_riposte", "left mouse within ordinary shield-block opportunity starts riposte")
	await ticks(15)
	verify(foe.resources.current("HP") < foe.resources.max_value("HP"), "riposte produces a real damaging attack instance")
	await prepare()
	await raise_guard()
	impact({"projectile_speed": 40, "range": 6})
	await ticks(3)
	verify(player.combat.defense.last_outcome == "parry", "front projectile can be precisely defended")
	verify(foe.combat.state != "EXPOSED", "projectile precision does not interrupt its distant caster")
	for offset in [Vector3(1.8, 0, 0), Vector3(0, 0, 1.8)]:
		await prepare()
		await raise_guard()
		var hp: float = player.resources.current("HP")
		impact({}, offset)
		verify(player.combat.defense.last_outcome == "none", "side or rear attacks bypass the forward guard cone")
		near(player.resources.current("HP"), hp - 100, "outside-angle hit retains full physical damage")
	await prepare()
	await raise_guard()
	var hp: float = player.resources.current("HP")
	impact({"blockable": false})
	near(player.resources.current("HP"), hp - 100, "explicit unblockable attack bypasses fresh shield precision")
	await prepare()
	await raise_guard()
	hp = player.resources.current("HP")
	player.combat.receive_damage(packet(), foe, Vector3.BACK, true)
	near(player.resources.current("HP"), hp - 100, "periodic damage bypasses guard and precision")
	await prepare()
	player.combat.defense.start_guard(false)
	impact()
	verify(player.combat.defense.last_outcome == "block", "AI-style guard raise never grants a precision window")

func check_action_guard() -> void:
	await prepare("warrior")
	await click(MOUSE_BUTTON_RIGHT)
	verify(started.size() == 1 and started[0].semantic == "SECONDARY_TAP", "real right mouse starts the guard-point weapon attack")
	var id: String = player.combat.runner.current_action.get("instance_id", "")
	var hp: float = player.resources.current("HP")
	impact()
	verify(player.combat.defense.last_outcome == "parry", "weapon startup guard point has its own precise window")
	impact()
	verify(player.combat.defense.last_outcome == "block", "action precision is consumed once per action instance")
	near(player.resources.current("HP"), hp - 20, "action guard keeps its configured physical chip damage")
	verify(player.combat.runner.current_action.get("instance_id", "") == id, "successful action guard preserves the original attack")
	await ticks(20)
	verify(foe.resources.current("HP") < foe.resources.max_value("HP"), "guard-point attack still reaches active damage after defending")
	await prepare("warrior")
	await click(MOUSE_BUTTON_RIGHT)
	await wait_action_time(.23)
	hp = player.resources.current("HP")
	impact({"poise_damage": 0})
	near(player.resources.current("HP"), hp - 100, "weapon guard point expires after its declared endpoint")
	await prepare("warrior")
	await click(MOUSE_BUTTON_RIGHT)
	await wait_action_time(.14)
	player.resources.change("Stamina", -3)
	impact()
	verify(player.combat.state == "GUARD_BROKEN", "ordinary action guard fails when its stamina cannot cover a hit")

func check_fujian() -> void:
	await prepare_fujian()
	await tap(KEY_R)
	verify(started.size() == 1 and started[0].id == "duelist_fujian", "duelist R enters the real counter stance")
	near(player.resources.current("Energy"), player.resources.max_value("Energy") - 20, "counter stance pays twenty Energy at activation")
	await wait_action_time(.4)
	var hp: float = player.resources.current("HP")
	impact()
	verify(player.combat.defense.last_outcome == "counter", "attack in active stance consumes the counter opportunity")
	near(player.resources.current("HP"), hp, "successful counter negates the triggering attack")
	verify(started.size() == 2 and started[1].id == "fujian_counter", "counter immediately starts the separate reaction action")
	impact({"poise_damage": 0})
	near(player.resources.current("HP"), hp - 100, "same stance cannot negate a second incoming hit")
	await ticks(20)
	verify(started.size() == 2, "one counter stance cannot launch repeated automatic reactions")
	verify(foe.resources.current("HP") < foe.resources.max_value("HP"), "automatic counter deals real outgoing damage")
	for time in [.1, 1.8]:
		await prepare_fujian()
		await tap(KEY_R)
		await wait_action_time(time)
		hp = player.resources.current("HP")
		impact({"poise_damage": 0})
		verify(player.combat.defense.last_outcome == "none", "counter fails outside its preparation and expiration boundaries")
		near(player.resources.current("HP"), hp - 100, "out-of-window counter takes the incoming damage")
		verify(started.size() == 1, "out-of-window counter does not start a reaction")
	await prepare_fujian()
	await tap(KEY_R)
	await wait_action_time(.4)
	impact({}, Vector3(0, 0, 1.8))
	verify(player.combat.defense.last_outcome == "counter", "full-circle counter stance also accepts attacks from behind")
	await prepare_fujian()
	player.resources.change("Energy", -player.resources.current("Energy"))
	await tap(KEY_R)
	verify(started.is_empty() and player.combat.can_start(), "insufficient Energy rejects counter stance before entering its window")
	await prepare_fujian()
	await tap(KEY_R)
	await wait_action_time(.4)
	hp = player.resources.current("HP")
	player.combat.receive_damage(packet({"poise_damage": 0}), foe, Vector3.BACK, true)
	near(player.resources.current("HP"), hp - 100, "DOT does not trigger counter stance")
	impact()
	verify(player.combat.defense.last_outcome == "counter", "bypassed DOT does not consume the next-attack counter opportunity")

func check_hyper_armor_and_grab() -> void:
	await prepare("barbarian")
	mouse(MOUSE_BUTTON_LEFT, true)
	await ticks(60)
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(2)
	verify(player.combat.defense.has_hyper_armor(), "released heavy charged attack enters its actual hyper-armor window")
	var hp: float = player.resources.current("HP")
	impact({"poise_damage": 999})
	near(player.resources.current("HP"), hp - 100, "hyper armor never prevents HP damage")
	verify(player.combat.state == "ACTION" and player.combat.runner.busy(), "hyper armor prevents ordinary poise break from cancelling the attack")
	var grab: Dictionary = arena.database.enemies.ogre.grab_action.duplicate(true)
	grab.erase("formula")
	grab["formula"] = {"base": 100}
	for mode in ["guard", "counter", "hyper_armor", "dodge"]:
		if mode == "counter":
			await prepare_fujian()
			await tap(KEY_R)
			await wait_action_time(.4)
		elif mode == "hyper_armor":
			await prepare("barbarian")
			mouse(MOUSE_BUTTON_LEFT, true)
			await ticks(60)
			mouse(MOUSE_BUTTON_LEFT, false)
			await ticks(2)
		else:
			await prepare()
			if mode == "guard":
				await raise_guard()
			else:
				player.combat.engage()
				await tap(KEY_SPACE)
		hp = player.resources.current("HP")
		impact(grab)
		if mode == "dodge":
			near(player.resources.current("HP"), hp, "dodge invulnerability avoids otherwise unblockable grab")
			verify(player.combat.state == "DODGE", "avoided grab never forces captured state")
		else:
			near(player.resources.current("HP"), hp - 100, "grab bypasses " + mode + " HP protection")
			verify(player.combat.state == "GRABBED", "grab forces captured state through " + mode)

func check_grab_lifecycle_and_guard_resume() -> void:
	var grab: Dictionary = arena.database.enemies.ogre.grab_action.duplicate(true)
	grab["formula"] = {"base": 100}
	grab["grab_duration"] = .3
	await prepare()
	impact(grab)
	verify(player.combat.state == "GRABBED" and foe.combat.state == "GRABBING", "real grab pairs captured victim with holding attacker")
	await ticks(21)
	verify(player.combat.state == "KNOCKDOWN" and foe.combat.state == "NORMAL", "grab duration releases attacker and throws victim into knockdown")
	verify(player.combat.grab_source == null and foe.combat.grab_target == null, "timed grab release clears both weak references")
	await ticks(42)
	verify(player.combat.state == "NORMAL", "thrown victim returns to normal after knockdown recovery")
	for ending in ["death", "removed"]:
		await prepare()
		if ending == "removed":
			foe = arena.spawn_enemy("soldier", ORIGIN + Vector3.FORWARD * 2)
			foe.ai_enabled = false
		impact(grab)
		if ending == "death":
			foe.resources.change("HP", -foe.resources.current("HP"))
		else:
			arena.enemies.erase(foe)
			foe.queue_free()
		await ticks(3)
		verify(player.combat.state == "KNOCKDOWN" and player.combat.grab_source == null, "grab source " + ending + " immediately releases its victim")
		await ticks(42)
		verify(player.combat.state == "NORMAL", "source " + ending + " leaves no permanent captured state")
	for following in ["skill", "riposte"]:
		await prepare()
		await raise_guard(20)
		if following == "skill":
			await tap(KEY_Q)
		else:
			impact()
			await click()
		verify(started.size() == 1 and player.combat.runner.busy(), "held Ctrl permits a requested " + following + " action")
		for i in range(120):
			if player.combat.state == "GUARD":
				break
			await ticks(1)
		verify(player.combat.state == "GUARD" and player.combat.defense.guard_held, "held Ctrl restores shield after " + following + " finishes")
		impact()
		verify(player.combat.defense.last_outcome == "block", "automatic guard after " + following + " does not grant a fresh precise window")

func check_ogre_ai_grab_reach() -> void:
	await prepare()
	var ogre: Node
	for enemy in arena.enemies:
		if enemy.enemy_id == "ogre":
			ogre = enemy
			break
	ogre.global_position = player.global_position + Vector3.FORWARD * 3.15
	ogre.facing = Vector3.BACK
	ogre.attacks_made = 2
	ogre.ai_cooldown = 0.0
	var initial_distance: float = ogre.global_position.distance_to(player.global_position)
	var hp: float = player.resources.current("HP")
	var ai_actions: Array[Dictionary] = []
	var observed_start := func(action: Dictionary):
		ai_actions.append({"id": action.get("id", ""), "kind": action.get("attack_kind", ""),
			"distance": ogre.global_position.distance_to(player.global_position), "frame": Engine.get_physics_frames()})
	ogre.combat.runner.action_started.connect(observed_start)
	verify(initial_distance > float(ogre.grab_action.range), "AI grab scenario begins outside grab range but inside ordinary strike reach")
	ogre.ai_enabled = true
	await ticks(6)
	verify(ogre.global_position.distance_to(player.global_position) < initial_distance - .05, "ogre AI approaches before attempting its third grab attack")
	verify(ai_actions.is_empty() and ogre.attacks_made == 2, "ogre AI does not spend its third attack on an out-of-range grab")
	for i in range(240):
		if player.combat.state == "GRABBED":
			break
		await ticks(1)
	verify(ai_actions.size() == 1 and ai_actions[0].kind == "GRAB" and ogre.attacks_made == 3, "actual AI selects grab for its third attack")
	verify(ai_actions.size() == 1 and float(ai_actions[0].distance) <= float(ogre.grab_action.range) * .8 + .04, "AI waits for the grab-specific engagement distance before starting")
	verify(player.combat.state == "GRABBED" and player.resources.current("HP") < hp, "AI-created grab instance actually damages and captures the stationary player")
	print("AI_GRAB_TRACE ", JSON.stringify({"initial_distance": initial_distance, "actions": ai_actions,
		"victim_state": player.combat.state, "damage": hp - player.resources.current("HP")}))
	ogre.ai_enabled = false
	ogre.combat.runner.action_started.disconnect(observed_start)

func check_window_boundaries() -> void:
	await prepare()
	await raise_guard()
	player.combat.defense.guard_time = .16
	var result: Dictionary = player.combat.defense.resolve(packet(), foe, Vector3.BACK)
	verify(result.outcome == "block", "shield perfect window excludes its exact endpoint")
	await prepare("warrior")
	await click(MOUSE_BUTTON_RIGHT)
	player.combat.runner.action_time = .12
	result = player.combat.defense.resolve(packet(), foe, Vector3.BACK)
	verify(result.outcome == "block", "action perfect window excludes its exact endpoint")
	player.combat.runner.action_time = .22
	result = player.combat.defense.resolve(packet(), foe, Vector3.BACK)
	verify(result.outcome == "none", "action guard excludes its exact endpoint")
	await prepare_fujian()
	await tap(KEY_R)
	player.combat.runner.action_time = .35
	result = player.combat.defense.resolve(packet(), foe, Vector3.BACK)
	verify(result.outcome == "counter", "counter stance includes its exact start")
	result = player.combat.defense.resolve(packet(), foe, Vector3.BACK)
	verify(result.outcome == "none", "counter opportunity is single-use even before reaction replaces its action")
	await prepare_fujian()
	await tap(KEY_R)
	player.combat.runner.action_time = 1.75
	result = player.combat.defense.resolve(packet(), foe, Vector3.BACK)
	verify(result.outcome == "none", "counter stance excludes its exact endpoint")
