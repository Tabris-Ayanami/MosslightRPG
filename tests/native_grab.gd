extends SceneTree
## Possess the real ogre, then use physical Q through the common input router.
const Units = preload("res://combat/unit_definition.gd")
const ORIGIN := Vector3(0, .1, 5)
var arena: Node
var player: Node
var ogre: Node
var victim: Node
var checks := 0
var failures: Array[String] = []
var hits: Array[Dictionary] = []
var skills: Array[String] = []
var ai_started: Array[String] = []
var soldier_started: Array[Dictionary] = []

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
	event.pressed = pressed
	Input.parse_input_event(event)
func tap_q() -> void:
	key(KEY_Q, true)
	await ticks(1)
	key(KEY_Q, false)
	await ticks(1)
func tap_secondary() -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = true
	Input.parse_input_event(event)
	await ticks(1)
	event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = false
	Input.parse_input_event(event)
	await ticks(1)
func spawn(id: String, position: Vector3) -> Node:
	var body: Node = arena.spawn_enemy(id, position)
	body.ai_enabled = false
	return body
func prepare_grab() -> void:
	ogre.combat.reset()
	victim.combat.reset()
	ogre.global_position = ORIGIN
	victim.global_position = ORIGIN + Vector3.FORWARD * 1.85
	ogre.facing = Vector3.FORWARD
	victim.facing = Vector3.BACK
	arena.aim_override = victim.global_position
	arena.aim_point = victim.global_position
	arena.locked_target = victim
	await ticks(3)
	hits.clear()
	skills.clear()
func await_grab() -> bool:
	for i in range(95):
		if victim.combat.state == "GRABBED": return true
		await ticks(1)
	return false

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	arena.player_visual_script = preload("res://combat/animation_controller.gd")
	root.add_child(arena)
	await ticks(3)
	player = arena.player
	arena.sound.muted = true
	arena.ui.toggle_menu(false)
	arena.input_blocked = false
	arena.pointer_blocked = false
	for enemy in arena.enemies:
		enemy.ai_enabled = false
		enemy.global_position = Vector3(18, .1, 18)
	var raw: Dictionary = arena.database.enemies.ogre
	var unit := Units.for_enemy(arena.database, "ogre")
	check(unit.innate_skills.size() == 2 and unit.innate_skills[0].id == raw.grab_action.id and unit.innate_skills[0].is_skill and unit.innate_skills[1].id == "ogre_stone_throw", "ogre keeps grab in Q and adds stone throw in E")
	check(unit.innate_actions.SECONDARY_TAP == raw.secondary_action and unit.innate_actions.SECONDARY_TAP.id != raw.grab_action.id and unit.innate_actions.SECONDARY_TAP.get("attack_kind", "") != "GRAB", "right mouse has its own heavy sweep and does not alias Q grab")
	var faithful := true
	for field in ["startup", "active", "recovery", "cooldown", "costs", "formula", "range", "angle", "grab_duration", "blockable", "parryable"]:
		faithful = faithful and unit.innate_skills[0][field] == raw.grab_action[field]
	check(faithful and unit.innate_skills[0].ai_attack_every == raw.grab_every, "visible skill inherits actual grab timing, costs, damage, reach and AI cadence")
	check("霸体" in unit.innate_skills[0].description and "格挡" in unit.innate_skills[0].description and "闪避" in unit.innate_skills[0].description, "grab description explains its defensive counters without inventing different stats")
	unit.innate_skills[0].formula.base = 999999
	check(raw.grab_action.formula.base == 150 and unit.innate_actions.SECONDARY_TAP.formula.base == raw.secondary_action.formula.base, "Q's nested snapshot cannot mutate the catalog or independent right mouse action")
	var declared: Dictionary = raw.grab_action.duplicate(true)
	var shipped_skills: Array = raw.innate_skills.duplicate(true)
	declared["name"] = "显式抓取配置"
	arena.database.skills[declared.id] = raw.grab_action.duplicate(true)
	raw["innate_skills"] = [declared, declared.id, "warrior_whirlwind", "warrior_whirlwind", "missing_native_skill", {}]
	var normalized := Units.for_enemy(arena.database, "ogre")
	check(normalized.innate_skills.size() == 2 and normalized.innate_skills[0].name == declared.name and normalized.innate_skills[1].id == "warrior_whirlwind", "inline and referenced native abilities retain explicit order and deduplicate by ID")
	check(normalized.innate_skills.all(func(skill: Dictionary) -> bool: return skill.is_skill) and normalized.innate_skills[0].ai_attack_every == 3, "declared native skills share QER classification and legacy grab cadence")
	raw["innate_skills"] = shipped_skills
	arena.database.skills.erase(declared.id)
	# Dreamwalk reaches the body through actual skill input, with equal levels.
	player.loadout.select_career("mage")
	player.loadout.set_level(10)
	player.loadout.select_career("conjurer")
	player.loadout.assign_skill(0, 0, "conjurer_dreamwalk")
	player.combat.reset()
	player.global_position = ORIGIN + Vector3.LEFT * 5
	ogre = spawn("ogre", ORIGIN)
	victim = spawn("heavy_guard", ORIGIN + Vector3.FORWARD * 1.85)
	arena.locked_target = ogre
	arena.aim_override = ogre.global_position
	arena.aim_point = ogre.global_position
	await tap_q()
	await ticks(20)
	check(arena.control.controlled_actor() == ogre and ogre.is_human_controlled(), "physical Q Dreamwalk transfers input to the equal-level ogre")
	check(ogre.skill_at(0).id == "ogre_grab" and ogre.skill_at(1).id == "ogre_stone_throw" and ogre.skill_at(2).is_empty(), "possessed body exposes its catalog grab in Q and stone in E")
	ogre.combat.damage_dealt.connect(func(result: Dictionary): hits.append(result))
	ogre.combat.skill_used.connect(func(id: String): skills.append(id))
	await prepare_grab()
	check(victim.combat.defense.start_guard(), "actual shield defender enters guard before the grab")
	var hp: float = victim.resources.current("HP")
	var stamina: float = ogre.resources.current("Stamina")
	await tap_q()
	check(ogre.combat.runner.current_action.get("id", "") == "ogre_grab", "possessed body's physical Q starts the actual grab action")
	check(ogre.animation.body_flash_remaining > 0 and ogre.animation.body_flash_color == Color("ff293b"), "grab startup displays its real red body warning")
	check(await await_grab(), "Q's real attack instance captures a hostile shield defender")
	check(victim.resources.current("HP") < hp and victim.combat.defense.last_outcome == "none" and ogre.combat.state == "GRABBING", "grab bypasses shield damage protection and pairs both controlled states")
	check(hits.size() == 1 and skills == ["ogre_grab"] and ogre.resources.current("Stamina") == stamina, "one Q emits one skill event and hit with the actual zero resource cost")
	check(victim.combat.grab_source.get_ref() == ogre and ogre.combat.grab_target.get_ref() == victim, "grab links the real possessed source and victim")
	await ticks(65)
	check(ogre.combat.state == "NORMAL" and victim.combat.state == "KNOCKDOWN", "configured one-second hold releases attacker and throws the victim")
	await ticks(43)
	check(victim.combat.state == "NORMAL" and victim.combat.grab_source == null and ogre.combat.grab_target == null, "knockdown recovery clears both grab links")
	await prepare_grab()
	var brace := {"id":"native_brace_fixture", "targeting":"SELF", "presentation_type":"WEAPON_ACTION", "startup":0.0, "active":3.0, "recovery":.1, "formula":{}, "costs":{}, "hyper_armor":{"start":0.0,"end":3.0}}
	victim.innate_actions["BRACE"] = brace
	check(victim.combat.use_action(brace) and victim.combat.has_hyper_armor(), "victim runs a real action with an active hyper-armor window")
	hp = victim.resources.current("HP")
	await tap_q()
	check(await await_grab(), "a second physical Q captures the unit through active hyper armor")
	check(victim.resources.current("HP") < hp and not victim.combat.runner.busy() and not victim.combat.has_hyper_armor(), "grab damages and cancels the armored action rather than merely staggering it")
	await ticks(110)
	check(victim.combat.state == "NORMAL" and ogre.combat.state == "NORMAL", "both bodies recover after the hyper-armor capture")
	await prepare_grab()
	await tap_secondary()
	check(ogre.combat.runner.current_action.get("id", "") == "ogre_heavy_sweep" and not ogre.combat.runner.current_action.get("is_skill", false), "physical right mouse starts a separate weapon sweep")
	var captured := false
	for i in range(130):
		captured = captured or victim.combat.state == "GRABBED"
		await ticks(1)
	check(not captured and hits.size() == 1 and skills.is_empty() and victim.combat.grab_source == null, "right mouse causes one ordinary hit without grabbing or firing Q's skill event")
	# AI starts outside grab range: finish the full primary string, then approach.
	arena.control.release()
	ogre.combat.reset()
	victim.global_position = Vector3(18, .1, 18)
	player.combat.reset()
	player.global_position = ORIGIN
	player.set_physics_process(false)
	player.resources.configure("HP", 100000)
	player.combat.current_poise = 100000
	ogre.global_position = ORIGIN + Vector3.FORWARD * 3.15
	ogre.spawn_point = ogre.global_position
	ogre.attacks_made = 0
	ogre.ai_cooldown = 0
	ogre.enemy_attack_cooldown = .05
	ogre.ai_enabled = true
	var competing := brace.duplicate(true)
	competing.merge({"id":"scheduled_skill_probe","range":6.0,"ai_attack_every":3}, true)
	ogre.innate_skills.append(competing)
	ogre.combat.runner.action_started.connect(func(action: Dictionary): ai_started.append(action.id))
	for i in range(450):
		if player.combat.state == "GRABBED": break
		await ticks(1)
	check(ai_started.slice(0, 4) == ["ogre_attack", "ogre_attack_2", "ogre_slam_3", "ogre_grab"], "live AI finishes all three primary swings then Q grab despite another scheduled skill")
	check(ogre.attacks_made == 4 and player.combat.state == "GRABBED" and player.resources.current("HP") < 100000, "the deferred grab closes the shorter reach and actually captures its enemy")
	check(not ai_started.has("scheduled_skill_probe"), "a different QER candidate cannot replace the scheduled third grab")
	ogre.ai_enabled = false
	ogre.combat.reset()
	ogre.global_position = Vector3(18, .1, 18)
	player.combat.reset()
	player.global_position = ORIGIN
	var soldier: Node = spawn("soldier", ORIGIN + Vector3.FORWARD * 1.7)
	soldier.combat.runner.action_started.connect(func(action: Dictionary):
		soldier_started.append({"id": action.id, "time": soldier.combat.input_time,
			"duration": action.startup + action.active + action.recovery}))
	soldier.ai_cooldown = 0
	soldier.ai_enabled = true
	for i in range(390):
		if soldier_started.size() >= 4: break
		await ticks(1)
	check(soldier_started.map(func(action: Dictionary) -> String: return action.id).slice(0, 4) == ["soldier_attack", "soldier_attack_2", "soldier_attack_3", "soldier_attack"], "soldier AI executes all three sword swings then restarts the sequence")
	var respects_recovery := soldier_started.size() >= 4
	for index in range(1, mini(4, soldier_started.size())):
		respects_recovery = respects_recovery and soldier_started[index].time - soldier_started[index - 1].time >= soldier_started[index - 1].duration - .02
	check(respects_recovery, "AI combo advancement never skips an earlier swing's attack or recovery")
	check(soldier_started.size() >= 4 and soldier_started[3].time - soldier_started[2].time >= soldier.enemy_attack_cooldown - .02, "AI applies its configured tactical pause only after a complete three-swing string")
	soldier.ai_enabled = false
	player.set_physics_process(true)
	arena.control.cancel_all()
	key(KEY_Q, false)
	print("NATIVE_GRAB_RESULT %d/%d passed" % [checks-failures.size(), checks])
	arena.queue_free()
	await ticks(3)
	quit(0 if failures.is_empty() else 1)
