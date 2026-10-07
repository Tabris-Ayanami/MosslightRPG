extends SceneTree
## Physical InputMap events exercise selection, release, cancellation, buffering,
## target validation and the catalog's actual geometry in the live arena.
const Preferences = preload("res://rpg/game_preferences.gd")
const ORIGIN := Vector3(0, .1, 6)
const POINTER := Vector2(640, 300)
var arena: Node
var player: Node
var checks := 0
var failures: Array[String] = []
var started: Array[Dictionary] = []

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
func mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = POINTER
	event.global_position = POINTER
	event.pressed = pressed
	Input.parse_input_event(event)
func tap(code: Key) -> void:
	key(code, true)
	await ticks(1)
	key(code, false)
	await ticks(1)
func click(button := MOUSE_BUTTON_LEFT) -> void:
	mouse(button, true)
	await ticks(1)
	mouse(button, false)
	await ticks(1)
func aim(direction: Vector3, distance := 5.0) -> void:
	arena.aim_override = player.global_position + direction * distance
	await ticks(1)
func record(action: Dictionary) -> void:
	var entry := action.duplicate(true)
	entry["observed_direction"] = player.combat.action_direction
	entry["observed_point"] = player.combat.action_point
	started.append(entry)
func prepare(career := "warrior") -> void:
	for code in [KEY_Q, KEY_E, KEY_R, KEY_SHIFT, KEY_SPACE, KEY_W]: key(code, false)
	for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]: mouse(button, false)
	arena.control.cancel_all()
	player.input_router.cancel()
	var definition: Dictionary = arena.database.careers[career]
	player.loadout.select_career(str(definition.get("base_career", career)))
	player.loadout.set_level(maxi(1, int(definition.get("required_level", 1))))
	if career != definition.get("base_career", career): player.loadout.select_career(career)
	player.combat.reset()
	player.global_position = ORIGIN
	player.velocity = Vector3.ZERO
	player.facing = Vector3.FORWARD
	arena.locked_target = null
	arena.aim_override = ORIGIN + Vector3.FORWARD * 5
	arena.input_blocked = false
	arena.pointer_blocked = false
	arena.ui.toggle_menu(false)
	Preferences.reset_cast_modes()
	for enemy in arena.enemies:
		enemy.set_physics_process(false)
		enemy.combat.reset()
		enemy.global_position = Vector3(18, .1, 18)
	var motion := InputEventMouseMotion.new()
	motion.position = POINTER
	motion.global_position = POINTER
	Input.parse_input_event(motion)
	await ticks(3)
	started.clear()
func skill_count() -> int:
	return started.filter(func(entry: Dictionary) -> bool: return entry.get("is_skill", false)).size()

func run() -> void:
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-casting-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(5)
	player = arena.player
	player.combat.runner.action_started.connect(record)
	await prepare()
	var before: float = player.resources.current("Energy")
	key(KEY_Q, true)
	await ticks(10)
	check(player.skill_casting.active() and player.skill_casting.indicator.visible and player.skill_casting.preview.valid, "quick key hold opens a valid visible selector")
	check(started.is_empty() and player.resources.current("Energy") == before and player.combat.cooldowns.is_empty(), "aiming spends no energy and starts no action or cooldown")
	check(player.skill_casting.preview.action.targeting == "CIRCLE" and is_equal_approx(player.skill_casting.preview.action.radius, 3), "self circle uses the actual whirlwind radius")
	key(KEY_Q, false)
	await ticks(1)
	check(skill_count() == 1 and not player.skill_casting.active() and not player.skill_casting.indicator.visible, "quick release commits exactly once and hides the preview")
	check(is_equal_approx(player.resources.current("Energy"), before - 20) and float(player.combat.cooldowns.get("warrior_whirlwind", 0)) > 4.9, "confirmation alone pays the actual skill energy and cooldown")
	await ticks(60)
	check(skill_count() == 1, "holding and releasing a skill never autorepeats")

	await prepare()
	key(KEY_E, true)
	await ticks(2)
	await aim(Vector3.RIGHT)
	check(player.skill_casting.preview.intent.direction.dot(Vector3.RIGHT) > .999, "held directional skill follows the current mouse aim")
	check(player.facing.dot(Vector3.FORWARD) > .999, "selection does not rotate the idle body away from WASD facing")
	key(KEY_E, false)
	await ticks(1)
	await aim(Vector3.LEFT)
	check(skill_count() == 1 and player.combat.action_direction.dot(Vector3.RIGHT) > .999, "release direction stays fixed when the mouse moves during startup")
	await ticks(30)
	check(player.global_position.x > ORIGIN.x + 2 and absf(player.global_position.z - ORIGIN.z) < .1, "the actual thrust movement executes in the confirmed direction")

	await prepare()
	Preferences.set_cast_mode("skill_q", "precise")
	await tap(KEY_Q)
	check(player.skill_casting.active() and started.is_empty(), "precise first press and release retain selection without casting")
	await tap(KEY_Q)
	check(skill_count() == 1 and not player.skill_casting.active(), "precise second same-key press commits one skill")
	await prepare()
	Preferences.set_cast_mode("skill_q", "precise")
	key(KEY_Q, true)
	await ticks(1)
	for i in range(3):
		var repeat := InputEventKey.new()
		repeat.physical_keycode = KEY_Q
		repeat.keycode = KEY_Q
		repeat.pressed = true
		repeat.echo = true
		Input.parse_input_event(repeat)
		await ticks(1)
	key(KEY_Q, false)
	await ticks(1)
	check(player.skill_casting.active() and skill_count() == 0, "keyboard autorepeat while holding precise Q cannot count as confirmation")
	await prepare()
	Preferences.set_cast_mode("skill_e", "precise")
	await tap(KEY_E)
	await aim(Vector3.LEFT)
	await click()
	check(skill_count() == 1 and started.size() == 1 and player.combat.action_direction.dot(Vector3.LEFT) > .999, "precise left-click confirmation does not leak a normal attack")
	await ticks(60)
	check(started.size() == 1 and player.input_router.held.is_empty(), "confirmation button release cannot enqueue a stray weapon action")

	await prepare("soldier")
	key(KEY_Q, true)
	await ticks(2)
	before = player.resources.current("Energy")
	await click(MOUSE_BUTTON_RIGHT)
	key(KEY_Q, false)
	await ticks(40)
	check(not player.skill_casting.active() and started.is_empty() and player.resources.current("Energy") == before, "right-click cancels held quick cast and its later key release is harmless")
	check(player.combat.state == "NORMAL" and not player.combat.guard_requested and not player.input_router.shield_held, "cast cancellation never also raises the equipped shield")
	await click(MOUSE_BUTTON_RIGHT)
	check(started.size() == 1 and started[0].id == "shield_raise", "a fresh right-click after cancellation still performs normal shield input")
	await prepare()
	Preferences.set_cast_mode("skill_q", "precise")
	await tap(KEY_Q)
	await click(MOUSE_BUTTON_RIGHT)
	await ticks(12)
	check(started.is_empty() and not player.skill_casting.active(), "right-click also cancels precise selection without a secondary attack")
	await tap(KEY_Q)
	check(player.skill_casting.active() and started.is_empty(), "cancelled precise selection starts fresh on the next key press")

	await prepare()
	key(KEY_Q, true)
	await ticks(1)
	mouse(MOUSE_BUTTON_RIGHT, true)
	key(KEY_Q, false)
	await ticks(1)
	mouse(MOUSE_BUTTON_RIGHT, false)
	await ticks(2)
	check(started.is_empty(), "same-frame right cancellation takes priority over quick release")
	await prepare()
	key(KEY_Q, true)
	await ticks(1)
	key(KEY_E, true)
	await ticks(1)
	key(KEY_Q, false)
	await ticks(1)
	check(player.skill_casting.slot == 1 and started.is_empty(), "another skill key replaces selection without releasing the abandoned slot")
	key(KEY_E, false)
	await ticks(1)
	check(skill_count() == 1 and started[0].id == "warrior_thrust", "only the currently selected replacement key can confirm")

	await prepare("mage")
	key(KEY_Q, true)
	await ticks(1)
	await aim(Vector3.RIGHT)
	check(player.skill_casting.preview.action.targeting == "DIRECTION" and player.skill_casting.indicator.vertices.size() > 100, "projectile selection draws a filled directional path")
	key(KEY_Q, false)
	await ticks(1)
	await aim(Vector3.LEFT)
	await ticks(12)
	var projectiles: Array = arena.effects.get_children().filter(func(node: Node) -> bool: return node.get("projectile") == true)
	check(not projectiles.is_empty() and projectiles[-1].direction.dot(Vector3.RIGHT) > .999, "actual projectile retains the released direction through startup")
	await prepare("mage")
	check(player.loadout.assign_skill(0, 0, "mage_earth_spike"), "catalog point/line spell can be prepared in the test slot")
	key(KEY_Q, true)
	await ticks(1)
	await aim(Vector3.RIGHT, 30)
	var selected_reach: float = player.skill_casting.preview.action.range
	check(player.skill_casting.preview.intent.point.distance_to(player.global_position) <= selected_reach + .01 and player.skill_casting.preview.action.length == 6, "ground skill clamps its center to effective casting reach while preserving line length")
	await aim(Vector3.RIGHT, 4)
	var selected_point: Vector3 = player.skill_casting.preview.intent.point
	var inline_unit: Node = arena.enemies[0]
	var outside_unit: Node = arena.enemies[1]
	inline_unit.global_position = selected_point + Vector3.RIGHT * 2.9
	outside_unit.global_position = selected_point + Vector3.FORWARD * 1.2
	var inside_hp: float = inline_unit.resources.current("HP")
	var outside_hp: float = outside_unit.resources.current("HP")
	key(KEY_Q, false)
	await ticks(1)
	await aim(Vector3.LEFT, 2)
	check(player.combat.action_point.distance_to(selected_point) < .01, "ground impact point is fixed at confirmation")
	check(is_equal_approx(player.combat.runner.current_action.range, selected_reach), "preview includes the same weapon/passive casting-range modifiers as execution")
	var spike: Dictionary = player.combat.runner.current_action
	check(CombatTargeting.contains("POINT", ORIGIN, Vector3.RIGHT, selected_point + Vector3.RIGHT * 2.9, spike, selected_point) and not CombatTargeting.contains("POINT", ORIGIN, Vector3.RIGHT, selected_point + Vector3.FORWARD * 1.1, spike, selected_point), "point/line actual hitbox matches its six-by-two preview instead of a circle")
	await ticks(15)
	check(inline_unit.resources.current("HP") < inside_hp and outside_unit.resources.current("HP") == outside_hp, "real ground-line damage hits its longitudinal edge and excludes a unit outside its width")

	await prepare("conjurer")
	check(player.loadout.assign_skill(0, 0, "conjurer_dreamwalk"), "targeted dreamwalk is selected from the real catalog")
	Preferences.set_cast_mode("skill_q", "precise")
	await tap(KEY_Q)
	before = player.resources.current("Energy")
	check(player.skill_casting.active() and not player.skill_casting.preview.valid, "targeted mode opens selection even before an eligible unit is hovered")
	await tap(KEY_Q)
	check(player.skill_casting.active() and started.is_empty() and player.resources.current("Energy") == before, "invalid precise confirmation retains selection and charges nothing")
	var boss: Node = arena.enemies.filter(func(unit: Node) -> bool: return unit.enemy_id == "ogre")[0]
	boss.global_position = player.global_position + Vector3.RIGHT * 3
	arena.aim_override = boss.global_position
	await ticks(1)
	check(player.skill_casting.preview.intent.target.get_ref() == boss and not player.skill_casting.preview.valid, "hovered higher-level unit is shown as invalid without substituting another target")
	var soldier: Node = arena.enemies.filter(func(unit: Node) -> bool: return unit.enemy_id == "soldier")[0]
	soldier.global_position = player.global_position + Vector3.FORWARD * 3
	arena.aim_override = soldier.global_position + Vector3.RIGHT * 1.5
	await ticks(1)
	check(player.skill_casting.preview.intent.target == null, "unit selection does not magnetize an empty mouse position to a nearby small body")
	arena.aim_override = soldier.global_position
	await ticks(1)
	check(player.skill_casting.preview.valid and player.skill_casting.preview.intent.target.get_ref() == soldier, "moving onto an eligible unit updates the same live selector")
	await tap(KEY_Q)
	arena.locked_target = boss
	arena.aim_override = boss.global_position
	await ticks(16)
	check(arena.control.controlled_actor() == soldier, "confirmed targeted spell cannot be redirected to a different hovered or locked unit")
	check(not player.skill_casting.active() and soldier.is_human_controlled(), "control transfer clears the original body's casting selection")

	await prepare()
	await click()
	key(KEY_E, true)
	await ticks(1)
	await aim(Vector3.RIGHT)
	key(KEY_E, false)
	await ticks(1)
	check(player.skill_casting.pending() and skill_count() == 0, "confirming during basic startup queues one legal skill handoff")
	await aim(Vector3.LEFT)
	await ticks(32)
	var skills := started.filter(func(entry: Dictionary) -> bool: return entry.get("is_skill", false))
	check(skills.size() == 1 and skills[0].observed_direction.dot(Vector3.RIGHT) > .999, "buffered skill uses the original confirmed direction when its handoff opens")
	await prepare()
	await click()
	await tap(KEY_E)
	check(player.skill_casting.pending(), "second buffer fixture has a pending cast")
	await click(MOUSE_BUTTON_RIGHT)
	await ticks(35)
	check(skill_count() == 0 and not player.skill_casting.pending() and started.size() == 1, "right-click can cancel a buffered cast without leaking a secondary attack")
	await prepare("mage")
	player.loadout.assign_skill(0, 0, "mage_lightning")
	soldier.global_position = player.global_position + Vector3.FORWARD * 3
	arena.aim_override = soldier.global_position
	await click()
	before = player.resources.current("Energy")
	await tap(KEY_Q)
	check(player.skill_casting.pending(), "targeted buffer retains the confirmed unit before a legal handoff")
	soldier.combat.state = "DEAD"
	await ticks(35)
	check(skill_count() == 0 and player.resources.current("Energy") == before and float(player.combat.cooldowns.get("mage_lightning", 0)) == 0, "a buffered target dying before startup rejects the cast without energy or cooldown")

	await prepare()
	key(KEY_Q, true)
	await ticks(1)
	arena.ui.toggle_menu(true)
	key(KEY_Q, false)
	await ticks(2)
	check(not player.skill_casting.active() and started.is_empty(), "opening a blocking menu cancels selection and consumes no skill release")
	await prepare()
	key(KEY_Q, true)
	await ticks(1)
	await tap(KEY_SHIFT)
	key(KEY_Q, false)
	await ticks(30)
	check(not player.skill_casting.active() and skill_count() == 0 and player.loadout.current_set == 1, "combat-set switching discards selection from the previous loadout")
	await prepare()
	key(KEY_Q, true)
	await ticks(1)
	arena._focus_lost()
	key(KEY_Q, false)
	await ticks(2)
	check(not player.skill_casting.active() and started.is_empty(), "focus loss clears casting and prevents a ghost release")
	await prepare()
	key(KEY_Q, true)
	await ticks(1)
	player.combat.state = "HITSTUN"
	player.combat.control_time = .5
	await ticks(1)
	key(KEY_Q, false)
	await ticks(2)
	check(not player.skill_casting.active() and started.is_empty(), "incoming hitstun cancels a selected skill before confirmation")
	await prepare()
	Preferences.set_cast_mode("skill_q", "precise")
	Preferences.set_cast_mode("skill_e", "quick")
	Preferences.set_cast_mode("skill_r", "precise")
	await tap(KEY_Q)
	check(player.skill_casting.active() and player.skill_casting.mode == "precise", "Q retains its independently configured precise mode")
	await click(MOUSE_BUTTON_RIGHT)
	await tap(KEY_E)
	check(skill_count() == 1 and not player.skill_casting.active(), "E remains quick release while neighboring slots use precise")
	await ticks(45)
	await tap(KEY_R)
	check(player.skill_casting.active() and skill_count() == 1 and player.skill_casting.mode == "precise", "R independently remains in precise selection")
	await prepare()
	Preferences.set_cast_mode("skill_q", "precise")
	await tap(KEY_Q)
	player.resources.change("Energy", -10000)
	await tap(KEY_Q)
	check(player.skill_casting.active() and skill_count() == 0 and player.resources.current("Energy") == 0 and player.combat.cooldowns.is_empty(), "confirmation rechecks energy lost after entering selection and spends nothing")
	player.resources.change("Energy", 10000)
	await tap(KEY_Q)
	check(skill_count() == 1 and not player.skill_casting.active(), "the same precise selection can confirm after its resource requirement is restored")
	player.input_router.cancel()
	arena.queue_free()
	await ticks(4)
	DirAccess.remove_absolute(Preferences.settings_path)
	Preferences.settings_path = Preferences.DEFAULT_PATH
	print("SKILL_CASTING_RESULT %d/%d passed" % [checks - failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
