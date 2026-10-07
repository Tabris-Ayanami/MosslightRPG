extends SceneTree
## 1080p production HUD captures: real main actor, profession pools and input mapping.
const OUTPUT := "res://docs/hud/"
var app: Node
var game: Node
var actor: Node
var checks := 0
var failures: Array[String] = []
var capture_enabled := false

func _initialize() -> void:
	call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func shot(label: String) -> void:
	if not capture_enabled: return
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	check(frame.get_size() == Vector2i(1920,1080), label + " is rendered at real 1920x1080")
	frame.save_png(OUTPUT + label + ".png")
func build(career: String) -> void:
	app = load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	game = app.game
	actor = game.player
	app.ui.modulate.a = 1.0
	check(actor.progression.choose_career(career), "normal game chooses " + career)
	app.ui.close_panel(true)
	app.ui.region_clock = 0
	game.sound.muted = true
	await ticks(8)
	game.combat_world.encounters_started = true
	for foe in game.combat_world.enemies:
		foe.set_physics_process(false)
	for i in range(mini(3, actor.loadout.available_skills.size())):
		var id: String = actor.loadout.available_skills[i]
		actor.progression.learn_skill(id)
		actor.loadout.assign_skill(0,i,id)
	game.toast_time = 0
	await ticks(40)
func dispose() -> void:
	game._release_actions()
	app.queue_free()
	await ticks(4)
func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1920,1080)
	capture_enabled = DisplayServer.get_name() != "headless"
	check(int(ProjectSettings.get_setting("display/window/size/viewport_width"))==1920 and int(ProjectSettings.get_setting("display/window/size/viewport_height"))==1080,"project logical debug target is 1080p")
	check(int(ProjectSettings.get_setting("display/window/size/window_width_override"))==1920 and int(ProjectSettings.get_setting("display/window/size/window_height_override"))==1080,"default client window is 1080p")
	await build("warrior")
	var keys: Array = preload("res://scripts/frontend/journal_bindings.gd").ACTIONS + preload("res://scripts/frontend/journal_bindings.gd").QUICK_ACTIONS
	check(app.ui.quick_buttons.size()==7,"bottom HUD has only QER and four item slots")
	for id in keys:
		check(app.ui.quick_buttons.has(id),"visible HUD slot " + id)
		if app.ui.quick_buttons.has(id):
			var b: Button = app.ui.quick_buttons[id]
			var bounds := b.get_global_rect()
			check(bounds.position.y > 940 and bounds.end.y <= 1080,"slot sits close to bottom at 1080p: " + id)
			check(app.ui.blocks_world_pointer(bounds.get_center()),"visible slot captures pointer: " + id)
	check(not app.ui.blocks_world_pointer(Vector2(430,195)),"old empty part of top-left blocker releases world pointer")
	check(game.pixel_material.shader.resource_path=="res://shaders/upscale.gdshader" and game.post_material.shader.resource_path=="res://shaders/reference_outline.gdshader","1080p keeps original pixel rendering shaders")
	var overlay: Node
	for child in game.get_children():
		if child.get_script() == preload("res://rpg/world_overlay.gd"):
			overlay = child
	check(is_instance_valid(overlay) and overlay.stamina_ring.visible, "main pixel world projects a visible foot ring into the full-size HUD")
	if is_instance_valid(overlay):
		check(overlay.stamina_ring.centers.size() == int(actor.resources.max_value("Stamina")), "ground arc shows every actual stamina point")
		var nearest := Vector3(game.camera.global_basis.z.x,0,game.camera.global_basis.z.z).normalized()
		for point in overlay.stamina_ring.ground_points:
			check((point-actor.global_position).dot(nearest)>0, "stamina point remains on the near-camera half of the ground ring")
	await shot("01-warrior-a-1080")
	Input.action_press("switch_combat_set")
	await ticks(2)
	Input.action_release("switch_combat_set")
	await ticks(34)
	check(actor.loadout.current_set==1,"actual Shift action selects second weapon group")
	await shot("02-warrior-b-1080")
	actor.resources.change("Energy",-40)
	actor.resources.change("Stamina",-2)
	actor.combat.stamina_clock = 0.0
	await ticks(25)
	await shot("03-stamina-recovery-outline-1080")
	actor.resources.change("Energy",20)
	await ticks(10)
	await shot("04-energy-recovery-1080")
	await ticks(20)
	await shot("05-energy-recovered-1080")
	game.camera_yaw += PI * .42
	await ticks(60)
	await shot("06-camera-orbit-1080")
	await dispose()
	await build("mage")
	check(actor.resources.max_value("Energy")>0 and app.ui.hud_resource_id=="Energy","mage displays the same continuous blue energy pool as warrior")
	await shot("07-mage-1080")
	actor.resources.change("Energy",-40)
	await ticks(2)
	actor.resources.change("Energy",20)
	await ticks(10)
	await shot("08-mage-energy-recovery-1080")
	await ticks(20)
	await shot("09-mage-energy-recovered-1080")
	await dispose()
	print("HUD_1080: %d checks; %d failures" % [checks,failures.size()])
	for label in failures: printerr("FAIL: ",label)
	quit(0 if failures.is_empty() else 1)
