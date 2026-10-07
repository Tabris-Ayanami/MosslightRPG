extends SceneTree
## Real input + GPU charge presentation sequences, separate from legacy feature gates.
## Godot --path . --rendering-method gl_compatibility --fixed-fps 60 --script tests/combat_charge_visual.gd
const OUTPUT := "res://docs/combat/"
var arena
var checks := 0
var failures := 0
var report: PackedStringArray = []
var images: PackedStringArray = []
var started: PackedStringArray = []
var recording := false
var recorded_frames := 0
var recording_ticks := 0
var frame_directory := ""
const POINTER := Vector2(580, 290)

func _initialize() -> void:
	call_deferred("run")

func verify(ok: bool, message: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	var line := ("PASS " if ok else "FAIL ") + message
	print(line)
	report.append(line)

func tick(count: int = 1) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func mouse(down: bool, secondary := false) -> void:
	var event := InputEventMouseButton.new()
	event.position = POINTER
	event.global_position = POINTER
	event.button_index = MOUSE_BUTTON_RIGHT if secondary else MOUSE_BUTTON_LEFT
	event.pressed = down
	Input.parse_input_event(event)
	await tick(2)
	await RenderingServer.frame_post_draw

func click_skill(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	Input.parse_input_event(motion)
	await tick(2)
	verify(arena.pointer_blocked and not arena.input_blocked, "skill hover blocks only world mouse attacks")
	arena.ui._refresh_hud()
	verify(not button.disabled, "hovered Q remains clickable during primary attack")
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		Input.parse_input_event(event)
		await tick()

func record_frame() -> void:
	if not recording:
		return
	recording_ticks += 1
	if recording_ticks % 2 != 0:
		return
	root.get_texture().get_image().save_png(frame_directory.path_join("frame_%04d.png" % recorded_frames))
	recorded_frames += 1

func key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)
	await tick()

func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		verify(false, "GPU renderer is required")
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	verify(image.save_png(ProjectSettings.globalize_path(OUTPUT + label + ".png")) == OK, "capture " + label)
	images.append(label + ".png")

func prepare(career: String, weapon: String) -> void:
	for action in InputMap.get_actions():
		Input.action_release(action)
	arena.player.input_router.cancel()
	arena.player.loadout.select_career(career)
	arena.player.combat.reset()
	verify(arena.player.loadout.equip_weapon(0, weapon), "prepare " + weapon)
	arena.ui.toggle_menu(false)
	arena.ui._toast_time = 0
	arena.toast_time = 0
	arena.player.global_position = Vector3(0, .1, 8)
	arena.aim_override = Vector3(0, 0, 16)
	arena.aim_point = arena.aim_override
	var motion := InputEventMouseMotion.new()
	motion.position = POINTER
	motion.global_position = POINTER
	Input.parse_input_event(motion)
	await tick(4)

func wait_charge(progress: float) -> void:
	var count := 0
	while arena.player.combat.state == "CHARGING" and arena.player.combat.charge_progress() < progress and count < 120:
		await tick()
		count += 1
	await RenderingServer.frame_post_draw

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1280, 720)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	arena.camera.size = 11
	arena.player.combat.runner.action_started.connect(func(action: Dictionary) -> void: started.append(str(action.get("id", ""))))
	for enemy in arena.enemies:
		enemy.ai_enabled = false
		# Leave actual enemies available for interruption tests, outside our close-up.
		enemy.global_position.z -= 20
	await tick(4)
	var cases := [["SINGLE_BLADE", "warrior", "iron_longsword"], ["SHORT_WEAPON", "warrior", "hunter_dagger"], ["POLEARM", "barbarian", "border_spear"], ["HEAVY_2H", "barbarian", "bone_greataxe"], ["BOW", "rogue", "shortbow"], ["CASTER", "mage", "apprentice_staff"]]
	var full_poses: Dictionary = {}
	for entry in cases:
		var family: String = entry[0]
		await prepare(entry[1], entry[2])
		var visual = arena.player.animation
		var idle: Transform3D = visual._right_arm.transform
		await mouse(true)
		verify(arena.player.combat.state == "CHARGING", family + " mouse press immediately enters charge")
		verify(visual.current_animation == "charging", family + " has feedback before release")
		verify(visual._right_arm.transform != idle, family + " begins visible preparation pose")
		verify(not arena.ui.charge_indicator_visible and arena.ui.charge_indicator_text.is_empty(), family + " has no floating charge bar or text")
		verify(arena.ui._charge_hint_text.is_empty(), family + " preparation leaves the screen clear")
		await wait_charge(.32)
		verify(not visual._charge_aura.visible and not visual._charge_spark.visible, family + " preparation has no persistent timing glow")
		verify(not arena.ui.charge_indicator_visible, family + " partial progress has no percentage panel")
		await capture("charge_" + family.to_lower() + "_01_preparing")
		await wait_charge(1)
		verify(arena.player.combat.charge_ready and visual.current_animation == "charge_ready", family + " full charge is visibly ready while still held")
		verify(visual.body_flash_remaining <= 0 and not visual.precision_glow_active, family + " full charge adds no white cue outside a precision window")
		var signature := str([visual._torso.transform, visual._left_arm.transform, visual._right_arm.transform, visual._weapon.transform])
		verify(not full_poses.has(signature), family + " full preparation differs from other families")
		full_poses[signature] = family
		if family == "BOW":
			verify(visual._bow_string_top.position.z > .1, "bow string visibly drawn before release")
			var attached := true
			for segment in visual._weapon.get_children():
				attached = attached and segment.position.length() < .8
			verify(attached, "bow limbs remain attached after actor moves and weapon is rebuilt")
		await capture("charge_" + family.to_lower() + "_02_full")
		await mouse(false)
		verify(arena.player.combat.state == "ACTION", family + " release begins charged action")
		verify(arena.player.combat.runner.current_action.get("charged_release", false), family + " release feedback follows actual charged action")
		verify(not arena.ui.charge_indicator_visible and not visual._charge_aura.visible, family + " held indicator clears on release")
		verify(visual._right_arm.rotation.length() > .35, family + " release keeps prepared pose instead of snapping idle")
		var frame := 0
		while arena.player.combat.runner.busy() and arena.player.combat.runner.action_phase != "ACTIVE" and frame < 20:
			await tick()
			frame += 1
		verify(visual._release_flash.visible, family + " actual active phase has release feedback")
		await capture("charge_" + family.to_lower() + "_03_release")
		await tick(45)
		verify(not visual._charge_aura.visible and not visual._release_flash.visible and not visual._charge_spark.visible, family + " effects clear after recovery")
	# A held secondary attack is interrupted by actual UI and damage events.
	await prepare("warrior", "iron_longsword")
	verify(arena.player.loadout.weapon_at(0).weapon_type == "Sword", "ordinary sword group exposes secondary charge directly")
	await mouse(true, true)
	await wait_charge(.5)
	verify(not arena.ui.charge_indicator_visible and arena.player.animation.current_animation == "charging", "right mouse shows preparation without a text panel")
	await key(KEY_X, true)
	await key(KEY_X, false)
	verify(arena.ui.menu_open and arena.player.combat.state != "CHARGING", "opening character menu cancels held charge")
	verify(not arena.ui.charge_indicator_visible and not arena.player.animation._charge_aura.visible, "menu cancellation clears all charge presentation")
	await mouse(false, true)
	verify(not arena.player.combat.runner.busy(), "release after menu cancellation cannot resurrect attack")
	arena.ui.toggle_menu(false)
	await tick(3)
	await mouse(true)
	await wait_charge(.45)
	arena.player.combat.receive_damage({"formula": {"base": 1}, "damage_type": "PHYSICAL", "can_crit": false, "poise_damage": 9999}, arena.enemies[0], Vector3.FORWARD)
	await tick(2)
	verify(arena.player.combat.state == "HITSTUN", "real poise break interrupts charging")
	verify(not arena.ui.charge_indicator_visible and not arena.player.animation._charge_aura.visible, "hit interruption clears charge presentation")
	await capture("charge_interrupted_clean")
	await mouse(false)
	await tick(35)
	# Show an actual queued Q command during a primary attack.
	await prepare("warrior", "iron_longsword")
	await mouse(true)
	await mouse(false)
	await key(KEY_Q, true)
	verify(not arena.player.combat.queued_command.is_empty(), "Q queues while primary attack is in progress")
	arena.ui._refresh_hud()
	verify(not arena.ui._chain_text.visible and arena.ui._chain_text.text.is_empty(), "queued skill has no floating transition panel")
	verify(not arena.ui._hud_buttons[0].disabled, "skill input remains enabled for valid attack transition")
	await capture("charge_attack_skill_transition")
	await key(KEY_Q, false)
	await tick(20)
	verify(not arena.ui._chain_text.visible, "transition hint clears when queue is consumed")
	# Native hover -> click -> continued hover must retain and execute the skill intent.
	await prepare("warrior", "iron_longsword")
	await mouse(true)
	await mouse(false)
	var action_count := started.size()
	await click_skill(arena.ui._hud_buttons[0])
	await tick(65)
	verify(arena.pointer_blocked and not arena.input_blocked, "one second of continued skill hover keeps keyboard/gameplay input available")
	verify(started.slice(action_count) == PackedStringArray(["warrior_whirlwind"]), "hovered skill button executes exactly one skill with no extra primary attack")
	verify(arena.player.input_router.buffer.entries.is_empty(), "skill hover and click leave no attack buffer residue")
	# Record a complete real-input sequence at the arena's normal player zoom.
	await prepare("barbarian", "bone_greataxe")
	arena.camera.size = 24
	await tick(8)
	frame_directory = OS.get_environment("TEMP").path_join("mosslight_charge_frames_%d" % int(Time.get_unix_time_from_system()))
	DirAccess.make_dir_recursive_absolute(frame_directory)
	RenderingServer.frame_post_draw.connect(record_frame)
	recording = true
	await tick(12)
	await mouse(true)
	await wait_charge(1)
	await capture("charge_player_view_full_1280")
	await tick(20)
	await mouse(false)
	await tick(55)
	recording = false
	verify(recorded_frames >= 50, "continuous preparing/full/release sequence captured at 30 fps")
	root.size = Vector2i(960, 540)
	arena.ui.debug_open = true
	arena.ui._debug_panel.visible = true
	arena.player.combat.reset()
	await mouse(true)
	await wait_charge(1)
	verify("100% READY" in arena.ui._debug_text.text, "debug readiness matches the full charge HUD on the same frame")
	verify(arena.ui._hp_text.size.y >= arena.ui._hp_text.get_combined_minimum_size().y, "960x540 health label retains its full font line height")
	await capture("charge_player_view_debug_960")
	var debug_bottom: float = arena.ui._debug_panel.get_global_rect().end.y
	var hotbar_top: float = arena.ui.get_node("Hotbar").get_global_rect().position.y
	verify(debug_bottom < hotbar_top, "960x540 debug panel clears the Q/E/R hotbar")
	await mouse(false)
	var summary := "COMBAT_CHARGE_VISUAL_RESULT checks=%d failures=%d captures=%d" % [checks, failures, images.size()]
	print(summary)
	report.append(summary)
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Sequence: each family preparing -> full (button held) -> release (ACTIVE)")
	report.append("VideoFrames: " + frame_directory)
	report.append("RecordedFrames: %d at 30 fps" % recorded_frames)
	var log := FileAccess.open(OUTPUT + "charge_visual_test.log", FileAccess.WRITE)
	log.store_string("\n".join(report) + "\n")
	quit(0 if failures == 0 else 1)
