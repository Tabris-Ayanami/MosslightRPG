extends RefCounted

static func install() -> void:
	var keys := {"move_up": KEY_W, "move_down": KEY_S, "move_left": KEY_A, "move_right": KEY_D,
		"skill_q": KEY_Q, "skill_e": KEY_E, "skill_r": KEY_R, "dodge_dash": KEY_SPACE,
		"switch_combat_set": KEY_SHIFT, "interact": KEY_F, "lock_target": KEY_TAB,
		"quick_item_1": KEY_1, "quick_item_2": KEY_2, "quick_item_3": KEY_3, "quick_item_4": KEY_4,
		"move_jump": KEY_Z, "move_crouch": KEY_C,
		"combat_menu": KEY_X, "combat_debug": KEY_F10, "combat_pause": KEY_ESCAPE, "guard": KEY_CTRL}
	for id in keys:
		if not InputMap.has_action(id):
			InputMap.add_action(id)
		if not InputMap.action_get_events(id).is_empty():
			continue
		var key := InputEventKey.new()
		key.physical_keycode = keys[id]
		InputMap.action_add_event(id, key)
	for id in ["attack_primary", "attack_secondary"]:
		if not InputMap.has_action(id):
			InputMap.add_action(id)
		if not InputMap.action_get_events(id).is_empty():
			continue
		var mouse := InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_LEFT if id == "attack_primary" else MOUSE_BUTTON_RIGHT
		InputMap.action_add_event(id, mouse)
	preload("res://scripts/frontend/journal_bindings.gd").restore_preferences()

static func release_all() -> void:
	for id in InputMap.get_actions():
		Input.action_release(id)
