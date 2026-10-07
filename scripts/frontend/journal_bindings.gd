extends RefCounted
## The UI labels refer to action bindings, never to a hard-coded display key.
const PREFERENCES=preload("res://rpg/game_preferences.gd")
const ACTIONS: Array[StringName]=[&"skill_q",&"skill_e",&"skill_r"]
const DEFAULTS: Array[Key]=[KEY_Q,KEY_E,KEY_R]
const QUICK_ACTIONS: Array[StringName]=[&"quick_item_1",&"quick_item_2",&"quick_item_3",&"quick_item_4"]
static var last_error := ""
static func label(slot: int) -> String:
	return action_label(ACTIONS[slot],OS.get_keycode_string(DEFAULTS[slot]))

static func action_label(action: StringName,fallback := "") -> String:
	if InputMap.has_action(action):
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				var code: int=event.physical_keycode if event.physical_keycode!=0 else event.keycode
				if code!=0: return OS.get_keycode_string(code)
			if event is InputEventMouseButton: return "鼠标 "+str(event.button_index)
	return fallback

static func signature() -> String:
	return label(0)+"|"+label(1)+"|"+label(2)

static func assign(slot: int,event: InputEventKey) -> bool:
	last_error="这个按键用于移动或菜单，请换一个。"
	if slot<0 or slot>=ACTIONS.size(): return false
	var code: int=event.physical_keycode if event.physical_keycode!=0 else event.keycode
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed or event.shift_pressed: return false
	if not _available(code): return false
	var candidate := snapshot()
	var target: String=String(ACTIONS[slot])
	var previous: int=candidate[target]
	for action in candidate:
		if action!=target and candidate[action]==code: candidate[action]=previous
	candidate[target]=code
	var result: Error=PREFERENCES.set_bindings(candidate)
	if result!=OK:
		last_error="按键保存失败，原按键仍然有效。"
		return false
	_apply(candidate)
	last_error=""
	return true

static func snapshot() -> Dictionary:
	var result: Dictionary=PREFERENCES.BINDING_DEFAULTS.duplicate()
	for action in result:
		if not InputMap.has_action(action): continue
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				result[action]=event.physical_keycode if event.physical_keycode!=0 else event.keycode
				break
	return result

## Called after the engine's action installation, and by the title UI before any
## world is loaded. This changes no unrelated movement/menu/mouse actions.
static func restore_preferences() -> void:
	var codes := PREFERENCES.get_bindings()
	for code in codes.values():
		if not _available(code):
			codes=PREFERENCES.BINDING_DEFAULTS.duplicate()
			break
	_apply(codes)

static func reset_defaults() -> bool:
	var codes: Dictionary=PREFERENCES.BINDING_DEFAULTS.duplicate()
	var result: Error=PREFERENCES.set_bindings(codes)
	if result!=OK:
		last_error="按键保存失败，原按键仍然有效。"
		return false
	_apply(codes)
	last_error=""
	return true

static func _available(code: int) -> bool:
	if not PREFERENCES.valid_binding_code(code): return false
	var event := InputEventKey.new()
	event.physical_keycode=code
	event.keycode=code
	for action: StringName in InputMap.get_actions():
		if action not in ACTIONS and action not in QUICK_ACTIONS and InputMap.event_is_action(event,action,true): return false
	return true

static func _apply(codes: Dictionary) -> void:
	for action in codes:
		if not InputMap.has_action(action): InputMap.add_action(action)
		Input.action_release(action)
		InputMap.action_erase_events(action)
		var key := InputEventKey.new()
		key.physical_keycode=codes[action]
		InputMap.action_add_event(action,key)
