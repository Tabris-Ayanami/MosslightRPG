extends "res://tests/combat_charge_visual.gd"
## GPU evidence for paired soldier weapons and exact low-intensity precision cues.
var cue_samples := 0

func sample_window(label: String) -> void:
	await RenderingServer.frame_post_draw
	var expected: bool = arena.player.combat.defense.precision_window_active()
	verify(arena.player.animation.precision_glow_active == expected, label + " presentation equals current rule window")
	verify(arena.player.animation.body_flash_remaining <= 0, label + " has no separate white flash timer")
	cue_samples += 1

func select_item(option: OptionButton, id: String) -> void:
	for index in range(option.item_count):
		if option.get_item_metadata(index) == id:
			option.select(index)
			option.item_selected.emit(index)
			await tick(2)
			return
	verify(false, "missing dropdown entry " + id)

func soldier_setup() -> void:
	await prepare("warrior", "iron_longsword")
	arena.player.loadout.set_level(2)
	verify(arena.player.loadout.select_career("soldier"), "choose soldier paired-weapon profession")
	arena.camera.size = 13
	await tick(4)
	arena.floaters.clear()

func run() -> void:
	root.size = Vector2i(1280, 720)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	for enemy in arena.enemies:
		enemy.ai_enabled = false
		enemy.global_position = Vector3(-20, .1, -20)
	await tick(4)
	await soldier_setup()
	var player = arena.player
	var visual = player.animation
	verify(player.loadout.weapon_at(0).weapon_type == "Sword" and player.loadout.weapon_at(1).weapon_type == "Shield", "soldier A sword and B shield are real catalog weapons")
	verify(visual.weapon_family == "SINGLE_BLADE" and is_instance_valid(visual._shield) and visual._shield.visible, "soldier holds sword and shield at once")
	arena.ui.toggle_menu(true)
	arena.ui._tabs.current_tab = 1
	await tick(3)
	verify(arena.ui._weapons.size() == 2, "soldier exposes only the two A/B weapon selectors")
	var only_shields := true
	for index in range(arena.ui._weapons[1].item_count):
		only_shields = only_shields and arena.database.weapons[arena.ui._weapons[1].get_item_metadata(index)].weapon_type == "Shield"
	verify(only_shields, "soldier B dropdown only lists shield weapons")
	await select_item(arena.ui._weapons[1], "buckler")
	verify(player.loadout.sets[1].weapon == "buckler", "native B weapon callback equips a real shield")
	await select_item(arena.ui._weapons[1], "wooden_shield")
	verify("精准" in arena.ui._weapon_description(player.loadout.weapon_at(1)), "shield tooltip explains defense and precision windows")
	await capture("parry_soldier_equipment_1280")
	arena.ui._tabs.current_tab = 0
	await capture("parry_soldier_trait_1280")
	arena.ui.toggle_menu(false)
	await tick(3)
	var sword_id: int = visual._weapon.get_instance_id()
	var shield_id: int = visual._shield.get_instance_id()
	var sword_data: Dictionary = visual.weapon_data.duplicate(true)
	var original_head_material: Material = (visual._head.get_child(0) as MeshInstance3D).material_override
	var original_head_color: Color = original_head_material.get_shader_parameter("base_color")
	frame_directory = OS.get_environment("TEMP").path_join("mosslight_parry_frames_%d" % int(Time.get_unix_time_from_system()))
	DirAccess.make_dir_recursive_absolute(frame_directory)
	RenderingServer.frame_post_draw.connect(record_frame)
	recording = true
	await tick(10)
	await mouse(true, true)
	verify(player.combat.runner.current_action.get("id", "") == "shield_raise", "right mouse immediately starts shield-raise action")
	verify(visual.current_animation == "shield_raise", "shield raise has a level defensive pose")
	await sample_window("shield raise")
	verify(visual.precision_glow_active, "shield raise starts inside precise window")
	verify(visual._precision_overlay.albedo_color.a <= .181 and visual._precision_overlay.emission_energy_multiplier <= .2, "precision overlay is restrained instead of white silhouette")
	verify((visual._head.get_child(0) as MeshInstance3D).material_override == original_head_material and original_head_material.get_shader_parameter("base_color") == original_head_color, "precision overlay retains original skin material")
	await capture("parry_shield_precision_on_1280")
	for index in range(15):
		await tick()
		await sample_window("held shield frame %d" % index)
	verify(player.combat.state == "GUARD" and not visual.precision_glow_active, "holding transitions to ordinary guard with no precision glow")
	await capture("parry_shield_guard_off_1280")
	var skills_a: Array = player.loadout.sets[0].skills.duplicate()
	await key(KEY_SHIFT, true)
	await key(KEY_SHIFT, false)
	verify(player.loadout.current_set == 1 and player.loadout.sets[1].skills != skills_a, "Shift switches to the separate B skill group")
	verify(visual._weapon.get_instance_id() == sword_id and visual._shield.get_instance_id() == shield_id, "Shift preserves the actual sword and shield nodes")
	verify(visual.weapon_data == sword_data and visual._shield.visible, "B skill group still displays both original weapons")
	verify(player.combat.state == "GUARD", "paired skill switch preserves held guard pose")
	await capture("parry_soldier_group_b_guard_1280")
	await mouse(false, true)
	await tick(4)
	await mouse(true)
	await mouse(false)
	verify(str(player.combat.runner.current_action.get("family", player.combat.runner.current_action.get("animation_family", ""))) == "SINGLE_BLADE", "left mouse in B group still performs sword action")
	await tick(5)
	await capture("parry_soldier_group_b_sword_1280")
	await tick(36)
	await mouse(true, true)
	verify(player.combat.runner.current_action.get("id", "") == "shield_raise", "right mouse in B group still raises shield")
	await mouse(false, true)
	await tick(20)
	recording = false
	var paired_frame_directory := frame_directory
	var paired_recorded_frames := recorded_frames
	# Heavy-charge cue and release inheritance at actual input timestamps.
	await prepare("barbarian", "iron_greatsword")
	verify(player.loadout.weapon().weapon_type == "Greatsword", "heavy-window evidence uses an actual greatsword")
	arena.camera.size = 12
	frame_directory = OS.get_environment("TEMP").path_join("mosslight_greatsword_frames_%d" % int(Time.get_unix_time_from_system()))
	DirAccess.make_dir_recursive_absolute(frame_directory)
	recorded_frames = 0
	recording_ticks = 0
	recording = true
	await tick(12)
	await mouse(true)
	await wait_charge(.55)
	await sample_window("heavy early")
	verify(not visual.precision_glow_active, "heavy charge before 65 percent has no precision glow")
	await capture("parry_heavy_before_window_1280")
	await wait_charge(.70)
	await sample_window("heavy precise")
	verify(visual.precision_glow_active, "heavy charge 65 to 85 percent lights precisely")
	await capture("parry_heavy_in_window_1280")
	await mouse(false)
	verify(player.combat.runner.current_action.has("guard_window"), "release inside heavy window inherits slash defense")
	await sample_window("heavy inherited slash")
	await capture("parry_heavy_precision_release_1280")
	await tick(35)
	recording = false
	var greatsword_frame_directory := frame_directory
	var greatsword_recorded_frames := recorded_frames
	frame_directory = paired_frame_directory
	recorded_frames = paired_recorded_frames
	await prepare("barbarian", "iron_greatsword")
	await mouse(true)
	await wait_charge(.90)
	await sample_window("heavy late")
	verify(not visual.precision_glow_active, "heavy precision glow ends beyond 85 percent")
	await capture("parry_heavy_after_window_1280")
	await wait_charge(1)
	verify(not visual.precision_glow_active and visual.body_flash_remaining <= 0, "full charge has no new white cue")
	await mouse(false)
	verify(not player.combat.runner.current_action.has("guard_window"), "late full release has no inherited defense")
	await tick(35)
	# A real parry consumes the light immediately instead of replaying a success flash.
	await soldier_setup()
	var foe = arena.enemies[0]
	foe.combat.reset()
	foe.global_position = player.global_position + Vector3(1.5, 0, -1.2)
	foe.facing = (player.global_position - foe.global_position).normalized()
	arena.aim_override = foe.global_position
	await tick(4)
	verify(foe.combat.use_action(foe.enemy_action), "soldier enemy starts real incoming attack")
	await tick(35)
	await mouse(true, true)
	var waited := 0
	while player.combat.defense.last_outcome != "parry" and waited < 18:
		await tick()
		waited += 1
	await sample_window("after parry consumption")
	verify(player.combat.defense.last_outcome == "parry", "real incoming hit is precisely blocked")
	verify(not visual.precision_glow_active and visual.body_flash_remaining <= 0, "precise hit turns glow off without a success flash")
	await capture("parry_consumed_glow_off_1280")
	await mouse(false, true)
	await tick(30)
	root.size = Vector2i(960, 540)
	arena.ui.debug_open = true
	arena.ui._debug_panel.visible = true
	await mouse(true, true)
	await capture("parry_precision_debug_960")
	verify(arena.ui._debug_panel.get_global_rect().end.y < arena.ui.get_node("Hotbar").get_global_rect().position.y, "precision debug leaves QER visible at 960")
	await mouse(false, true)
	root.size = Vector2i(1280, 720)
	arena.ui.debug_open = false
	arena.ui._debug_panel.visible = false
	arena.ui.toggle_menu(true)
	arena.ui._tabs.current_tab = 3
	await tick(3)
	var drill_button: Button
	for child in arena.ui.find_children("*", "Button", true, false):
		if child.text == "盾防 / 精准练习":
			drill_button = child
	verify(is_instance_valid(drill_button) and "士兵" in drill_button.tooltip_text, "shield drill explains the soldier sword-shield loadout")
	if is_instance_valid(drill_button):
		var point := drill_button.get_global_rect().get_center()
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
		verify(not arena.ui.menu_open and player.loadout.uses_paired_weapons(), "actual practice button enters soldier mode and closes menu")
		verify(player.loadout.weapon_at(0).weapon_type == "Sword" and player.loadout.weapon_at(1).weapon_type == "Shield", "practice entry equips sword and shield in their real weapon slots")
		arena.camera.size = 24
		await tick(4)
		await capture("parry_soldier_practice_1280")
	var summary := "COMBAT_PARRY_VISUAL_RESULT checks=%d failures=%d captures=%d" % [checks, failures, images.size()]
	print(summary)
	report.append(summary)
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("VideoFrames: " + frame_directory)
	report.append("RecordedFrames: %d at 30 fps" % recorded_frames)
	report.append("GreatswordVideoFrames: " + greatsword_frame_directory)
	report.append("GreatswordRecordedFrames: %d at 30 fps" % greatsword_recorded_frames)
	var log := FileAccess.open(OUTPUT + "parry_visual_test.log", FileAccess.WRITE)
	log.store_string("\n".join(report) + "\n")
	quit(0 if failures == 0 else 1)
