extends SceneTree
## Production main camera, real mouse projection, GUI clicks and Kirito skeleton.
const Preferences = preload("res://rpg/game_preferences.gd")
const OUTPUT := "res://docs/combat/"
var app: Node
var game: Node
var hero: Node
var checks := 0
var failures := 0
var captures := 0
var actions := 0
var origin: Vector3

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	print("PASS " if ok else "FAIL ", label)
func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode=code
	event.keycode=code
	event.pressed=pressed
	Input.parse_input_event(event)
func tap(code: Key) -> void:
	key(code,true)
	await ticks(2)
	key(code,false)
	await ticks(2)
func pointer(at: Vector2) -> void:
	if DisplayServer.get_name()!="headless":
		root.grab_focus()
		Input.warp_mouse(at)
	var event := InputEventMouseMotion.new()
	event.position=at
	event.global_position=at
	Input.parse_input_event(event)
	await ticks(3)
func click(at: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	await pointer(at)
	for down: bool in [true,false]:
		var event := InputEventMouseButton.new()
		event.position=at
		event.global_position=at
		event.button_index=button
		event.pressed=down
		Input.parse_input_event(event)
		await ticks(2)
func shot(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await RenderingServer.frame_post_draw
	var pixels := root.get_texture().get_image()
	check(pixels.get_size()==Vector2i(1920,1080) and pixels.save_png(OUTPUT+"movement-"+label+"-1080.png")==OK,"1080p main capture "+label)
	captures+=1
func prepare() -> void:
	app.ui.close_panel(true)
	for code in [KEY_Z,KEY_C,KEY_X]: key(code,false)
	hero.combat.reset()
	hero.global_position=origin
	hero.velocity=Vector3.ZERO
	game.aim_override=null
	game.combat_world.aim_override=null
	await ticks(15)
	actions=0

func run() -> void:
	Preferences.settings_path=OS.get_temp_dir().path_join("mosslight-movement-main-%d-%d.cfg" % [OS.get_process_id(),Time.get_ticks_usec()])
	root.size=Vector2i(1920,1080)
	if DisplayServer.get_name()!="headless": root.grab_focus()
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=app.SAVE_REPOSITORY.new(Preferences.settings_path+"-adventures")
	root.add_child(app)
	current_scene=app
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	await ticks(3)
	app._finish_arrival()
	game=app.game
	hero=game.player
	app.ui.close_panel(true)
	app.ui.modulate.a=1
	app.ui.career_picker=false
	app.ui.region_clock=0
	game.sound.muted=true
	game.combat_world.encounters_started=true
	for unit in game.combat_world.enemies: unit.set_physics_process(false)
	hero.combat.runner.action_started.connect(func(_action: Dictionary): actions+=1)
	await ticks(45)
	origin=hero.global_position
	print("MAIN_MOVEMENT_ORIGIN ",origin)
	check(app.ui.movement_buttons.size()==2 and app.ui.quick_buttons.size()==7,"main adds two circles without displacing skill or item slots")
	var z: Control=app.ui.movement_buttons.move_jump
	var c: Control=app.ui.movement_buttons.move_crouch
	var q: Control=app.ui.quick_buttons.skill_q
	check(z.size==Vector2(24,24) and c.size==Vector2(24,24) and c.position.y-z.position.y==26 and q.position.x-z.position.x==31,"stacked small circles occupy the height immediately left of Q")
	check(app.ui.blocks_world_pointer(z.get_global_rect().get_center()) and app.ui.blocks_world_pointer(c.get_global_rect().get_center()),"actual scaled movement circles block world pointer input")
	await shot("hud")

	var aim: Vector3=hero.global_position+game.combat_world.camera_right()*3
	await pointer(game.world_to_screen(aim))
	print("MAIN_POINTER_TRACE ", {"expected": game.world_to_screen(aim), "actual": root.get_mouse_position(), "aim_plane": game.screen_to_world(root.get_mouse_position(),hero.global_position.y), "focus": root.has_focus()})
	key(KEY_Z,true)
	await ticks(4)
	print("MAIN_JUMP_PREVIEW ",hero.movement_actions.preview," reason=",hero.movement_actions.invalid_reason)
	check(hero.movement_actions.active() and hero.movement_actions.preview.valid,"actual mouse ray selects a valid main-world landing")
	check(hero.movement_actions.indicator.find_children("*","Label3D",true,false).is_empty(),"main jump rings show boundaries without numeric labels")
	check(Vector2(hero.movement_actions.preview.point.x-aim.x,hero.movement_actions.preview.point.z-aim.z).length()<.20,"pixel viewport ray projection preserves landing coordinates")
	await shot("jump-rings")
	var landing: Vector3=hero.movement_actions.preview.point
	key(KEY_Z,false)
	await ticks(15)
	check(hero.movement_actions.airborne and hero.animation.current_animation=="jump_arc" and hero.global_position.y>origin.y+.7,"Kirito shows an airborne skeletal jump in the main world")
	await shot("jump-airborne")
	await ticks(60)
	print("MAIN_JUMP_FINISH ", {"position": hero.global_position, "target": landing, "reason": hero.movement_actions.last_reason, "actions": actions})
	check(not hero.movement_actions.airborne and hero.global_position.distance_to(landing)<.10 and actions==0,"main jump reaches the selected ground without any weapon leak")

	await prepare()
	Preferences.set_cast_mode("move_jump","precise")
	await click(app.ui.movement_buttons.move_jump.get_global_rect().get_center())
	check(hero.movement_actions.selection=="jump" and actions==0,"clicking the Z circle opens landing selection without attacking")
	await pointer(game.world_to_screen(hero.global_position+game.combat_world.camera_right()*3))
	await click(Vector2(960,400),MOUSE_BUTTON_RIGHT)
	check(not hero.movement_actions.active() and not hero.movement_actions.airborne and actions==0,"real right-click cancels the HUD jump selection")
	await click(app.ui.movement_buttons.move_crouch.get_global_rect().get_center())
	await ticks(14)
	check(hero.movement_actions.crouching and hero.animation.current_animation=="crouch_idle" and app.ui.panel=="" and actions==0,"default C circle toggles a physical crouch without book or attack leakage")
	var visual: Node=hero.animation
	check(visual._rig.position.y<-.40 and visual.skeleton.get_bone_pose_rotation(visual._bones.J_Bip_L_UpperLeg).angle_to(Quaternion.IDENTITY)>.2,"main crouch lowers Kirito's pelvis and bends the actual leg bones")
	await pointer(game.world_to_screen(hero.global_position+game.combat_world.camera_right()*3))
	await shot("crouch")
	await tap(KEY_C)
	await ticks(14)
	check(not hero.movement_actions.crouching and hero.animation._rig.position.y>-.03,"physical C toggles standing after a HUD crouch")
	Preferences.set_cast_mode("move_crouch","precise")
	await tap(KEY_C)
	check(hero.movement_actions.selection=="crouch" and hero.movement_actions.preview.point==hero.global_position,"precise C displays a self indicator")
	await shot("crouch-self")
	await tap(KEY_C)
	await ticks(12)
	check(hero.movement_actions.crouching and not hero.movement_actions.active(),"second precise C confirms its own posture change in main")

	app.ui.show_panel("settings")
	app.ui.settings_tab=1
	app.ui._build_modal()
	await ticks(55)
	check(app.ui.modal.get_node("CastMode3").text=="精准施法" and app.ui.modal.get_node("CastMode4").text=="精准施法","book settings show the actual independent Z/C modes")
	await shot("settings")
	await click(app.ui.get_global_transform()*app.ui.modal.get_node("CastMode3").get_global_rect().get_center())
	await ticks(6)
	check(Preferences.get_cast_mode("move_jump")=="quick" and Preferences.get_cast_mode("move_crouch")=="precise" and Preferences.get_cast_mode("skill_q")=="quick","clicking Z's setting changes only Z's saved mode")
	app.ui.close_panel(true)
	await ticks(12)
	await tap(KEY_X)
	await ticks(55)
	check(app.ui.panel=="character","X now opens the main character book")
	app.ui.close_panel(true)
	Preferences.set_cast_mode("move_jump","quick")
	hero.restore(game.GARDEN_ORIGIN+Vector3(2.5,-.1,13.4))
	await ticks(16)
	check(hero.swimming,"shore jump begins in the main world's actual water")
	var bank: Vector3=game.GARDEN_ORIGIN+Vector3(2.5,2.2,8.2)
	game.aim_override=bank
	key(KEY_Z,true)
	await ticks(3)
	print("SHORE_JUMP_PREVIEW ",hero.movement_actions.preview," reason=",hero.movement_actions.invalid_reason)
	check(hero.movement_actions.preview.valid and hero.movement_actions.preview.cost==2,"actual bank height and trajectory validate a two-pip shore jump")
	await shot("water-bank")
	var shore_landing: Vector3=hero.movement_actions.preview.point
	var health: float=hero.resources.current("HP")
	key(KEY_Z,false)
	await ticks(75)
	check(not hero.swimming and not hero.wading and hero.global_position.distance_to(shore_landing)<.12 and hero.resources.current("HP")==health,"jump exits actual water onto the bank without buoyancy teleportation or health loss")
	hero.combat.reset()
	hero.input_router.cancel()
	app.queue_free()
	await ticks(5)
	DirAccess.remove_absolute(Preferences.settings_path)
	Preferences.settings_path=Preferences.DEFAULT_PATH
	print("MOVEMENT_MAIN_RESULT %d/%d passed, %d captures" % [checks-failures,checks,captures])
	quit(0 if failures==0 else 1)
