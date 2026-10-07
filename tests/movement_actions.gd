extends SceneTree
## Real InputMap events exercise the shared unit movement component and physics.
const Preferences = preload("res://rpg/game_preferences.gd")
const ORIGIN := Vector3(0, .08, 6)
const POINTER := Vector2(900, 400)
var arena: Node
var player: Node
var moves: Node
var checks := 0
var failures: Array[String] = []
var actions := 0

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
	event.position = POINTER
	event.global_position = POINTER
	event.button_index = button
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
func aim(distance: float, direction := Vector3.RIGHT) -> void:
	arena.aim_override = player.global_position + direction * distance
	await ticks(2)
func prepare() -> void:
	for code in [KEY_Z, KEY_C, KEY_Q, KEY_E, KEY_R, KEY_D, KEY_X, KEY_SPACE]: key(code, false)
	for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]: mouse(button, false)
	arena.control.release()
	arena.input_blocked = false
	arena.pointer_blocked = false
	arena.ui.toggle_menu(false)
	player.combat.reset()
	player.global_position = ORIGIN
	player.velocity = Vector3.ZERO
	player.facing = Vector3.FORWARD
	Preferences.reset_cast_modes()
	arena.aim_override = ORIGIN + Vector3.RIGHT * 3
	var motion := InputEventMouseMotion.new()
	motion.position = POINTER
	motion.global_position = POINTER
	Input.parse_input_event(motion)
	await ticks(6)
	actions = 0
	moves.last_reason = ""
	player.combat.stamina_clock = 0
func box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	arena.actor_parent.add_child(body)
	body.global_position = at
	return body

func run() -> void:
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-movement-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(5)
	player = arena.player
	moves = player.movement_actions
	player.loadout.select_career("warrior")
	for unit in arena.enemies:
		unit.set_physics_process(false)
		unit.global_position = Vector3(18, .1, 18)
	player.combat.runner.action_started.connect(func(_action: Dictionary): actions += 1)
	await prepare()
	check(Preferences.CAST_ACTIONS.all(func(action: String) -> bool: return Preferences.get_cast_mode(action)=="quick"), "Q/E/R/Z/C default independently to quick casting")
	check(moves.cost_for_distance(0)==0 and moves.cost_for_distance(2)==0 and moves.cost_for_distance(2.01)==1 and moves.cost_for_distance(4)==1 and moves.cost_for_distance(4.01)==2, "distance bands have stable inclusive 0/1/2 pip boundaries")
	check(player.is_on_floor(), "movement starts on the actual arena floor")
	var before: float = player.resources.current("Stamina")
	var count: int = moves.jumps_started
	key(KEY_Z, true)
	await ticks(3)
	print("JUMP_PREVIEW ", moves.preview, " failure=", moves.invalid_reason)
	check(moves.active() and moves.indicator.visible and moves.preview.get("valid", false), "held Z opens a valid visible landing selector")
	check(not moves.airborne and moves.jumps_started==count and player.resources.current("Stamina")==before, "selection neither jumps nor pays stamina")
	var outer_radius := 0.0
	var boundaries := {}
	for vertex: Vector3 in moves.indicator.vertices:
		var radius := Vector2(vertex.x-player.global_position.x,vertex.z-player.global_position.z).length()
		outer_radius=maxf(outer_radius,radius)
		for cost in range(floori(before)+1):
			if absf(radius-2.0*(cost+1))<.05: boundaries[cost]=true
	check(moves.preview.get("cost", -1)==1 and boundaries.size()==floori(before)+1 and absf(outer_radius-moves.maximum_range())<.05, "rendered boundaries include the free band and all currently affordable rings")
	check(moves.indicator.find_children("*","Label3D",true,false).is_empty(), "jump indicator contains no world-space numeric labels")
	check(player.facing.dot(Vector3.FORWARD)>.999, "mouse selection leaves idle WASD facing unchanged")
	var landing: Vector3 = moves.preview.point
	var takeoff: Vector3 = player.global_position
	key(KEY_Z, false)
	await ticks(1)
	check(moves.airborne and moves.jumps_started==count+1 and not moves.active() and not moves.indicator.visible, "quick release starts one jump and closes the indicator")
	check(is_equal_approx(player.resources.current("Stamina"), before-1), "jump confirmation pays the selected distance cost once")
	var height := 0.0
	var largest_step := 0.0
	var previous: Vector3 = player.global_position
	for i in range(80):
		await ticks(1)
		height = maxf(height, player.global_position.y-takeoff.y)
		largest_step = maxf(largest_step, player.global_position.distance_to(previous))
		previous = player.global_position
		if not moves.airborne: break
	print("JUMP_LANDING ", player.global_position, " target=", landing, " reason=", moves.last_reason)
	check(not moves.airborne and moves.last_reason=="landed" and player.global_position.distance_to(landing)<.06, "continuous arc lands at its committed world position")
	check(height>.85 and largest_step<.35 and actions==0, "jump rises visibly, moves continuously and never leaks a weapon action")
	check(not player.combat.invulnerable(), "jump grants no dodge invulnerability")

	await prepare()
	player.resources.change("Stamina", -10000)
	key(KEY_Z, true)
	await ticks(2)
	check(moves.preview.pips==0 and is_equal_approx(moves.maximum_range(),2) and moves.preview.cost==0, "zero stamina keeps a useful free two metre jump")
	await ticks(93)
	check(moves.active() and moves.preview.pips==1 and is_equal_approx(moves.maximum_range(),4), "held maximum ring expands when a real stamina pip recovers")
	player.resources.change("Stamina", -10000)
	await ticks(2)
	check(moves.preview.pips==0 and moves.preview.cost==0 and Vector2(moves.preview.point.x-player.global_position.x,moves.preview.point.z-player.global_position.z).length()<=2.001, "lost stamina shrinks rings and clamps the landing immediately")
	key(KEY_Z, false)
	await ticks(2)
	check(moves.airborne and player.resources.current("Stamina")==0, "free band remains executable without negative stamina")
	await ticks(75)

	await prepare()
	Preferences.set_cast_mode("move_jump","precise")
	await tap(KEY_Z)
	check(moves.active() and not moves.airborne, "precise Z remains in selection after first key release")
	before = player.resources.current("Stamina")
	await click(MOUSE_BUTTON_RIGHT)
	await ticks(3)
	check(not moves.active() and not moves.airborne and player.resources.current("Stamina")==before and actions==0, "RMB cancels a jump without shield, weapon or resource leakage")
	await tap(KEY_Z)
	await tap(KEY_Z)
	check(moves.airborne and not moves.active(), "second precise Z confirms the landing")
	await ticks(75)
	await prepare()
	Preferences.set_cast_mode("move_jump","precise")
	await tap(KEY_Z)
	await click()
	check(moves.airborne and actions==0, "precise LMB confirms the jump without attacking")
	await ticks(75)
	await prepare()
	key(KEY_Z,true)
	await ticks(1)
	await click(MOUSE_BUTTON_RIGHT)
	key(KEY_Z,false)
	await ticks(4)
	check(not moves.airborne and not moves.active() and actions==0, "cancelled quick Z release cannot resurrect a jump")

	await prepare()
	var wall := box(player.global_position+Vector3(1.5,1,0),Vector3(.6,2,3))
	await ticks(2)
	key(KEY_Z,true)
	await ticks(2)
	before = player.resources.current("Stamina")
	check(not moves.preview.valid and not moves.invalid_reason.is_empty(), "full capsule sweep rejects a jump through a wall")
	key(KEY_Z,false)
	await ticks(2)
	check(not moves.airborne and player.resources.current("Stamina")==before, "invalid trajectory cannot spend stamina or teleport")
	wall.queue_free()
	await ticks(2)
	await prepare()
	var step := box(ORIGIN+Vector3(3,.22,0),Vector3(2,.60,2))
	await ticks(2)
	key(KEY_Z,true)
	await ticks(2)
	landing = moves.preview.point
	check(moves.preview.valid and landing.y>.50 and moves.preview.cost==1, "height-aware landing query resolves an elevated step with full capsule clearance")
	key(KEY_Z,false)
	await ticks(60)
	check(moves.last_reason=="landed" and player.global_position.distance_to(landing)<.08, "continuous jump can land on the top of a raised step")
	step.queue_free()
	await ticks(2)
	await prepare()
	var beam := box(ORIGIN+Vector3(3.24,1.65,0),Vector3(.10,.20,2))
	await ticks(2)
	key(KEY_Z,true)
	await ticks(2)
	landing = moves.preview.point
	check(moves.preview.valid, "flat landing near an overhang does not require surplus slope-lift headroom")
	key(KEY_Z,false)
	await ticks(60)
	check(moves.last_reason=="landed" and player.global_position.distance_to(landing)<.08, "body sweep clears an overhead edge and lands without intersecting it")
	beam.queue_free()
	await ticks(2)
	await prepare()
	key(KEY_Z,true)
	await ticks(1)
	key(KEY_Z,false)
	await ticks(4)
	wall = box(ORIGIN+Vector3(2.1,1.5,0),Vector3(.6,3,3))
	for i in range(50):
		await ticks(1)
		if not moves.airborne: break
	check(not moves.airborne and moves.last_reason=="path_blocked" and player.global_position.x<2, "runtime sweep stops at a new obstacle instead of forcing the old landing")
	check(not moves.press("jump") and not moves.active(), "interrupted air movement cannot use a stale floor flag for a second jump")
	wall.queue_free()
	await ticks(2)
	await prepare()
	key(KEY_Z,true)
	await ticks(1)
	key(KEY_Z,false)
	await ticks(4)
	var interrupted_at: Vector3 = player.global_position
	player.combat.force_control("HITSTUN", .45)
	await ticks(4)
	check(not moves.airborne and moves.last_reason=="interrupted" and player.global_position.x<2.5 and player.global_position.distance_to(interrupted_at)<1, "hit control interrupts flight without snapping to its destination")

	await prepare()
	key(KEY_C,true)
	await ticks(1)
	check(moves.selection=="crouch" and not moves.crouching and not arena.ui.menu_open and moves.preview.point==player.global_position, "quick C selects the body rather than opening the character menu")
	key(KEY_C,false)
	await ticks(14)
	var collider: CollisionShape3D = player.get_node("CollisionShape3D")
	var standing_height: float = moves._standing_height
	check(moves.crouching and moves.crouch_blend>.99 and collider.shape.height<standing_height and player.animation.current_animation=="crouch_idle", "C release lowers the collider and presents a real crouching pose")
	var start: Vector3 = player.global_position
	key(KEY_D,true)
	await ticks(30)
	key(KEY_D,false)
	await ticks(2)
	check(absf(player.global_position.distance_to(start)-player.move_speed*.5*.5)<.2, "crouch movement uses half the shared movement speed")
	await tap(KEY_C)
	await ticks(12)
	check(not moves.crouching and is_equal_approx(collider.shape.height,standing_height) and moves.crouch_blend==0, "second quick C restores standing posture and capsule")
	Preferences.set_cast_mode("move_crouch","precise")
	await tap(KEY_C)
	check(moves.selection=="crouch" and not moves.crouching, "C has its own precise self selector")
	await click(MOUSE_BUTTON_RIGHT)
	check(not moves.crouching and not moves.active() and actions==0, "RMB cancels crouch selection without changing posture")
	await tap(KEY_C)
	await tap(KEY_C)
	check(moves.crouching and not moves.active(), "second precise C switches to crouching")
	await tap(KEY_C)
	await click()
	check(not moves.crouching and actions==0, "precise C can stand using LMB without a weapon attack")
	check(Preferences.get_cast_mode("move_jump")=="quick" and Preferences.get_cast_mode("move_crouch")=="precise" and Preferences.get_cast_mode("skill_q")=="quick", "Z/C modes remain independent from each other and Q/E/R")
	Preferences.reload_preferences()
	check(Preferences.get_cast_mode("move_crouch")=="precise", "crouch cast mode survives preferences reload")

	await prepare()
	await tap(KEY_C)
	var ceiling := box(player.global_position+Vector3(0,1.05,0),Vector3(3,.20,3))
	await ticks(2)
	before = player.resources.current("Stamina")
	await tap(KEY_C)
	check(moves.crouching and not moves.can_stand(), "standing is rejected under a low ceiling without expanding into it")
	await tap(KEY_Z)
	check(not moves.airborne and player.resources.current("Stamina")==before, "jump cannot stand through a ceiling or pay an invalid takeoff")
	ceiling.queue_free()
	await ticks(2)
	await tap(KEY_C)
	check(not moves.crouching, "standing works after headroom is restored")

	await prepare()
	key(KEY_Z,true)
	await ticks(1)
	await tap(KEY_X)
	key(KEY_Z,false)
	await ticks(2)
	check(arena.ui.menu_open and not moves.active() and not moves.airborne, "X opens the character menu and cancels a pending jump")
	await tap(KEY_X)
	check(not arena.ui.menu_open, "X closes the character menu")
	await prepare()
	key(KEY_Z,true)
	await ticks(1)
	key(KEY_Q,true)
	await ticks(1)
	check(not moves.active() and player.skill_casting.active(), "skill selection replaces jump selection")
	key(KEY_C,true)
	await ticks(1)
	check(moves.selection=="crouch" and not player.skill_casting.active(), "crouch self selection replaces skill selection")
	await click(MOUSE_BUTTON_RIGHT)
	key(KEY_C,false)
	key(KEY_Q,false)
	key(KEY_Z,false)
	await ticks(2)
	check(not moves.crouching and not moves.airborne and actions==0, "replaced and cancelled selections cannot fire on later releases")

	await prepare()
	var ogre: Node = arena.enemies.filter(func(unit: Node): return unit.race_id=="giant")[0]
	ogre.global_position = ORIGIN + Vector3.RIGHT * 8
	ogre.combat.reset()
	ogre.set_physics_process(true)
	check(arena.control.possess(ogre), "native giant can receive the shared human movement controls")
	await ticks(5)
	await tap(KEY_C)
	await ticks(12)
	check(ogre.movement_actions.crouching and ogre.animation.current_animation=="crouch_idle" and not player.movement_actions.crouching, "possessed unit crouches using its own size, collider and procedural pose")
	arena.aim_override=ogre.global_position+Vector3.RIGHT*1.5
	var ogre_jump_count: int=ogre.movement_actions.jumps_started
	await tap(KEY_Z)
	await ticks(2)
	check(ogre.movement_actions.airborne and not ogre.movement_actions.crouching and ogre.animation.current_animation=="jump_arc", "native giant stands and jumps through its shared movement adapter")
	await ticks(60)
	check(ogre.movement_actions.jumps_started==ogre_jump_count+1 and ogre.movement_actions.last_reason=="landed" and not ogre.movement_actions.airborne, "large possessed body lands with its own capsule and a single jump")
	await tap(KEY_C)
	await ticks(12)
	var ogre_collider: CollisionShape3D = ogre.get_node("CollisionShape3D")
	var ogre_height: float = ogre.movement_actions._standing_height
	arena.control.release()
	ogre.set_physics_process(false)
	check(not ogre.movement_actions.crouching and is_equal_approx(ogre_collider.shape.height,ogre_height), "ending possession restores the native collider and clears crouching")
	player.input_router.cancel()
	arena.queue_free()
	await ticks(4)
	DirAccess.remove_absolute(Preferences.settings_path)
	Preferences.settings_path=Preferences.DEFAULT_PATH
	print("MOVEMENT_ACTIONS_RESULT %d/%d passed" % [checks-failures.size(),checks])
	quit(0 if failures.is_empty() else 1)
