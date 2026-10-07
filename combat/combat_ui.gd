extends Control
## Native, resizable arena HUD. The arena sets `arena` before adding this node.

const INK := Color("101f27")
const PANEL := Color("19323a")
const TEXT := Color("f1e7ce")
const MINT := Color("7adac5")
const GOLD := Color("e8c480")
const MUTED := Color("9eb5b3")
const ENERGY_BAR = preload("res://scripts/frontend/hud_energy_bar.gd")
const MOVEMENT_BUTTON = preload("res://scripts/frontend/hud_movement_button.gd")
const SLOT_NAMES := {"head": "头部", "torso": "上衣", "legs": "裤子", "feet": "鞋子", "belt": "腰带", "ring1": "戒指 Ⅰ", "ring2": "戒指 Ⅱ", "neck": "项链"}
const QUALITY := {"Common": Color("eeeeea"), "Fine": Color("8bd095"), "Rare": Color("8abbff"), "Epic": Color("d39aff"), "Legendary": Color("ef7977")}
var arena
var menu_open := false
var debug_open := false
var _health: ProgressBar
var _hp_text: Label
var _identity: Label
var _resources: Control
var _weapon_text: Label
var _target_text: Label
var _notification: Label
var _toast_time := 0.0
var _hud_buttons: Array[Button] = []
var _quick_buttons: Array[Button] = []
var _movement_buttons: Array[Button] = []
var _menu_shade: ColorRect
var _menu_panel: PanelContainer
var _tabs: TabContainer
var _character_info: Label
var _passive_info: Label
var _subclasses: HBoxContainer
var _weapons: Array[OptionButton] = []
var _gear_explanation: Label
var _gear_header: Label
var _career_feature: Label
var _equipment: Dictionary = {}
var _skill_options: Array = []
var _menu_error: Label
var _debug_panel: PanelContainer
var _debug_text: Label
var _refresh_clock := 0.0
var _refreshing := false
var charge_indicator_visible := false
var charge_indicator_text := ""
var _charge_progress_display := 0.0
var _charge_ready_display := false
var _charge_hint_text := ""
var _chain_text: Label
var stamina_ring = preload("res://combat/stamina_ring.gd").new()
var battle_hud = preload("res://combat/battle_hud.gd").new()

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = _make_theme()
	_build_hud()
	_build_menu()
	_build_debug_overlay()
	stamina_ring.attach(self)
	battle_hud.attach(self)
	resized.connect(_layout)
	if arena.player.loadout.has_signal("changed"):
		arena.player.loadout.changed.connect(_refresh_menu)
	_layout()
	_refresh_menu()
	_refresh_hud()
	if arena.player.loadout.level == 0:
		toggle_menu(true)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("combat_menu"):
		toggle_menu(not menu_open)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("combat_debug"):
		debug_open = not debug_open
		_debug_panel.visible = debug_open
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("combat_pause") and menu_open:
		toggle_menu(false)
		get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not is_instance_valid(arena) or not is_instance_valid(arena.player):
		return
	var hovered := get_viewport().gui_get_hovered_control()
	var over_button := hovered is BaseButton and is_ancestor_of(hovered)
	if arena.controlled_actor().input_router:
		if menu_open and not arena.input_blocked:
			arena.controlled_actor().input_router.cancel()
		elif over_button and not arena.pointer_blocked and not arena.controlled_actor().input_router.selection_active() and not arena.controlled_actor().input_router.cast_pending():
			arena.controlled_actor().input_router.cancel_pointer()
	arena.input_blocked = menu_open
	arena.pointer_blocked = over_button
	for i in range(_movement_buttons.size()):
		var movement: Node=arena.controlled_actor().movement_actions
		_movement_buttons[i].selected=movement.selection==("jump" if i==0 else "crouch") or i==1 and movement.crouching
		_movement_buttons[i].disabled=menu_open or movement.airborne
		_movement_buttons[i].visible=not menu_open
	_update_charge_indicator()
	_update_queued_indicator()
	_refresh_clock += delta
	_resources.set_values(arena.controlled_actor().resources.current("Energy"), arena.controlled_actor().resources.max_value("Energy"))
	_toast_time = maxf(0.0, _toast_time - delta)
	_notification.visible = _toast_time > 0.0 or arena.toast_time > 0.0
	if arena.toast_time > 0.0:
		_notification.text = arena.toast
	if _refresh_clock >= 0.08:
		_refresh_clock = 0.0
		_refresh_hud()
		if menu_open:
			_refresh_character_info()
			_refresh_equipment_availability()
	if debug_open:
		_refresh_debug()
	stamina_ring.update(arena, delta, menu_open)
	battle_hud.update(arena, delta, size, menu_open)
	_target_text.visible = not battle_hud.boss_active
	queue_redraw()

func toggle_menu(value: Variant = null) -> void:
	menu_open = not menu_open if value == null else bool(value)
	_menu_shade.visible = menu_open
	_menu_panel.visible = menu_open
	arena.input_blocked = menu_open
	if arena.controlled_actor().input_router:
		arena.controlled_actor().input_router.cancel()
	if menu_open:
		_refresh_menu()
	else:
		get_viewport().gui_release_focus()

func notify(message: String) -> void:
	arena.notify(message)
	_notification.text = message
	_toast_time = 3.2
	_notification.visible = true
	if menu_open:
		_menu_error.text = message

func _make_theme() -> Theme:
	var result := Theme.new()
	result.default_font_size = 16
	result.set_color("font_color", "Label", TEXT)
	result.set_color("font_color", "Button", TEXT)
	result.set_color("font_hover_color", "Button", Color.WHITE)
	result.set_color("font_disabled_color", "Button", Color("788d91"))
	result.set_stylebox("panel", "PanelContainer", _style(PANEL, Color("3b5b60"), 12))
	for control in ["Button", "OptionButton"]:
		result.set_stylebox("normal", control, _style(Color("24434b"), Color("45666a"), 7))
		result.set_stylebox("hover", control, _style(Color("31565d"), MINT, 7))
		result.set_stylebox("pressed", control, _style(Color("142d35"), GOLD, 7))
		result.set_stylebox("disabled", control, _style(Color("203139"), Color("34494d"), 7))
		result.set_stylebox("focus", control, _style(Color(0, 0, 0, 0), GOLD, 7))
		result.set_color("font_color", control, TEXT)
		result.set_color("font_disabled_color", control, MUTED)
	result.set_stylebox("panel", "TabContainer", _style(INK, Color("35525b"), 8))
	result.set_stylebox("tab_selected", "TabContainer", _style(Color("31565d"), MINT, 5))
	result.set_stylebox("tab_unselected", "TabContainer", _style(Color("203941"), Color("35525b"), 5))
	result.set_color("font_selected_color", "TabContainer", TEXT)
	result.set_color("font_unselected_color", "TabContainer", MUTED)
	result.set_stylebox("panel", "PopupMenu", _style(INK, MINT, 7))
	result.set_color("font_color", "PopupMenu", TEXT)
	result.set_color("font_disabled_color", "PopupMenu", Color("697a7c"))
	result.set_stylebox("panel", "TooltipPanel", _style(INK, GOLD, 7))
	result.set_color("font_color", "TooltipLabel", TEXT)
	return result

func _style(fill: Color, border: Color, radius: int = 8) -> StyleBoxFlat:
	var result := StyleBoxFlat.new()
	result.bg_color = fill
	result.border_color = border
	result.set_border_width_all(1)
	result.set_corner_radius_all(radius)
	result.content_margin_left = 12
	result.content_margin_right = 12
	result.content_margin_top = 9
	result.content_margin_bottom = 9
	return result

func _build_hud() -> void:
	var status := _panel(self, "Status")
	status.position = Vector2(20, 18)
	status.custom_minimum_size = Vector2(316, 122)
	var stack := _vbox(status)
	_identity = _label(stack, "旅人 · Lv0", 18, GOLD)
	var meters := VBoxContainer.new()
	meters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meters.add_theme_constant_override("separation", 0)
	stack.add_child(meters)
	_health = ProgressBar.new()
	_health.custom_minimum_size.y = 13
	_health.show_percentage = false
	_health.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_health.add_theme_stylebox_override("background", _style(Color("091a22"), Color("091a22"), 6))
	_health.add_theme_stylebox_override("fill", _style(Color("a94953"), Color("d67b7c"), 6))
	meters.add_child(_health)
	_resources = ENERGY_BAR.new()
	_resources.custom_minimum_size = Vector2(214, 16)
	_resources.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	meters.add_child(_resources)
	_hp_text = _label(stack, "生命 100 / 100", 14)
	var actions := HBoxContainer.new()
	actions.name = "TopButtons"
	actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(actions)
	_button(actions, "X  角色与备战", func() -> void: toggle_menu(not menu_open))
	_button(actions, "F10  调试", func() -> void:
		debug_open = not debug_open
		_debug_panel.visible = debug_open)
	_target_text = _label(self, "Tab 锁定目标 · 出招朝准心", 15, MUTED)
	_target_text.name = "TargetInfo"
	_target_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var hotbar := _panel(self, "Hotbar")
	hotbar.custom_minimum_size = Vector2(604, 130)
	var hot := _vbox(hotbar)
	_weapon_text = _label(hot, "战斗组 A · 请先选择职业", 15, GOLD)
	_weapon_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var skills := HBoxContainer.new()
	skills.alignment = BoxContainer.ALIGNMENT_CENTER
	hot.add_child(skills)
	for i in range(3):
		var index := i
		var button := _button(skills, ["Q", "E", "R"][i] + "  未备战", func() -> void: _use_skill(index))
		button.custom_minimum_size = Vector2(182, 48)
		button.add_theme_font_size_override("font_size", 15)
		_hud_buttons.append(button)
	for i in range(2):
		var index := i
		var button := MOVEMENT_BUTTON.new()
		button.kind="jump" if i==0 else "crouch"
		button.size=Vector2(24,24)
		button.tooltip_text="Z 跳跃 · 按住选落点，松开确认；每 2 米增加 1 点体力消耗。" if i==0 else "C 蹲下 / 站起 · 默认松键切换；可在设置中选择精准施法。"
		button.pressed.connect(func(): arena.controlled_actor().movement_actions.press("jump" if index==0 else "crouch","hud"))
		add_child(button)
		_movement_buttons.append(button)
	var quick := HBoxContainer.new()
	quick.alignment = BoxContainer.ALIGNMENT_CENTER
	hot.add_child(quick)
	for i in range(4):
		var index := i
		var button := _button(quick, str(i + 1), func() -> void: arena.controlled_actor().combat.use_quick_item(index))
		button.custom_minimum_size = Vector2(137, 31)
		button.add_theme_font_size_override("font_size", 13)
		_quick_buttons.append(button)
	var hints := _label(self, "WASD 移动  ·  左/右键攻击  ·  Ctrl 持盾  ·  Space 闪避  ·  Z 跳跃  ·  C 蹲站  ·  Shift 切组  ·  F 装备箱", 13, MUTED)
	hints.name = "Hints"
	hints.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notification = _label(self, "", 20, GOLD)
	_notification.name = "Notification"
	_notification.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notification.add_theme_color_override("font_shadow_color", Color.BLACK)
	_notification.add_theme_constant_override("shadow_offset_x", 2)
	_notification.add_theme_constant_override("shadow_offset_y", 2)
	_notification.visible = false
	_chain_text = _label(self, "", 16, MINT)
	_chain_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chain_text.add_theme_color_override("font_shadow_color", Color.BLACK)
	_chain_text.add_theme_constant_override("shadow_offset_x", 1)
	_chain_text.add_theme_constant_override("shadow_offset_y", 1)
	_chain_text.visible = false

func _build_menu() -> void:
	_menu_shade = ColorRect.new()
	_menu_shade.color = Color(0.015, 0.035, 0.05, 0.78)
	_menu_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_menu_shade)
	_menu_panel = _panel(self, "LoadoutMenu")
	_menu_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var layout := _vbox(_menu_panel)
	var title_row := HBoxContainer.new()
	layout.add_child(title_row)
	var title := _label(title_row, "战斗试炼  /  角色与备战", 23, GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(title_row, "返回标题", func() -> void:
		preload("res://combat/input_map.gd").release_all()
		get_tree().change_scene_to_file("res://scenes/frontend/app.tscn"))
	_button(title_row, "关闭  X / Esc", func() -> void: toggle_menu(false))
	_label(layout, "选择职业，配置两套武器与 Q / E / R，然后进入试炼场。", 14, MUTED)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_tabs)
	var character := _tab("角色与成长")
	_label(character, "基础职业  ·  选择后成为 Lv1 并自动获得技能和被动", 17, GOLD)
	var careers := HBoxContainer.new()
	character.add_child(careers)
	for id in arena.database.careers:
		var data: Dictionary = arena.database.careers[id]
		if int(data.get("required_level", 1)) != 1:
			continue
		var career_id := str(id)
		var button := _button(careers, str(data.get("name", id)), func() -> void: _choose_career(career_id))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = "可装备：" + " / ".join(data.get("proficiencies", []))
	var level_row := HBoxContainer.new()
	character.add_child(level_row)
	_label(level_row, "测试等级", 16)
	for level in [1, 2, 3, 10]:
		var chosen: int = level
		_button(level_row, "Lv%d" % level, func() -> void:
			arena.player.combat.reset()
			arena.player.loadout.set_level(chosen)
			_refresh_menu())
	_label(character, "职业进阶  ·  达到所需等级后选择", 17, GOLD)
	_subclasses = HBoxContainer.new()
	character.add_child(_subclasses)
	_character_info = _label(character, "", 16)
	_character_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_passive_info = _label(character, "", 15, MINT)
	_passive_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_career_feature = _label(character, "", 15, MINT)
	_career_feature.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var gear := _tab("装备与外观")
	_gear_header = _label(gear, "战斗组武器  ·  Shift 同时切换武器和技能", 17, GOLD)
	for index in range(2):
		var set_index := index
		var option := _option_row(gear, "战斗组 " + ["A", "B"][index])
		option.item_selected.connect(func(item: int) -> void:
			if not _refreshing and not arena.player.loadout.equip_weapon(set_index, str(option.get_item_metadata(item))):
				_report_loadout_error()
			_refresh_menu())
		_weapons.append(option)
	_gear_explanation = _label(gear, "", 14, MUTED)
	_gear_explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label(gear, "穿戴装备  ·  更换头部、上衣、裤子、鞋子可查看模型变化", 17, GOLD)
	for slot in SLOT_NAMES:
		var slot_id := str(slot)
		var option := _option_row(gear, SLOT_NAMES[slot])
		option.item_selected.connect(func(item: int) -> void:
			if not _refreshing and not arena.player.loadout.equip_item(slot_id, str(option.get_item_metadata(item))):
				_report_loadout_error()
			_refresh_menu())
		_equipment[slot_id] = option
	var skills := _tab("技能备战")
	_label(skills, "职业技能自动开放，同一技能可放入两个战斗组。", 16, GOLD)
	_label(skills, "同一技能共享冷却；实战中鼠标悬停 Q / E / R 可查看不可用原因。", 14, MUTED)
	for index in range(2):
		_label(skills, "战斗组 " + ["A", "B"][index], 20, GOLD)
		var row: Array[OptionButton] = []
		for slot in range(3):
			var set_index := index
			var skill_slot := slot
			var option := _option_row(skills, ["Q", "E", "R"][slot])
			option.item_selected.connect(func(item: int) -> void:
				if not _refreshing:
					arena.player.loadout.assign_skill(set_index, skill_slot, str(option.get_item_metadata(item)))
				_refresh_menu())
			row.append(option)
		_skill_options.append(row)
	var debug := _tab("测试工具")
	_label(debug, "防御练习", 18, GOLD)
	var drills := HBoxContainer.new()
	debug.add_child(drills)
	for entry in [["shield", "盾防 / 精准练习"], ["counter", "负剑反击练习"], ["grab", "红光抓取练习"], ["dual", "二刀流练习"]]:
		var drill_id: String = entry[0]
		var drill_button := _button(drills, entry[1], func() -> void:
			arena.defense_drill(drill_id)
			toggle_menu(false))
		if drill_id == "shield":
			drill_button.tooltip_text = "直接成为 Lv2 士兵：A 槽剑、B 槽盾同时持有；左剑右盾，Shift 只切 QER。"
		elif drill_id == "dual":
			drill_button.tooltip_text = "直接成为 Lv10 二刀流：武技和剑技先左剑 B、再右剑 A；Shift 只切 QER。技能费用、冷却和突进各一次。"
	_label(debug, "Ctrl 挡 / 格挡后左键追击；R 负剑；红光用 Space 躲。", 15, MINT)
	_label(debug, "随时恢复并重试", 18, GOLD)
	var reset_row := HBoxContainer.new()
	debug.add_child(reset_row)
	_button(reset_row, "恢复资源 / 复活", func() -> void: arena.player.combat.restore_resources())
	_button(reset_row, "回满能量", func() -> void:
		var resources: Node = arena.controlled_actor().resources
		resources.change("Energy", resources.max_value("Energy") - resources.current("Energy")))
	_button(reset_row, "重置技能冷却", func() -> void: arena.player.combat.cooldowns.clear())
	_button(reset_row, "设为 25% 生命", func() -> void:
		arena.player.resources.change("HP", arena.player.resources.max_value("HP") * 0.25 - arena.player.resources.current("HP")))
	var clear_row := HBoxContainer.new()
	debug.add_child(clear_row)
	_button(clear_row, "清除所有敌人", func() -> void: arena.kill_all_enemies())
	_button(clear_row, "重置试炼场", func() -> void: arena.reset_arena())
	_button(clear_row, "显示 / 隐藏 Debug", func() -> void:
		debug_open = not debug_open
		_debug_panel.visible = debug_open)
	_label(debug, "生成测试敌人", 18, GOLD)
	for id in arena.database.enemies:
		var enemy_id := str(id)
		var data: Dictionary = arena.database.enemies[id]
		_button(debug, "%s   生命 %s / 护甲 %s / 韧性 %s" % [data.get("name", id), data.get("hp", 0), data.get("armor", 0), data.get("poise", 0)], func() -> void:
			arena.spawn_enemy(enemy_id, arena.player.global_position + arena.player.facing * 6.0))
	_label(debug, "建议：先用普通士兵验证武技，再用重甲守卫验证破势；火元素验证元素抗性，食人魔验证控制免疫。", 15, MUTED).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_error = _label(layout, "", 14, GOLD)
	_menu_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_shade.visible = false
	_menu_panel.visible = false

func _build_debug_overlay() -> void:
	_debug_panel = _panel(self, "DebugOverlay")
	_debug_panel.custom_minimum_size = Vector2(346, 0)
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_text = _label(_debug_panel, "", 12, Color("b6e6d4"))
	_debug_text.add_theme_constant_override("line_spacing", 1)
	_debug_panel.visible = false
	# Menus stay above the debug overlay when open.
	move_child(_menu_shade, get_child_count() - 1)
	move_child(_menu_panel, get_child_count() - 1)

func _layout() -> void:
	if not is_instance_valid(_menu_panel):
		return
	var area := size
	var top := get_node("TopButtons") as Control
	top.position = Vector2(maxf(340, area.x - 293), 20)
	var hotbar := get_node("Hotbar") as Control
	hotbar.position = Vector2((area.x - 604) * 0.5, area.y - 188)
	for i in range(_movement_buttons.size()): _movement_buttons[i].position=hotbar.position+Vector2(-31,52+i*26)
	_chain_text.position = hotbar.position + Vector2(0, -29)
	_chain_text.size = Vector2(604, 25)
	var hints := get_node("Hints") as Control
	hints.position = Vector2(12, area.y - 25)
	hints.size.x = area.x - 24
	_target_text.position = Vector2(340, 72)
	_target_text.size = Vector2(maxf(200, area.x - 680), 25)
	_notification.position = Vector2(30, maxf(152, area.y * 0.26))
	_notification.size.x = area.x - 60
	_menu_panel.position = Vector2(maxf(20, (area.x - 920) * 0.5), 24)
	_menu_panel.size = Vector2(minf(920, area.x - 40), area.y - 48)
	_debug_panel.position = Vector2(area.x - 364, 72)

func _refresh_hud() -> void:
	var player = arena.controlled_actor()
	var combat = player.combat
	var loadout = player.loadout
	var weapon: Dictionary = loadout.weapon()
	var names := _career_names()
	_identity.text = "%s · Lv%d  %s" % [" / ".join(names) if not names.is_empty() else "旅人", loadout.level, "战斗中" if combat.in_combat else "脱战"]
	_health.max_value = maxf(1.0, player.resources.max_value("HP"))
	_health.value = player.resources.current("HP")
	_hp_text.text = "生命 %d / %d%s" % [player.resources.current("HP"), player.resources.max_value("HP"), "   护盾 %d" % player.health.shield if player.health.shield > 0 else ""]
	_resources.set_values(player.resources.current("Energy"), player.resources.max_value("Energy"))
	if loadout.uses_paired_weapons():
		_weapon_text.text = "技能组 %s  ·  %s + %s  ·  Shift 切 QER" % [["A", "B"][loadout.current_set], loadout.weapon_at(0).get("name", "武器 A"), loadout.weapon_at(1).get("name", "武器 B")]
	else:
		_weapon_text.text = "[%s] %s  ·  %s  ·  Shift 切组" % [["A", "B"][loadout.current_set], weapon.get("name", "未装备武器"), weapon.get("animation_family", "选择职业开始")]
	_weapon_text.add_theme_color_override("font_color", QUALITY.get(weapon.get("quality", "Common"), GOLD))
	get_node("Hints").text = "WASD 移动/定向  ·  出招朝准心  ·  左/右键双剑连斩  ·  Space 闪避  ·  Shift 切 QER" if loadout.is_dual_wielding() else ("WASD 移动/定向  ·  出招朝准心  ·  左键剑 / 右键盾  ·  按住右键防御  ·  Space 闪避  ·  Shift 切 QER" if loadout.uses_paired_weapons() else "WASD 移动/定向  ·  出招朝准心  ·  左/右键武技  ·  Space 闪避  ·  Shift 切武器和 QER")
	var locked = arena.locked_target
	_target_text.text = "锁定：%s · Lv%d   %.0f / %.0f" % [locked.display_name, locked.loadout.level, locked.resources.current("HP"), locked.resources.max_value("HP")] if is_instance_valid(locked) else "Tab 锁定目标 · 出招朝准心"
	for i in range(3):
		var action: Dictionary = player.skill_at(i)
		var id: String = action.get("id", "")
		var cooldown := float(combat.cooldowns.get(id, 0.0))
		var reason: String = "未备战技能" if action.is_empty() else combat.skill_input_failure(action, true)
		_hud_buttons[i].text = "%s  %s%s" % [["Q", "E", "R"][i], action.get("name", "未备战"), "\n%.1f s" % cooldown if cooldown > 0 else ""]
		_hud_buttons[i].disabled = not reason.is_empty() or menu_open
		_hud_buttons[i].tooltip_text = _skill_description(action) + ("\n不可用：" + reason if not reason.is_empty() else "\n点击选取，左键确认，右键取消")
	for i in range(4):
		var cd := float(combat.cooldowns.get("item_" + str(i), 0.0))
		var reason: String = combat.quick_item_failure(i)
		var item: Dictionary = arena.database.items.get(["healing_potion", "qi_potion", "spell_potion", "fire_bomb"][i], {})
		_quick_buttons[i].text = "%d %s ×%d%s" % [i + 1, item.get("name", "消耗品"), combat.quick_counts[i], " %.1fs" % cd if cd > 0 else ""]
		_quick_buttons[i].disabled = menu_open or not reason.is_empty()
		_quick_buttons[i].tooltip_text = str(item.get("description", "")) + ("\n不可用：" + reason if not reason.is_empty() else "")
	_update_queued_indicator()

func _update_queued_indicator() -> void:
	_chain_text.visible = false
	_chain_text.text = ""

func _update_charge_indicator() -> void:
	# Compatibility observables remain, but timing is shown only on the actor.
	charge_indicator_visible = false
	charge_indicator_text = ""
	_charge_progress_display = 0.0
	_charge_ready_display = false
	_charge_hint_text = ""

func _refresh_menu() -> void:
	if not is_instance_valid(_tabs):
		return
	_refreshing = true
	var loadout = arena.player.loadout
	var paired: bool = loadout.uses_paired_weapons()
	var style: String = loadout.paired_style()
	_gear_header.text = "双剑装备  ·  Shift 只切换技能组" if style == "dual_sword_pair" else ("士兵剑盾装备  ·  Shift 只切换技能组" if paired else "战斗组武器  ·  Shift 同时切换武器和技能")
	_gear_explanation.text = "二刀流：A / B 各一把剑和三个技能。武技和剑技先左剑 B、再右剑 A。回旋斩两次，前刺只突进一次后刺两下。Shift 只切 QER；技能费用与冷却各一次。" if style == "dual_sword_pair" else ("士兵：A 槽装备剑，B 槽装备盾；始终同时持剑盾。左键挥剑，右键举盾，按住持续防御。Shift 只切换 Q / E / R。" if paired else "每组包含一把武器和 Q / E / R 三个技能。Shift 同时切换武器与技能组。")
	for child in _subclasses.get_children():
		_subclasses.remove_child(child)
		child.queue_free()
	var next: Array = []
	if not loadout.career_ids.is_empty():
		next = arena.database.careers[loadout.career_ids.back()].get("next_careers", [])
	for id in next:
		var career_id := str(id)
		var button := _button(_subclasses, str(arena.database.careers[id].get("name", id)), func() -> void: _choose_career(career_id))
		button.disabled = loadout.level < int(arena.database.careers[id].get("required_level", 2))
	if next.is_empty():
		_label(_subclasses, "先选择基础职业" if loadout.career_ids.is_empty() else "已选择当前职业；可用测试等级验证成长。", 15, MUTED)
	for i in range(2):
		var option := _weapons[i]
		(option.get_parent().get_child(0) as Label).text = "武器 " + ["A", "B"][i]
		option.clear()
		for id in arena.database.weapons:
			var data: Dictionary = arena.database.weapons[id]
			if style == "sword_shield_pair" and (i == 1) != (data.get("weapon_type", "") == "Shield"):
				continue
			if style == "dual_sword_pair" and data.get("weapon_type", "") not in ["Sword", "Katana"]:
				continue
			var reason: String = loadout.can_equip_set_weapon(i, id)
			option.add_item("%s  · 补正 %s%s" % [data.get("name", id), data.get("weapon_scaling", 0), "  · " + reason if not reason.is_empty() else ""])
			var n := option.item_count - 1
			option.set_item_metadata(n, id)
			option.set_item_disabled(n, not reason.is_empty())
			option.get_popup().set_item_tooltip(n, _weapon_description(data) + ("\n不可装备：" + reason if not reason.is_empty() else ""))
			if id == loadout.sets[i].weapon:
				option.select(n)
		if loadout.sets[i].weapon.is_empty():
			option.select(-1)
	for slot in _equipment:
		var option: OptionButton = _equipment[slot]
		option.clear()
		option.add_item("空槽 / 卸下")
		option.set_item_metadata(0, "")
		for id in arena.database.equipment:
			var data: Dictionary = arena.database.equipment[id]
			if data.get("slot", "") != slot and not (data.get("slot", "") == "ring" and slot in ["ring1", "ring2"]):
				continue
			var reason: String = loadout.can_equip_item(slot, id)
			option.add_item(str(data.get("name", id)) + ("  · " + reason if not reason.is_empty() else ""))
			var n := option.item_count - 1
			option.set_item_metadata(n, id)
			option.set_item_disabled(n, not reason.is_empty())
			option.get_popup().set_item_tooltip(n, _equipment_description(data) + ("\n不可装备：" + reason if not reason.is_empty() else ""))
			if id == loadout.equipment.get(slot, ""):
				option.select(n)
	for i in range(2):
		for j in range(3):
			var option: OptionButton = _skill_options[i][j]
			option.clear()
			option.add_item("未备战")
			option.set_item_metadata(0, "")
			for id in loadout.unlocked_skills:
				var data: Dictionary = arena.database.skills[id]
				option.add_item(data.get("name", id))
				var n := option.item_count - 1
				option.set_item_metadata(n, id)
				option.get_popup().set_item_tooltip(n, _skill_description(data))
				if id == loadout.sets[i].skills[j]:
					option.select(n)
	_refresh_character_info()
	_refreshing = false

func _refresh_character_info() -> void:
	var player = arena.controlled_actor()
	var entries: PackedStringArray = []
	for key in ["STR", "DEX", "CON", "INT", "PER", "CHA"]:
		entries.append("%s  %d" % [key, player.stats.get_final_stat(key)])
	_character_info.text = "%s  ·  Lv%d\n\n%s\n\n生命 %.0f / %.0f   体力 %s   能量 %s / %s\n护甲 %.0f   韧性 %.0f / %.0f\n当前战斗组 %s  ·  %s" % [" / ".join(_career_names()), player.loadout.level, "     ".join(entries), player.resources.current("HP"), player.resources.max_value("HP"), _dots("Stamina"), ENERGY_BAR.number(player.resources.current("Energy")), ENERGY_BAR.number(player.resources.max_value("Energy")), player.stats.get_final_stat("Armor"), player.combat.current_poise, player.combat.max_poise(), ["A", "B"][player.loadout.current_set], player.loadout.weapon().get("name", "未装备")]
	var passive_names: PackedStringArray = []
	for id in player.loadout.passive_ids:
		passive_names.append(str(arena.database.passives.get(id, {}).get("name", id)))
	_passive_info.text = "已生效被动：" + ("、".join(passive_names) if not passive_names.is_empty() else "暂无")
	_career_feature.text = "二刀流特性：左剑 B 先攻，右剑 A 追击；剑技的攻击段也由两剑各执行一次。回旋各转一周，前刺只突进一次后连续两刺；消耗与冷却各一次。Shift 只切 QER。" if player.loadout.is_dual_wielding() else ("士兵特性：A 剑、B 盾同时握持；左右键操作不随技能组变化。右键点按有短暂精准窗口，按住转为普通盾防；Shift 只切 QER。" if player.loadout.uses_paired_weapons() else "精准防御：微白光只在有效判定窗口出现；命中消费或时间结束时立即熄灭。重武器蓄力 65%–85% 时松手可延续攻防窗口。")

func _refresh_equipment_availability() -> void:
	var loadout = arena.player.loadout
	for set_index in range(_weapons.size()):
		var option: OptionButton = _weapons[set_index]
		for index in range(option.item_count):
			var id := str(option.get_item_metadata(index))
			var data: Dictionary = arena.database.weapons.get(id, {})
			var reason: String = loadout.can_equip_set_weapon(set_index, id) if arena.player.combat.can_start() else "动作结束后才能更换装备"
			option.set_item_disabled(index, not reason.is_empty())
			option.set_item_text(index, "%s  · 补正 %s%s" % [data.get("name", id), data.get("weapon_scaling", 0), "  · " + reason if not reason.is_empty() else ""])
			option.get_popup().set_item_tooltip(index, _weapon_description(data) + ("\n不可装备：" + reason if not reason.is_empty() else ""))
	for slot in _equipment:
		var option: OptionButton = _equipment[slot]
		for index in range(option.item_count):
			var id := str(option.get_item_metadata(index))
			var reason: String = loadout.can_equip_item(slot, id)
			option.set_item_disabled(index, not reason.is_empty())
			if id.is_empty():
				continue
			var data: Dictionary = arena.database.equipment[id]
			option.set_item_text(index, str(data.get("name", id)) + ("  · " + reason if not reason.is_empty() else ""))
			option.get_popup().set_item_tooltip(index, _equipment_description(data) + ("\n不可装备：" + reason if not reason.is_empty() else ""))

func _refresh_debug() -> void:
	var p = arena.controlled_actor()
	var c = p.combat
	var w: Dictionary = p.loadout.weapon()
	var target = arena.locked_target
	var lines: PackedStringArray = ["DEBUG  /  F10", "State: %s   InCombat: %s" % [c.state, c.in_combat], "CurrentAction: " + str(c.runner.current_action.get("id", "—")), "ActionPhase: %s   ActionTime: %.3f" % [c.runner.action_phase, c.runner.action_time], "CurrentWeapon: " + str(w.get("name", "—")), "WeaponType: " + str(w.get("weapon_type", "—")), "AnimationFamily: " + str(w.get("animation_family", "—")), "CombatSet: " + ["A", "B"][p.loadout.current_set]]
	lines.append("HP: %.0f/%.0f   Stamina: %.0f/%.0f" % [p.resources.current("HP"), p.resources.max_value("HP"), p.resources.current("Stamina"), p.resources.max_value("Stamina")])
	lines.append("Energy: %.1f / %.1f" % [p.resources.current("Energy"), p.resources.max_value("Energy")])
	lines.append("Poise: %.1f / %.1f" % [c.current_poise, c.max_poise()])
	var inputs: PackedStringArray = []
	if p.input_router:
		for entry in p.input_router.buffer.entries:
			inputs.append("%s %.2f" % [entry.kind, p.input_router.clock - float(entry.time)])
	lines.append("InputBuffer: " + (", ".join(inputs) if not inputs.is_empty() else "—"))
	for i in range(3):
		var id: String = p.loadout.sets[p.loadout.current_set].skills[i]
		lines.append("%s: %s  CD %.1f" % [["Q", "E", "R"][i], arena.database.skills.get(id, {}).get("name", "—"), c.cooldowns.get(id, 0)])
	lines.append("LockedTarget: " + (str(target.display_name) if is_instance_valid(target) else "—"))
	lines.append("TargetHP: %.0f   TargetPoise: %.1f" % [target.resources.current("HP"), target.combat.current_poise] if is_instance_valid(target) else "TargetHP: —   TargetPoise: —")
	lines.append("LastDamage: %.2f (Raw %.2f)" % [c.last_damage.get("final", 0), c.last_damage.get("raw", 0)])
	lines.append("LastCrit: %s   LastDamageType: %s" % [c.last_damage.get("crit", false), c.last_damage.get("damage_type", "—")])
	lines.append("LastConditionFailed: " + (str(c.last_condition_failed) if not str(c.last_condition_failed).is_empty() else "—"))
	lines.append("Charge: %s %.2fs / %.0f%% %s" % [c.charge_button, c.charge_time, c.charge_progress() * 100, "READY" if c.charge_ready else ""])
	lines.append("Queued: " + str(c.queued_command.get("action_id", "—")))
	lines.append("Defense: %s  Precise:%s  HA:%s" % [c.defense.last_outcome, c.defense.precision_window_active(), c.has_hyper_armor()])
	lines.append("Guard: %s %.2fs  CD %.2f / Riposte %.2f" % [c.defense.guard_held, c.defense.guard_time, c.defense.guard_cooldown, c.guard_counter_time])
	_debug_text.text = "\n".join(lines)

func _draw() -> void:
	if not is_instance_valid(arena) or not is_instance_valid(arena.player):
		return
	stamina_ring.draw(self)
	battle_hud.draw(self)

func _exit_tree() -> void:
	battle_hud.clear()

func _choose_career(id: String) -> void:
	arena.player.combat.reset()
	if not arena.player.loadout.select_career(id):
		_report_loadout_error()
	else:
		notify("已选择 " + str(arena.database.careers[id].get("name", id)))
	_refresh_menu()

func _use_skill(slot: int) -> void:
	arena.controlled_actor().skill_casting.press(slot, "hud")
	_update_queued_indicator()

func _report_loadout_error() -> void:
	notify(str(arena.player.loadout.last_error))

func _career_names() -> PackedStringArray:
	var result: PackedStringArray = []
	for id in arena.player.loadout.career_ids:
		result.append(str(arena.database.careers[id].get("name", id)))
	return result

func _dots(id: String) -> String:
	var maximum := int(arena.controlled_actor().resources.max_value(id))
	var current := int(arena.controlled_actor().resources.current(id))
	if maximum <= 0:
		return "—"
	return "●".repeat(current) + "○".repeat(maxi(0, maximum - current))

func _skill_description(data: Dictionary) -> String:
	if data.is_empty():
		return "在 C 菜单中配置技能"
	var costs: PackedStringArray = []
	for id in data.get("costs", {}):
		costs.append("%s ×%s" % [{"Energy": "能量", "Stamina": "体力", "HP": "生命"}.get(id, id), data.costs[id]])
	var purpose := str(data.get("description", ""))
	if data.get("counter_stance", false):
		purpose = "站定负剑，警戒期间拦截来袭攻击并挥剑反击。红光抓取可破解架势。"
	elif data.has("guard_window") or "guard" in str(data.get("id", "")):
		purpose += " 动作中格挡来袭攻击；微白光持续期间可精准格挡。"
	var sequence: Dictionary = data.get("dual_sequence", {})
	if arena.player.loadout.is_dual_wielding() and not sequence.is_empty():
		var template := str(sequence.get("template", "slash"))
		var detail: String = {"spin": "左、右各完整转斩一周", "thrust": "突进一次后左、右各前刺一次", "slash": "左、右各挥斩一次"}.get(template, "左、右各攻击一次")
		purpose += "\n二刀流：%s；左剑 B → 右剑 A。费用、冷却和位移各结算一次。" % detail
	return "%s\n%s%s\n冷却 %.1f 秒 · %s\n范围 %s 米 · %s\n%s" % [data.get("name", ""), purpose, _defense_description(data), data.get("cooldown", 0), " / ".join(costs) if not costs.is_empty() else "无资源消耗", data.get("range", 0), data.get("targeting", "SELF"), _conditions_text(data.get("conditions", []))]

func _weapon_description(data: Dictionary) -> String:
	var details := "%s · %s\n武器补正 %s\n%s / %s\n%s" % [data.get("name", ""), data.get("quality", "Common"), data.get("weapon_scaling", 0), data.get("weapon_type", ""), data.get("animation_family", ""), _conditions_text(data.get("conditions", []))]
	if not str(data.get("description", "")).is_empty():
		details += "\n" + str(data.description)
	if data.get("weapon_type", "") == "Shield":
		details += "\n右键点按举盾，按住转持续防御；Ctrl 普通盾防。\n举盾防御 0–0.22 秒；精准 0–%.2f 秒。" % float(data.get("perfect_window", .16))
		return details
	var secondary: Dictionary = arena.database.get_action(str(data.get("animation_family", "")), "SECONDARY_TAP")
	if secondary.has("guard_window"):
		details += "\n剑武技的防御窗口：" + _defense_description(secondary)
	if data.get("animation_family", "") == "HEAVY_2H":
		details += "\n左键蓄力 65%–85% 为精准窗口；此时松手继承挥砍前 0.20 秒防御。早放、晚放与满蓄均无继承防御。"
	return details

func _defense_description(action: Dictionary) -> String:
	var guard: Dictionary = action.get("guard_window", {})
	if guard.is_empty():
		return ""
	var start := float(guard.get("start", 0.0))
	var end := float(guard.get("end", 0.0))
	var precise_end := minf(end, start + float(guard.get("perfect_window", 0.0)))
	return "\n防御窗口 %.2f–%.2f 秒；精准窗口 %.2f–%.2f 秒（仅窗口内微白光）。" % [start, end, start, precise_end]

func _equipment_description(data: Dictionary) -> String:
	var bits: PackedStringArray = [str(data.get("name", ""))]
	for id in data.get("modifiers", {}):
		bits.append("%s %+d" % [id, data.modifiers[id]])
	for id in data.get("passives", []):
		bits.append("被动：" + str(arena.database.passives.get(id, {}).get("name", id)))
	bits.append(_conditions_text(data.get("conditions", [])))
	return "\n".join(bits)

func _conditions_text(conditions: Array) -> String:
	var result: PackedStringArray = []
	for item in conditions:
		var kind := str(item.get("type", ""))
		var field := str(item.get("stat", {"weapon_family": "武器家族", "weapon_type": "武器类型", "proficiency": "职业熟练", "self_hp": "自身生命比例", "target_hp": "目标生命比例", "behind": "位于目标背后", "resource": "资源", "career": "职业"}.get(kind, kind)))
		result.append("%s %s %s" % [field, item.get("op", "="), item.get("value", "")])
	return "条件：" + ("；".join(result) if not result.is_empty() else "无")

func _panel(parent: Node, label: String) -> PanelContainer:
	var result := PanelContainer.new()
	result.name = label
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(result)
	return result

func _vbox(parent: Node) -> VBoxContainer:
	var result := VBoxContainer.new()
	result.add_theme_constant_override("separation", 8)
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(result)
	return result

func _label(parent: Node, text_value: String, font_size: int = 16, color: Color = TEXT) -> Label:
	var result := Label.new()
	result.text = text_value
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.add_theme_font_size_override("font_size", font_size)
	result.add_theme_color_override("font_color", color)
	parent.add_child(result)
	return result

func _button(parent: Node, text_value: String, callback: Callable) -> Button:
	var result := Button.new()
	result.text = text_value
	result.focus_mode = Control.FOCUS_NONE
	result.custom_minimum_size.y = 37
	result.pressed.connect(callback)
	parent.add_child(result)
	return result

func _tab(label: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = label
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 18)
	scroll.add_child(margin)
	var result := _vbox(margin)
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result.add_theme_constant_override("separation", 14)
	return result

func _option_row(parent: Node, text_value: String) -> OptionButton:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var caption := _label(row, text_value)
	caption.custom_minimum_size.x = 96
	var result := OptionButton.new()
	result.custom_minimum_size = Vector2(320, 35)
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result.fit_to_longest_item = false
	result.clip_text = true
	row.add_child(result)
	return result
