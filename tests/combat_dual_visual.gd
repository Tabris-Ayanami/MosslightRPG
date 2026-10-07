extends "res://tests/combat_charge_visual.gd"
## Real input, actual damage dispatch and GPU frames for Lv10 dual swords.
var foe
var hits: Array[Dictionary] = []
var actions: PackedStringArray = []

func capture_now(label: String) -> void:
	var result := root.get_texture().get_image().save_png(ProjectSettings.globalize_path(OUTPUT + label + ".png"))
	verify(result == OK, "capture " + label)
	images.append(label + ".png")

func button_named(label: String) -> Button:
	for child in arena.ui.find_children("*", "Button", true, false):
		if child.text == label:
			return child
	return null

func click_control(button: Button) -> void:
	verify(is_instance_valid(button), "native button available")
	if not is_instance_valid(button):
		return
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

func reset_pair() -> void:
	arena.player.combat.reset()
	foe.combat.reset()
	foe.resources.configure("HP", 100000)
	arena.player.global_position = Vector3(0, .1, 4)
	foe.global_position = Vector3(1.35, .1, 2.95)
	foe.velocity = Vector3.ZERO
	foe.facing = (arena.player.global_position - foe.global_position).normalized()
	arena.aim_override = foe.global_position
	arena.aim_point = foe.global_position
	arena.player.facing = (foe.global_position - arena.player.global_position).normalized()
	arena.floaters.clear()
	arena.toast_time = 0
	arena.ui._toast_time = 0
	for effect in arena.effects.get_children():
		effect.queue_free()
	arena.warnings.clear()
	var motion := InputEventMouseMotion.new()
	motion.position = POINTER
	motion.global_position = POINTER
	Input.parse_input_event(motion)
	await tick(3)
	hits.clear()
	actions.clear()

func observe_dual(label: String, expected_template: String = "slash") -> void:
	var seen_a := false
	var seen_b := false
	var pose_a := ""
	var pose_b := ""
	var frame := 0
	var spin_angles: Array[Array] = [[], []]
	var action_origin: Vector3 = arena.player.global_position
	var max_action_motion := 0.0
	verify(str(arena.player.combat.runner.current_action.get("dual_sequence", {}).get("template", "slash")) == expected_template, label + " uses shared " + expected_template + " template")
	while arena.player.combat.runner.busy() and frame < 120:
		await tick()
		await RenderingServer.frame_post_draw
		var visual = arena.player.animation
		max_action_motion = maxf(max_action_motion, action_origin.distance_to(arena.player.global_position))
		if visual._blade_trail.visible and visual.dual_pose_progress[0] >= .35 and not seen_a:
			seen_a = true
			pose_a = str([visual._right_arm.transform, visual._left_arm.transform, visual._torso.transform])
			verify(visual.dual_strike_index == 1 and visual.dual_weapon_index == 0 and not visual._second_blade_trail.visible, label + " second dispatch shows only right A sword trail")
			capture_now("dual_" + label + "_a_1280")
		if visual._second_blade_trail.visible and visual.dual_pose_progress[1] >= .35 and not seen_b:
			seen_b = true
			pose_b = str([visual._right_arm.transform, visual._left_arm.transform, visual._torso.transform])
			verify(visual.dual_strike_index == 0 and visual.dual_weapon_index == 1 and not visual._blade_trail.visible, label + " first dispatch shows only left B sword trail")
			capture_now("dual_" + label + "_b_1280")
		if expected_template == "spin" and (visual._blade_trail.visible or visual._second_blade_trail.visible):
			spin_angles[visual.dual_weapon_index].append(visual._rig.rotation.y)
		frame += 1
	verify(seen_a and seen_b and pose_a != pose_b, label + " has two distinct sequential poses")
	verify(hits.size() == 2, label + " actual enemy receives exactly two damage events")
	if hits.size() == 2:
		verify(hits[0].time < hits[1].time and hits[0].strike == 0 and hits[1].strike == 1 and hits[0].weapon == 1 and hits[1].weapon == 0, label + " damage and animation both execute left B before right A")
	if expected_template == "spin":
		for index in range(2):
			var angles: Array = spin_angles[index]
			verify(angles.size() >= 6 and float(angles.max()) - float(angles.min()) > 4.7, label + " blade " + str(index) + " visibly traverses its complete turn")
	if expected_template == "thrust":
		verify(max_action_motion < 3.2, label + " mirrored animation adds no second dash")
	verify(not arena.player.animation._blade_trail.visible and not arena.player.animation._second_blade_trail.visible, label + " both trails clear after recovery")

func run() -> void:
	root.size = Vector2i(1280, 720)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	for enemy in arena.enemies:
		enemy.ai_enabled = false
		enemy.global_position = Vector3(-20, .1, -20)
	foe = arena.enemies[0]
	await tick(3)
	arena.ui._choose_career("warrior")
	arena.player.loadout.set_level(2)
	arena.ui._refresh_menu()
	await click_control(button_named("剑士"))
	verify("swordsman" in arena.player.loadout.career_ids, "native career button advances to swordsman")
	await click_control(button_named("Lv10"))
	verify(arena.player.loadout.level == 10, "native level shortcut reaches Lv10")
	await click_control(button_named("二刀流"))
	verify(arena.player.loadout.is_dual_wielding(), "native career button unlocks Lv10 dual swords")
	await capture("dual_career_lv10_1280")
	arena.ui._tabs.current_tab = 1
	await tick(3)
	verify(arena.ui._weapons.size() == 2, "equipment exposes exactly A and B weapon dropdowns")
	var old_terms := false
	for label in arena.ui.find_children("*", "Label", true, false):
		old_terms = old_terms or "主手" in label.text or "副手" in label.text
	verify(not old_terms, "user-visible labels contain no main/offhand concept")
	await capture("dual_equipment_ab_1280")
	arena.ui.toggle_menu(false)
	arena.camera.size = 13
	await reset_pair()
	var visual = arena.player.animation
	verify(is_instance_valid(visual._dual_weapon) and not is_instance_valid(visual._shield), "both sword models are attached without a shield")
	verify(visual.weapon_data.id == arena.player.loadout.weapon_at(0).id and visual.dual_weapon_data.id == arena.player.loadout.weapon_at(1).id, "each sword model uses its own A/B weapon data")
	var sword_a: int = visual._weapon.get_instance_id()
	var sword_b: int = visual._dual_weapon.get_instance_id()
	await capture("dual_both_swords_idle_1280")
	arena.player.combat.damage_dealt.connect(func(result: Dictionary) -> void:
		hits.append({"time": arena.player.combat.runner.action_time, "strike": visual.dual_strike_index, "weapon": visual.dual_weapon_index, "damage": result.get("final", 0)}))
	arena.player.combat.runner.action_started.connect(func(action: Dictionary) -> void: actions.append(str(action.get("id", ""))))
	frame_directory = OS.get_environment("TEMP").path_join("mosslight_dual_frames_%d" % int(Time.get_unix_time_from_system()))
	DirAccess.make_dir_recursive_absolute(frame_directory)
	RenderingServer.frame_post_draw.connect(record_frame)
	recording = true
	await tick(12)
	await mouse(true)
	await mouse(false)
	await observe_dual("primary")
	await tick(10)
	await key(KEY_SHIFT, true)
	await key(KEY_SHIFT, false)
	verify(arena.player.loadout.current_set == 1 and visual._weapon.get_instance_id() == sword_a and visual._dual_weapon.get_instance_id() == sword_b, "Shift changes QER while preserving both sword nodes")
	await reset_pair()
	await mouse(true, true)
	await mouse(false, true)
	await observe_dual("secondary")
	await tick(10)
	# Charged preparation and release still execute one strike with each sword.
	await reset_pair()
	await mouse(true)
	await wait_charge(.7)
	verify(visual._left_arm.rotation.length() > 1.0 and visual._right_arm.rotation.length() > 1.0, "charging raises and prepares both swords")
	await capture("dual_charge_preparation_1280")
	await mouse(false)
	await observe_dual("charged")
	# One input pays once, while the shared template executes B then A.
	for entry in [["warrior_whirlwind", "spin"], ["warrior_thrust", "thrust"], ["swordsman_fan_slash", "slash"]]:
		await reset_pair()
		var skill_id: String = entry[0]
		var template: String = entry[1]
		verify(arena.player.loadout.assign_skill(arena.player.loadout.current_set, 1, skill_id), "assign dual skill " + skill_id)
		if template == "thrust":
			foe.global_position = arena.player.global_position + Vector3(.78, 0, -.625).normalized() * 4.4
			arena.aim_override = foe.global_position
			arena.aim_point = foe.global_position
		await tick(12)
		var qi_before: float = arena.player.resources.current("Qi")
		await key(KEY_E, true)
		await key(KEY_E, false)
		var action: Dictionary = arena.player.combat.runner.current_action
		verify(action.get("is_skill", false) and action.get("dual_wield", false), skill_id + " uses one skill action with two weapon segments")
		await observe_dual("skill_" + template, template)
		verify(actions.size() == 1, skill_id + " starts only one paid skill action")
		var expected_cost := float(arena.database.skills[skill_id].get("costs", {}).get("Qi", 0))
		verify(is_equal_approx(qi_before - arena.player.resources.current("Qi"), expected_cost), skill_id + " pays the skill Qi cost once")
		verify(float(arena.player.combat.cooldowns.get(skill_id, 0)) > 0, skill_id + " has one running cooldown")
		verify(is_instance_valid(visual._dual_weapon), skill_id + " retains the second sword model")
		verify("左剑 B → 右剑 A" in arena.ui._skill_description(arena.database.skills[skill_id]) and "各结算一次" in arena.ui._skill_description(arena.database.skills[skill_id]), skill_id + " tooltip explains mirrored segments and single costs/movement")
		await tick(12)
	recording = false
	# New practice button is a direct playable user entry, using actual UI clicks.
	arena.ui.toggle_menu(true)
	arena.ui._tabs.current_tab = 3
	await tick(3)
	await capture("dual_practice_menu_1280")
	await click_control(button_named("二刀流练习"))
	verify(not arena.ui.menu_open and arena.player.loadout.is_dual_wielding(), "practice button enters dual-sword mode and closes menu")
	arena.camera.size = 24
	await tick(4)
	await capture("dual_practice_player_view_1280")
	root.size = Vector2i(960, 540)
	arena.ui.debug_open = true
	arena.ui._debug_panel.visible = true
	await capture("dual_debug_960")
	verify(arena.ui._debug_panel.get_global_rect().end.y < arena.ui.get_node("Hotbar").get_global_rect().position.y, "dual-sword debug leaves QER visible at 960")
	arena.player.combat.reset()
	arena.player.loadout.set_level(9)
	await tick(2)
	verify(not arena.player.loadout.is_dual_wielding() and not is_instance_valid(arena.player.animation._dual_weapon), "dropping below Lv10 removes the second sword model")
	var summary := "COMBAT_DUAL_VISUAL_RESULT checks=%d failures=%d captures=%d" % [checks, failures, images.size()]
	print(summary)
	report.append(summary)
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("VideoFrames: " + frame_directory)
	report.append("RecordedFrames: %d at 30 fps" % recorded_frames)
	var log := FileAccess.open(OUTPUT + "dual_visual_test.log", FileAccess.WRITE)
	log.store_string("\n".join(report) + "\n")
	quit(0 if failures == 0 else 1)
