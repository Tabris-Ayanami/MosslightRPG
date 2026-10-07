extends SceneTree
## Reproduce UI interaction checks and reviewable rendered evidence:
## Godot --path . --rendering-method gl_compatibility --script tests/combat_ui.gd
## Headless runs execute assertions but intentionally skip image capture.

const Visual = preload("res://combat/animation_controller.gd")
const Database = preload("res://combat/combat_database.gd")
const OUTPUT := "res://docs/combat/"
var arena
var checks := 0
var failures: PackedStringArray = []
var report: PackedStringArray = []
var captures: PackedStringArray = []
var database := Database.new()
var showcase: Node3D

func _initialize() -> void:
	call_deferred("run")

func verify(condition: bool, label: String) -> void:
	checks += 1
	var line := ("PASS " if condition else "FAIL ") + label
	print(line)
	report.append(line)
	if not condition:
		failures.append(label)

func ticks(count: int = 3) -> void:
	for i in range(count):
		await process_frame
		await physics_frame

func key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await ticks(2)
	event = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = false
	Input.parse_input_event(event)
	await ticks(2)

func click(button: BaseButton) -> void:
	var center := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = center
	motion.global_position = center
	Input.parse_input_event(motion)
	await ticks(3)
	verify(arena.pointer_blocked and not arena.input_blocked, "hovering native HUD button suppresses pointer attack input only")
	var before_move: Vector3 = arena.player.global_position
	Input.action_press("move_right")
	await ticks(3)
	Input.action_release("move_right")
	verify(arena.player.global_position.distance_to(before_move) > .02, "keyboard movement remains available while hovering HUD")
	var event := InputEventMouseButton.new()
	event.position = center
	event.global_position = center
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	Input.parse_input_event(event)
	await ticks(1)
	event = InputEventMouseButton.new()
	event.position = center
	event.global_position = center
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	Input.parse_input_event(event)
	await ticks(1)

func select(option: OptionButton, id: String) -> void:
	for index in range(option.item_count):
		if str(option.get_item_metadata(index)) == id:
			verify(not option.is_item_disabled(index), "native option enabled: " + id)
			option.item_selected.emit(index)
			return
	verify(false, "native option exists: " + id)

func option_index(option: OptionButton, id: String) -> int:
	for index in range(option.item_count):
		if str(option.get_item_metadata(index)) == id:
			return index
	return -1

func shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await ticks(3)
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var result := image.save_png(ProjectSettings.globalize_path(OUTPUT + name + ".png"))
	verify(result == OK, "capture " + name + " (" + str(image.get_width()) + "x" + str(image.get_height()) + ")")
	captures.append(name + ".png")

func run() -> void:
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("InputPolicy: menus block gameplay; HUD hover blocks pointer attacks only")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1280, 720)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	for enemy in arena.enemies:
		enemy.ai_enabled = false
	await ticks(5)
	verify(arena.ui.menu_open and arena.player.loadout.level == 0, "Lv0 opens career menu")
	verify(arena.ui._equipment.size() == 8, "all eight equipment slots are present")
	verify(arena.ui._skill_options.size() == 2 and arena.ui._skill_options[0].size() == 3, "A/B each expose Q/E/R")
	await shot("ui_character_1280")
	await key(KEY_X)
	verify(not arena.ui.menu_open, "physical C closes menu")
	await key(KEY_F10)
	verify(arena.ui.debug_open and arena.ui._debug_panel.visible, "physical F10 opens debug overlay")
	await key(KEY_F10)
	verify(not arena.ui.debug_open, "physical F10 closes debug overlay")
	arena.player.global_position = arena.chest_position + Vector3(0, 0.1, 2)
	await key(KEY_F)
	verify(arena.ui.menu_open, "physical F opens equipment chest menu")
	arena.ui._choose_career("warrior")
	verify(arena.player.loadout.level == 1, "career menu transitions Lv0 to Lv1")
	arena.player.loadout.set_level(3)
	arena.ui._choose_career("swordsman")
	verify(arena.player.loadout.career_ids == ["warrior", "swordsman"], "subclass menu follows career branch")
	for pair in [["head", "iron_helm"], ["torso", "plate_armor"], ["legs", "iron_greaves"], ["feet", "hunter_boots"], ["belt", "vigor_belt"], ["ring1", "qi_ring"], ["ring2", "hunter_ring"], ["neck", "scholar_pendant"]]:
		select(arena.ui._equipment[pair[0]], pair[1])
		verify(arena.player.loadout.equipment[pair[0]] == pair[1], "equipment callback changes " + pair[0])
	select(arena.ui._weapons[1], "azure_katana")
	verify(arena.player.loadout.sets[1].weapon == "azure_katana", "B weapon callback changes independent set")
	select(arena.ui._skill_options[1][2], "warrior_whirlwind")
	verify(arena.player.loadout.sets[1].skills[2] == arena.player.loadout.sets[0].skills[0], "native loadout permits same skill in both sets")
	arena.ui._tabs.current_tab = 1
	await shot("ui_equipment_1280")
	root.size = Vector2i(960, 540)
	arena.ui._tabs.current_tab = 2
	await shot("ui_skills_960")
	arena.ui._tabs.current_tab = 3
	await shot("ui_debug_tools_960")
	root.size = Vector2i(1280, 720)
	arena.ui._choose_career("mage")
	arena.ui._refresh_menu()
	var head: OptionButton = arena.ui._equipment.head
	var blocked := option_index(head, "iron_helm")
	verify(blocked >= 0 and head.is_item_disabled(blocked), "equipment requirement grays unavailable iron helmet")
	verify("CON" in head.get_popup().get_item_tooltip(blocked), "equipment tooltip includes actual requirement failure")
	arena.ui.toggle_menu(false)
	arena.ui._refresh_hud()
	verify(arena.ui._quick_buttons[0].disabled, "full HP grays healing potion")
	verify(arena.ui._quick_buttons[1].disabled, "mage cannot consume irrelevant Qi potion")
	verify(arena.ui._quick_buttons[2].disabled, "full spell slots gray spell potion")
	arena.player.resources.change("SpellSlot", -1)
	arena.ui._refresh_hud()
	verify(not arena.ui._quick_buttons[2].disabled, "missing spell slot enables spell potion")
	arena.ui._choose_career("warrior")
	arena.ui.toggle_menu(false)
	arena.player.global_position = Vector3(0, 0.1, 8)
	arena.aim_override = Vector3(0, 0, -3)
	await ticks(5)
	var serial: int = arena.player.combat.serial
	await click(arena.ui._hud_buttons[1])
	verify(arena.player.combat.runner.current_action.get("id", "") == "warrior_thrust", "native HUD click casts selected skill")
	verify(arena.player.combat.serial == serial + 1, "HUD skill click creates exactly one action")
	verify(arena.player.input_router.buffer.entries.is_empty(), "HUD click does not enqueue a world weapon attack")
	arena.player.combat.reset()
	serial = arena.player.combat.serial
	await click(arena.ui.get_node("TopButtons").get_child(0))
	verify(arena.ui.menu_open, "native C menu button opens menu")
	verify(arena.player.combat.serial == serial and arena.player.input_router.buffer.entries.is_empty(), "menu click never triggers or buffers a weapon attack")
	await key(KEY_ESCAPE)
	verify(not arena.ui.menu_open, "physical Escape closes menu")
	arena.player.combat.cooldowns["warrior_whirlwind"] = 4.5
	arena.ui._refresh_hud()
	verify(arena.ui._hud_buttons[0].disabled and "技能冷却中" in arena.ui._hud_buttons[0].tooltip_text, "cooldown grays skill with reason")
	arena.locked_target = arena.enemies[1]
	await key(KEY_F10)
	arena.ui._refresh_debug()
	for label in ["State", "InCombat", "CurrentAction", "ActionPhase", "ActionTime", "CurrentWeapon", "WeaponType", "AnimationFamily", "CombatSet", "HP", "Stamina", "Qi", "SpellSlot", "Poise", "InputBuffer", "Q:", "E:", "R:", "LockedTarget", "TargetHP", "TargetPoise", "LastDamage", "LastCrit", "LastDamageType", "LastConditionFailed"]:
		verify(label in arena.ui._debug_text.text, "debug field " + label)
	arena.float_text(arena.player.global_position + Vector3.UP * 2, "暴击 192", Color("ffcc77"))
	await shot("ui_hud_1280")
	root.size = Vector2i(960, 540)
	await shot("ui_hud_960")
	arena.queue_free()
	await ticks(3)
	root.size = Vector2i(1280, 720)
	await verify_visuals()
	var summary := "COMBAT_UI_RESULT checks=%d failures=%d captures=%d" % [checks, failures.size(), captures.size()]
	print(summary)
	report.append(summary)
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("Captures: " + ", ".join(captures))
	var log := FileAccess.open(OUTPUT + "ui_visual_test.log", FileAccess.WRITE)
	log.store_string("\n".join(report) + "\n")
	quit(0 if failures.is_empty() else 1)

func make_showcase() -> void:
	showcase = Node3D.new()
	root.add_child(showcase)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("14212d")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color("c7d8e7")
	world.environment.ambient_light_energy = 0.75
	showcase.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.4
	showcase.add_child(sun)
	var camera := Camera3D.new()
	showcase.add_child(camera)
	camera.look_at_from_position(Vector3(3, 10, 13), Vector3(0, 0.8, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8.0
	camera.current = true

func add_model(at: Vector3, label: String) -> Node3D:
	var actor := Visual.new()
	showcase.add_child(actor)
	actor.position = at
	actor.setup(true, Color("71cabc"))
	actor.update_pose(1, Vector3.BACK, "NORMAL", "NONE", 0)
	var caption := Label3D.new()
	caption.text = label
	caption.position = at + Vector3(0, 2.15, 0)
	caption.font_size = 30
	caption.pixel_size = 0.009
	caption.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	showcase.add_child(caption)
	return actor

func geometry(node: Node) -> String:
	var parts: PackedStringArray = []
	if node is MeshInstance3D:
		parts.append(node.mesh.get_class() + str(node.mesh.get_aabb()) + str(node.transform))
		if node.material_override is ShaderMaterial:
			parts.append(str(node.material_override.get_shader_parameter("base_color")))
	for child in node.get_children():
		parts.append(geometry(child))
	return "|".join(parts)

func pose(actor: Node3D) -> String:
	return str([actor._torso.transform, actor._head.transform, actor._left_arm.transform, actor._right_arm.transform, actor._weapon.transform, actor._left_leg.transform, actor._spell_glow.scale])

func verify_visuals() -> void:
	make_showcase()
	var slots := ["head", "torso", "legs", "feet"]
	var variants := [["scout_hood", "iron_helm"], ["linen_tunic", "plate_armor"], ["traveler_pants", "iron_greaves"], ["soft_shoes", "hunter_boots"]]
	for column in range(4):
		var signatures: PackedStringArray = []
		for row in range(2):
			var data: Dictionary = database.equipment[variants[column][row]]
			var actor = add_model(Vector3((column - 1.5) * 2.9, 0, row * 5.0 - 2.5), str(data.name))
			actor.equip(slots[column], data)
			signatures.append(geometry(actor._slots[actor._slot_key(slots[column])][0]))
		verify(signatures[0] != signatures[1], "equipped " + slots[column] + " variants change real mesh geometry/material")
	await shot("visual_equipment_variants_1280")
	showcase.queue_free()
	await ticks(2)
	make_showcase()
	var families := ["SINGLE_BLADE", "SHORT_WEAPON", "POLEARM", "HEAVY_2H", "BOW", "CASTER"]
	var weapons := ["iron_longsword", "hunter_dagger", "border_spear", "bone_greataxe", "shortbow", "apprentice_staff"]
	var actors: Array = []
	var weapon_signatures: PackedStringArray = []
	for index in range(6):
		var family: String = families[index]
		var actor = add_model(Vector3((index % 3 - 1) * 3.7, 0, floorf(index / 3.0) * 5.0 - 2.5), family)
		actor.switch_weapon_family(family, database.weapons[weapons[index]])
		var signature := geometry(actor._weapon)
		verify(signature not in weapon_signatures, family + " has distinct weapon model")
		weapon_signatures.append(signature)
		var idle := pose(actor)
		var action_signatures: PackedStringArray = []
		for semantic in ["PRIMARY_TAP", "PRIMARY_CHARGE", "SECONDARY_TAP", "SECONDARY_CHARGE"]:
			actor.play_action(database.get_action(family, semantic))
			for phase in ["STARTUP", "ACTIVE", "RECOVERY"]:
				actor.update_pose(0, Vector3.BACK, "ACTION", phase, 0.5)
				verify(pose(actor) != idle, family + " " + semantic + " " + phase + " produces action pose")
			actor.update_pose(0, Vector3.BACK, "ACTION", "ACTIVE", 0.5)
			action_signatures.append(pose(actor))
		var unique: Dictionary = {}
		for value in action_signatures:
			unique[value] = true
		verify(unique.size() == 4, family + " four input semantics have distinguishable poses")
		actor.update_pose(0, Vector3.BACK, "NORMAL", "NONE", 0)
		actors.append(actor)
	await shot("visual_six_families_idle_1280")
	for index in range(actors.size()):
		actors[index].play_action(database.get_action(families[index], "PRIMARY_TAP"))
		actors[index].update_pose(0, Vector3.BACK, "ACTION", "ACTIVE", 0.5)
	await shot("visual_six_families_action_1280")
	var caster = actors.back()
	caster.play_action(database.get_action("CASTER", "PRIMARY_CHARGE"))
	caster.update_pose(0, Vector3.BACK, "ACTION", "ACTIVE", 0.5)
	var staff_pose := str([caster._left_arm.transform, caster._right_arm.transform, caster._torso.transform])
	var staff_mesh := geometry(caster._weapon)
	caster.switch_weapon_family("CASTER", database.weapons.storm_orb)
	caster.update_pose(0, Vector3.BACK, "ACTION", "ACTIVE", 0.5)
	verify(staff_pose == str([caster._left_arm.transform, caster._right_arm.transform, caster._torso.transform]), "staff and orb share caster body animation")
	verify(staff_mesh != geometry(caster._weapon) and caster._weapon.position.z < 0, "orb uses distinct mesh and forward floating attachment")
	for state in ["MOVE", "DODGE", "HITSTUN", "KNOCKDOWN", "DEAD"]:
		caster.play_locomotion(true)
		caster.play_dodge(false)
		caster.play_hit(state)
		caster.update_pose(0.2, Vector3.BACK, state, "NONE", 0.5)
		verify(caster._rig.transform != Transform3D.IDENTITY or caster._left_leg.rotation.length() > 0, "adapter presents state " + state)
	showcase.queue_free()
	await ticks(2)
