extends SceneTree
const Preferences = preload("res://rpg/game_preferences.gd")
## Real normal-mode learning, physical Q events and a timed local control lease.
var game: Node
var world: Node
var player: Node
var origin: Vector3
var checks := 0
var failures: Array[String] = []
var fixtures: Array[Node] = []
var uses: Array[String] = []
const SKILL := "conjurer_dreamwalk"

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func q(pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_Q
	event.pressed = pressed
	Input.parse_input_event(event)
func press_q() -> void:
	q(true)
	await ticks(1)
	q(false)
	await ticks(1)
func right_click(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.position = root.get_mouse_position()
	event.global_position = event.position
	event.pressed = pressed
	Input.parse_input_event(event)
func prepare() -> void:
	q(false)
	world.control.cancel_all()
	player.combat.reset()
	player.global_position = origin
	world.locked_target = null
	game.aim_override = origin + Vector3(50, 0, 50)
	for body in fixtures:
		if is_instance_valid(body): body.global_position = origin + Vector3(50, 0, -50)
	await ticks(2)
func spawn(id: String, offset := Vector3(3, 0, 0)) -> Node:
	var body: Node = world.spawn_enemy(id, player.global_position + offset)
	body.ai_enabled = false
	body.set_physics_process(false)
	fixtures.append(body)
	return body
func aim(body: Node, lock := true) -> void:
	game.aim_override = body.global_position
	world.aim_point = body.global_position
	world.locked_target = body if lock else null
	await ticks(2)
func energy() -> float: return player.resources.current("Energy")
func cooldown() -> float: return float(player.combat.cooldowns.get(SKILL, 0))
func assert_refunded(before: float, label: String) -> void:
	check(world.control.controlled_actor() == player and is_equal_approx(energy(), before) and is_zero_approx(cooldown()) and not player.combat.runner.busy(), label)

func run() -> void:
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-dreamwalk-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(20)
	player = game.player
	world = game.combat_world
	world.encounters_started = true
	game.sound.muted = true
	for enemy in world.enemies: enemy.set_physics_process(false)
	origin = player.global_position
	check(not player.loadout.sandbox_mode and player.loadout.level == 0, "dreamwalk begins in the actual fresh main game")
	check(player.progression.choose_career("mage"), "choose mage through real progression")
	check(player.inventory.count("magic_candy") == 0 and player.inventory.add_item("magic_candy"), "dreamwalk fixture explicitly grants its debug level item")
	check(player.inventory.use_item("magic_candy") and player.loadout.level == 2, "owned candy reaches the actual conjurer level")
	check(player.progression.choose_career("conjurer"), "advance to conjurer through its real career gate")
	check(SKILL in player.loadout.available_skills and SKILL not in player.loadout.unlocked_skills, "dreamwalk is eligible but is not silently learned")
	check(player.progression.learn_skill(SKILL) and player.loadout.assign_skill(0, 0, SKILL), "learn dreamwalk and equip it in A Q")
	player.combat.skill_used.connect(func(id: String): uses.append(id))
	var definition: Dictionary = world.database.skills[SKILL]
	check(CombatConditions.check({"type":"target_level_at_most_self"}, {"has_target":true,"level":2,"target_level":2}) and not CombatConditions.check({"type":"target_level_at_most_self"}, {"level":2}), "level condition permits equality and fails closed without a target")
	await prepare()
	var before := energy()
	await press_q()
	await ticks(20)
	assert_refunded(before, "Q without a target does not spend Energy or start cooldown")
	var boss := spawn("ogre")
	await aim(boss)
	check(boss.loadout.level == 10 and player.combat.context(boss).target_level == 10, "target context reads the boss's real level")
	await press_q()
	await ticks(20)
	assert_refunded(before, "Lv2 conjurer rejects Lv10 boss before charging costs")
	check(uses.is_empty(), "rejected dreamwalk does not emit skill_used")
	await prepare()
	var soldier := spawn("soldier")
	var original_faction: String = soldier.faction_id
	await aim(soldier)
	before = energy()
	var target_hp: float = soldier.resources.current("HP")
	check(Preferences.get_cast_mode("skill_q") == Preferences.CAST_QUICK, "fresh preferences default Q to hold-and-release casting")
	q(true)
	await ticks(2)
	check(player.skill_casting.active() and player.skill_casting.indicator.visible and not player.combat.runner.busy() and uses.is_empty(), "holding physical Q previews the selected target without starting the spell")
	check(is_equal_approx(energy(), before) and is_zero_approx(cooldown()), "aiming before confirmation spends no Energy and starts no cooldown")
	right_click(true)
	await ticks(1)
	right_click(false)
	await ticks(1)
	q(false)
	await ticks(1)
	assert_refunded(before, "right-click cancels held Q and its later release remains free")
	check(not player.skill_casting.active() and not player.skill_casting.indicator.visible and player.input_router.held.is_empty() and uses.is_empty(), "right-click cancellation hides the preview and does not leak a weapon attack")
	q(true)
	await ticks(1)
	q(false)
	await ticks(1)
	check(player.combat.runner.busy() and player.combat.action_target == soldier, "releasing physical Q starts the learned skill and locks its selected unit")
	check(is_equal_approx(energy(), before - 20) and cooldown() > 19, "startup pays exactly twenty Energy and starts the configured cooldown")
	await ticks(20)
	check(world.control.controlled_actor() == soldier and player.control_mode == "none" and soldier.is_human_controlled(), "Lv1 soldier receives local input through the real spell effect")
	check(soldier.resources.current("HP") == target_hp and uses.size() == 1, "possession causes no unintended damage and emits one skill event")
	var elapsed := 15.0 - float(world.control.remaining)
	check(elapsed >= .1 and elapsed < .4, "lease starts at the active effect rather than the initial key press")
	await ticks(870)
	check(world.control.controlled_actor() == soldier and world.control.remaining > 0, "the same body stays possessed for nearly fifteen seconds")
	await ticks(35)
	check(world.control.controlled_actor() == player and player.is_human_controlled(), "fifteen-second timeout restores input to the original body")
	check(soldier.faction_id == original_faction, "timeout restores the possessed unit's original faction")
	await prepare()
	var equal := spawn("heavy_guard")
	await aim(equal)
	check(equal.loadout.level == player.loadout.level, "heavy guard supplies the exact level-equality boundary")
	check(Preferences.set_cast_mode("skill_q", Preferences.CAST_PRECISE) == OK, "Q can independently select the two-press casting mode")
	before = energy()
	var uses_before := uses.size()
	await press_q()
	check(player.skill_casting.active() and player.skill_casting.mode == Preferences.CAST_PRECISE and not player.combat.runner.busy(), "first physical Q tap keeps precise aiming active after key release")
	check(is_equal_approx(energy(), before) and is_zero_approx(cooldown()) and uses.size() == uses_before, "first precise tap does not pay or emit a skill event")
	await press_q()
	check(player.combat.runner.busy() and player.combat.action_target == equal and is_equal_approx(energy(), before - 20) and cooldown() > 19 and uses.size() == uses_before + 1, "second physical Q tap confirms once and locks the target with normal cost and cooldown")
	await ticks(20)
	check(world.control.controlled_actor() == equal, "dreamwalk accepts a target of exactly the caster's level")
	check(Preferences.set_cast_mode("skill_q", Preferences.CAST_QUICK) == OK, "remaining target-snapshot checks use the default hold-and-release mode")
	await prepare()
	var higher := spawn("fire_elemental")
	await aim(higher)
	before = energy()
	await press_q()
	await ticks(20)
	assert_refunded(before, "a target just one level higher is rejected without payment")
	await prepare()
	var locked := spawn("soldier")
	var changed_aim := spawn("ogre", Vector3(-3, 0, 0))
	await aim(locked)
	await press_q()
	await aim(changed_aim)
	await ticks(20)
	check(world.control.controlled_actor() == locked and changed_aim.control_mode == "ai", "changing lock and aim during startup cannot redirect the spell to a stronger unit")
	await prepare()
	var leveled := spawn("soldier")
	await aim(leveled)
	before = energy()
	await press_q()
	leveled.loadout.level = 10
	await ticks(20)
	assert_refunded(before, "a target that levels above the caster during startup is rechecked and refunded")
	await prepare()
	var deleted := spawn("soldier")
	await aim(deleted)
	before = energy()
	await press_q()
	deleted.queue_free()
	await ticks(20)
	assert_refunded(before, "freeing the locked target during startup safely refunds costs and clears cooldown")
	await prepare()
	var neutral := spawn("heavy_guard")
	neutral.faction_id = "villagers"
	neutral.refresh_collision_layer()
	await aim(neutral, false)
	check(player.target_for_action(definition) == neutral and not world.are_hostile(player, neutral), "mouse targeting finds an eligible neutral unit with relation any")
	await press_q()
	await ticks(20)
	check(world.control.controlled_actor() == neutral, "same-level neutral unit can be possessed through physical Q")
	world.control.release()
	check(neutral.faction_id == "villagers", "releasing a neutral body restores its original faction")
	await prepare()
	var ally := spawn("soldier")
	ally.faction_id = player.faction_id
	ally.refresh_collision_layer()
	await aim(ally, false)
	await press_q()
	await ticks(20)
	check(world.control.controlled_actor() == ally, "same-faction units also satisfy the skill's explicit any relation")
	await prepare()
	# Float the stationary target above the real scene to isolate spherical range
	# from unrelated terrain occlusion. The caster and input remain the main game.
	var distant := spawn("soldier", Vector3.UP * 13.2)
	var range_passive := {"id":"dreamwalk_range_fixture","event":"stat_update","conditions":[{"type":"target_level_at_most_self"}],"effects":[{"type":"modifier","stat":"spell_range_multiplier","value":.2}]}
	world.database.passives[range_passive.id] = range_passive
	player.loadout.passive_ids.append(range_passive.id)
	await aim(distant)
	check(player.combat.action_failure(definition).is_empty(), "target-conditional range modifier permits a target beyond base twelve meters")
	await press_q()
	check(float(player.combat.runner.current_action.get("range", 0)) > 14, "the started action snapshots the same target-conditional effective range")
	await ticks(20)
	check(world.control.controlled_actor() == distant, "execution honors the modified range accepted at startup")
	player.loadout.passive_ids.erase(range_passive.id)
	world.database.passives.erase(range_passive.id)
	await prepare()
	var status_target := spawn("soldier", Vector3.UP * 13.2)
	player.combat.statuses.add_status("dreamwalk_range_status", {"duration":2,"effects":[{"type":"modifier","stat":"spell_range_multiplier","value":.2}]}, player)
	await aim(status_target)
	check(player.combat.action_failure(definition).is_empty(), "status range modifiers use the same preflight calculation")
	await press_q()
	await ticks(20)
	check(world.control.controlled_actor() == status_target, "status-extended range also remains legal when the effect executes")
	await prepare()
	var escaped := spawn("soldier")
	await aim(escaped)
	before = energy()
	await press_q()
	escaped.global_position = player.global_position + Vector3.UP * 18
	await ticks(20)
	assert_refunded(before, "a locked target leaving effective range during startup is safely refunded")
	print("DREAMWALK_RESULT %d/%d passed" % [checks - failures.size(), checks])
	world.control.cancel_all()
	q(false)
	game.queue_free()
	await ticks(3)
	quit(0 if failures.is_empty() else 1)
