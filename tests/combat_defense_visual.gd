extends "res://tests/combat_charge_visual.gd"
## Real Ctrl / mouse / R input with real enemy attack instances and GPU captures.
var foe

func setup_pair(enemy_id: String = "soldier", career: String = "warrior", with_shield: bool = true) -> void:
	await prepare(career, "iron_longsword")
	if with_shield:
		arena.player.loadout.set_level(2)
		arena.player.loadout.select_career("soldier")
	for enemy in arena.enemies:
		enemy.combat.reset()
		enemy.ai_enabled = false
		enemy.global_position = Vector3(-20, .1, -20)
		if enemy.enemy_id == enemy_id:
			foe = enemy
	arena.player.global_position = Vector3(0, .1, 2)
	foe.global_position = Vector3(1.6, .1, .8)
	foe.facing = (arena.player.global_position - foe.global_position).normalized()
	foe.move_direction = Vector3.ZERO
	arena.aim_override = foe.global_position
	arena.aim_point = arena.aim_override
	arena.player.facing = (foe.global_position - arena.player.global_position).normalized()
	arena.camera.size = 14
	await tick(8)
	arena.floaters.clear()
	for effect in arena.effects.get_children():
		effect.queue_free()
	arena.warnings.clear()
	await tick(2)

func wait_outcome(outcome: String, limit: int = 100) -> void:
	var frames := 0
	while arena.player.combat.defense.last_outcome != outcome and frames < limit:
		await tick()
		frames += 1
	await RenderingServer.frame_post_draw
	verify(arena.player.combat.defense.last_outcome == outcome, "real enemy attack resolves " + outcome)

func wait_action(id: String, limit: int = 100) -> void:
	var frames := 0
	while arena.player.combat.runner.current_action.get("id", "") != id and frames < limit:
		await tick()
		frames += 1
	await RenderingServer.frame_post_draw
	verify(arena.player.combat.runner.current_action.get("id", "") == id, "actual reaction starts " + id)

func click_control(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	Input.parse_input_event(motion)
	await tick(2)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		Input.parse_input_event(event)
		await tick(2)

func run() -> void:
	root.size = Vector2i(1280, 720)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	for enemy in arena.enemies:
		enemy.ai_enabled = false
	await tick(3)
	await setup_pair()
	verify(is_instance_valid(arena.player.animation._shield) and arena.player.animation._shield.visible, "soldier B-slot wooden shield is attached")
	verify(arena.ui._weapons.size() == 2, "equipment page has only A and B weapon dropdowns")
	arena.ui.toggle_menu(true)
	arena.ui._tabs.current_tab = 1
	var choice: OptionButton = arena.ui._weapons[1]
	for index in range(choice.item_count):
		if choice.get_item_metadata(index) == "buckler":
			choice.select(index)
			choice.item_selected.emit(index)
			break
	verify(arena.player.loadout.shield().get("id", "") == "buckler", "native dropdown callback equips round shield")
	await capture("defense_equipment_shields_1280")
	arena.ui.toggle_menu(false)
	await key(KEY_CTRL, true)
	verify(arena.player.combat.state == "GUARD", "Ctrl press enters ordinary guard")
	await tick()
	await RenderingServer.frame_post_draw
	verify(arena.player.animation.current_animation == "guard", "guard raises shield before any incoming hit")
	await tick(20)
	await capture("defense_shield_guard_1280")
	verify(foe.combat.use_action(foe.enemy_action), "soldier starts actual attack into held shield")
	await wait_outcome("block")
	verify(arena.player.combat.guard_counter_time > 0, "ordinary block opens weapon riposte opportunity")
	await capture("defense_ordinary_block_1280")
	await mouse(true)
	await mouse(false)
	await wait_action("guard_riposte", 20)
	await tick(6)
	verify(arena.player.animation.current_animation == "counter_slash", "guard reaction presents sword slash")
	await capture("defense_guard_riposte_1280")
	await key(KEY_CTRL, false)
	await setup_pair()
	verify(foe.combat.use_action(foe.enemy_action), "soldier attack starts before timed guard")
	await tick(35)
	await key(KEY_CTRL, true)
	await wait_outcome("parry", 20)
	verify(not arena.player.animation.precision_glow_active and arena.player.animation.body_flash_remaining <= 0, "perfect guard consumes precision glow without a success flash")
	verify(foe.combat.state == "EXPOSED", "perfect guard exposes the attacking enemy")
	verify(foe.animation.current_animation == "exposed", "exposed enemy visibly loses balance")
	await capture("defense_perfect_white_exposed_1280")
	await key(KEY_CTRL, false)
	await setup_pair("soldier", "warrior", false)
	arena.player.loadout.set_level(2)
	verify(arena.player.loadout.select_career("duelist"), "select duelist unlocks negative-sword stance")
	verify(arena.player.loadout.sets[0].skills[2] == "duelist_fujian", "duelist R is automatically negative-sword stance")
	await key(KEY_R, true)
	await key(KEY_R, false)
	await tick(22)
	verify(arena.player.animation.current_animation == "counter_stance_ready" and not arena.player.animation.precision_glow_active and arena.player.animation.body_flash_remaining <= 0, "negative-sword stance is watchful preparation without a white cue")
	var before: Vector3 = arena.player.global_position
	await key(KEY_W, true)
	await tick(6)
	await key(KEY_W, false)
	verify(before.distance_to(arena.player.global_position) < .05, "negative-sword stance remains planted under movement input")
	await capture("defense_fujian_stance_1280")
	verify(foe.combat.use_action(foe.enemy_action), "soldier starts real attack into negative-sword stance")
	await wait_action("fujian_counter")
	await tick(6)
	verify(arena.player.animation.current_animation == "counter_slash", "negative-sword reaction visibly swings instead of holding stance")
	await capture("defense_fujian_counter_1280")
	# Red warning -> extended startup -> actual grapple, encoded as an uncut sequence.
	await setup_pair("ogre")
	frame_directory = OS.get_environment("TEMP").path_join("mosslight_defense_frames_%d" % int(Time.get_unix_time_from_system()))
	DirAccess.make_dir_recursive_absolute(frame_directory)
	RenderingServer.frame_post_draw.connect(record_frame)
	recording = true
	await key(KEY_CTRL, true)
	await tick(20)
	verify(foe.combat.use_action(foe.grab_action), "ogre starts catalog grab through action runner")
	await tick(2)
	verify(foe.animation.body_flash_remaining > 0 and foe.animation.body_flash_color.r > .8 and foe.animation.body_flash_color.g < .4, "grab startup has visible whole-body red warning")
	verify(float(foe.grab_action.startup) >= 1.0, "grab gives at least one second of startup")
	verify(foe.animation.current_animation == "grab_windup", "grab has distinct open-arm preparation")
	await capture("defense_grab_red_warning_1280")
	await tick(54)
	verify(foe.animation.body_flash_remaining > 0 and foe.animation.body_flash_color.g < .4, "grab repeats red warning immediately before contact")
	await capture("defense_grab_preimpact_red_1280")
	var waited := 0
	while arena.player.combat.state != "GRABBED" and waited < 35:
		await tick()
		waited += 1
	await RenderingServer.frame_post_draw
	verify(arena.player.combat.state == "GRABBED", "actual grab defeats held shield")
	verify(arena.player.animation.current_animation == "grabbed" and foe.animation.current_animation == "grabbing", "both participants present the grapple states")
	await capture("defense_grab_held_1280")
	await tick(80)
	recording = false
	verify(arena.player.combat.state != "GRABBED" and foe.combat.state != "GRABBING", "grapple presentation exits after actual control duration")
	await key(KEY_CTRL, false)
	# Full charge creates no timing cue outside a real precision-defense window.
	await setup_pair()
	foe.global_position = Vector3(20, .1, -20)
	await mouse(true)
	await wait_charge(1)
	verify(not arena.ui.charge_indicator_visible and not arena.ui._chain_text.visible, "screen contains neither charge bar nor transition floating strip")
	verify(arena.player.animation.body_flash_remaining <= 0 and not arena.player.animation.precision_glow_active, "full charge creates no white cue")
	var clear := true
	for mesh in arena.player.animation._rig.find_children("*", "MeshInstance3D", true, false):
		clear = clear and mesh.material_overlay == null
	verify(clear, "full charge leaves body equipment and weapon overlays clear")
	await capture("defense_charge_white_flash_1280")
	await tick(14)
	verify(arena.player.animation.body_flash_remaining <= 0 and arena.player.animation._precision_meshes.is_empty(), "continuing to hold full charge leaves precision light off")
	await mouse(false)
	await tick(45)
	root.size = Vector2i(960, 540)
	arena.ui.debug_open = true
	arena.ui._debug_panel.visible = true
	await key(KEY_CTRL, true)
	await tick(3)
	await capture("defense_debug_960")
	verify(arena.ui._debug_panel.get_global_rect().end.y < arena.ui.get_node("Hotbar").get_global_rect().position.y, "960x540 defense debug leaves QER visible")
	verify("Defense:" in arena.ui._debug_text.text and "Guard:" in arena.ui._debug_text.text, "debug exposes defense result and guard window")
	await key(KEY_CTRL, false)
	root.size = Vector2i(1280, 720)
	arena.ui.debug_open = false
	arena.ui._debug_panel.visible = false
	for entry in [["shield", "盾防 / 精准练习"], ["counter", "负剑反击练习"], ["grab", "红光抓取练习"]]:
		arena.ui.toggle_menu(true)
		arena.ui._tabs.current_tab = 3
		await tick(3)
		if entry[0] == "shield":
			await capture("defense_practice_menu_1280")
		var button: Button
		for child in arena.ui.find_children("*", "Button", true, false):
			if child.text == entry[1]:
				button = child
		verify(is_instance_valid(button), "practice button exists: " + entry[0])
		if is_instance_valid(button):
			await click_control(button)
			verify(not arena.ui.menu_open and not arena.input_blocked, "real practice click closes menu: " + entry[0])
			if entry[0] == "counter":
				verify(arena.player.loadout.sets[0].skills[2] == "duelist_fujian", "counter drill directly equips negative-sword skill")
			elif entry[0] == "shield":
				verify(arena.player.loadout.uses_paired_weapons() and arena.player.loadout.weapon_at(0).weapon_type == "Sword" and arena.player.loadout.weapon_at(1).weapon_type == "Shield", "shield drill equips soldier with real A sword and B shield")
			else:
				var found_grab := false
				for enemy in arena.enemies:
					found_grab = found_grab or not enemy.grab_action.is_empty()
				verify(found_grab, "grab drill provides a red-warning grappler")
	var summary := "COMBAT_DEFENSE_VISUAL_RESULT checks=%d failures=%d captures=%d" % [checks, failures, images.size()]
	print(summary)
	report.append(summary)
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Protocol: compatibility update; precision-window-only glow, no full-charge/counter/success flash; current primary evidence is combat_parry_visual.gd")
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("VideoFrames: " + frame_directory)
	report.append("RecordedFrames: %d at 30 fps" % recorded_frames)
	var log := FileAccess.open(OUTPUT + "defense_visual_test.log", FileAccess.WRITE)
	log.store_string("\n".join(report) + "\n")
	quit(0 if failures == 0 else 1)
