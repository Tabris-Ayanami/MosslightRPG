extends SceneTree
## Developer A/B playground, isolated from adventure saves and preferences.
const Impact = preload("res://combat/impact_feedback.gd")
var arena: Node
var player: Node
var target: Node
var panel: Label
var previous: Dictionary = {}
var capture_path := ""
var hits := 0
var family_index := 0
const FAMILY_NAMES := ["单手剑", "匕首", "长柄", "重武器"]

func choose_family() -> void:
	player.combat.reset()
	player.loadout.select_career("warrior" if family_index < 2 else "barbarian")
	if family_index == 1: player.loadout.current_set = 1
	elif family_index == 2: player.loadout.equip_weapon(0,"border_spear")
	elif family_index == 3: player.loadout.equip_weapon(0,"iron_greatsword")
	target.combat.reset()
	target.combat.current_poise = 100000
	target.global_position = player.global_position + Vector3.FORWARD * (.95 if family_index == 1 else 1.4)
	hits = 0
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="): capture_path = arg.trim_prefix("--capture=")
	call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func mouse(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = Vector2(640, 280)
	Input.parse_input_event(event)
func run() -> void:
	root.size = Vector2i(1280, 720)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	await ticks(4)
	player = arena.player
	player.loadout.select_career("warrior")
	arena.ui.toggle_menu(false)
	arena.input_blocked = false
	arena.toast_time = 0.0
	for enemy in arena.enemies:
		enemy.ai_enabled = false
		enemy.global_position = Vector3(20, 0, 20)
	target = arena.enemies[0]
	target.resources.configure("HP", 100000)
	target.combat.base_poise = 100000
	target.combat.current_poise = 100000
	target.global_position = player.global_position + Vector3.FORWARD * 1.4
	target.facing = Vector3.FORWARD
	target.health.damage_received.connect(func(amount: float):
		if amount > 0: hits += 1)
	arena.aim_override = target.global_position
	var layer := CanvasLayer.new()
	root.add_child(layer)
	layer.layer = 20
	panel = Label.new()
	panel.position = Vector2(18, 95)
	panel.add_theme_color_override("font_color", Color("ffe9ae"))
	panel.add_theme_color_override("font_outline_color", Color("182230"))
	panel.add_theme_constant_override("outline_size", 5)
	panel.add_theme_font_size_override("font_size", 18)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(panel)
	if not capture_path.is_empty(): await capture()
func _process(_delta: float) -> bool:
	if not is_instance_valid(player) or not is_instance_valid(panel): return false
	for code in [KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6, KEY_F7]:
		var down := Input.is_physical_key_pressed(code)
		if down and not previous.get(code, false):
			match code:
				KEY_F1: Impact.hitstop_enabled = not Impact.hitstop_enabled
				KEY_F2: Impact.reaction_enabled = not Impact.reaction_enabled
				KEY_F3: Impact.trails_enabled = not Impact.trails_enabled
				KEY_F4: Impact.sound_enabled = not Impact.sound_enabled
				KEY_F5: target.global_position = player.global_position + Vector3.FORWARD * ((.95 if family_index == 1 else 1.4) if target.global_position.distance_to(player.global_position) > 3 else 5)
				KEY_F6: target.ai_enabled = not target.ai_enabled
				KEY_F7:
					family_index = (family_index + 1) % FAMILY_NAMES.size()
					choose_family()
		previous[code] = down
	arena.aim_override = target.global_position
	panel.text = "%s · 反馈实验\nF1 卡肉 %s   F2 受击 %s   F3 刀光 %s   F4 音效 %s\nF5 空挥/命中   F6 士兵反击   F7 换武器   左键连击 / Space 翻滚\n命中 %d   %s / %s   停顿 %.0f ms" % [FAMILY_NAMES[family_index], "开" if Impact.hitstop_enabled else "关", "开" if Impact.reaction_enabled else "关", "开" if Impact.trails_enabled else "关", "开" if Impact.sound_enabled else "关", hits, player.animation.skeletal_clip, player.combat.runner.action_phase, player.combat.hitstop_remaining * 1000]
	return false
func capture() -> void:
	DirAccess.make_dir_recursive_absolute(capture_path)
	for height in [18.0, 32.0]:
		arena.renderer.camera_height = height
		arena.renderer.target_camera_height = height
		for enabled in [false, true]:
			Impact.hitstop_enabled = enabled
			Impact.reaction_enabled = enabled
			Impact.trails_enabled = enabled
			player.combat.reset()
			player.global_position = Vector3(0, .05, 8)
			target.global_position = player.global_position + Vector3.FORWARD * 1.4
			target.combat.reset()
			target.combat.current_poise = 100000
			arena.aim_override = target.global_position
			hits = 0
			await ticks(5)
			for frame in range(210):
				if frame in [10, 38, 78]: mouse(true)
				elif frame in [12, 40, 80]: mouse(false)
				await ticks(1)
				if frame % 4 == 0:
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png(capture_path.path_join("h%d-%s-%03d.png" % [int(height), "on" if enabled else "off", frame]))
			print("LAB_STAGE ", JSON.stringify({"height": height, "feedback": enabled, "hits": hits}))
			if hits != 3:
				push_error("Feedback capture must exercise all three real hits")
	Impact.hitstop_enabled = true
	Impact.reaction_enabled = true
	Impact.trails_enabled = true
	arena.queue_free()
	await ticks(4)
	print("COMBAT_LAB complete")
	quit()
