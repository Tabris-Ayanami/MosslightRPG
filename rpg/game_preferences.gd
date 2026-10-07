extends RefCounted
## Shared presentation preferences; writes preserve every unrelated ConfigFile key.
const DEFAULT_PATH := "user://game_preferences.cfg"
const AUDIO_KEYS := ["master", "music", "effects"]
const AUDIO_DEFAULTS := [72.0, 58.0, 80.0]
const AUDIO_GROUPS := [["Master"], ["Music"], ["Effects", "Ambience", "Footsteps", "Weather"]]
const BINDING_DEFAULTS := {"skill_q": KEY_Q, "skill_e": KEY_E, "skill_r": KEY_R,
	"quick_item_1": KEY_1, "quick_item_2": KEY_2, "quick_item_3": KEY_3, "quick_item_4": KEY_4}
const SKILL_ACTIONS := ["skill_q", "skill_e", "skill_r"]
const CAST_ACTIONS := ["skill_q", "skill_e", "skill_r", "move_jump", "move_crouch"]
const CAST_QUICK := "quick"
const CAST_PRECISE := "precise"
const RESERVED_KEYS := [KEY_NONE, KEY_ESCAPE, KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META,
	KEY_W, KEY_A, KEY_S, KEY_D, KEY_SPACE, KEY_F, KEY_M, KEY_B, KEY_C, KEY_J, KEY_K,
	KEY_Z, KEY_X, KEY_TAB, KEY_F1, KEY_F2, KEY_F10, KEY_F11]
static var settings_path := DEFAULT_PATH
static var _loaded_path := ""
static var _damage_numbers := true
static var _audio_levels: Array = AUDIO_DEFAULTS.duplicate()
static var _binding_codes: Dictionary = BINDING_DEFAULTS.duplicate()
static var _cast_modes: Dictionary = {}
static var _audio_baselines: Dictionary = {}

static func reload_preferences() -> void:
	var config := ConfigFile.new()
	var error := config.load(settings_path)
	var damage: Variant = config.get_value("combat_ui", "damage_numbers", true) if error == OK else true
	_damage_numbers = damage if damage is bool else true
	_audio_levels = AUDIO_DEFAULTS.duplicate()
	_binding_codes = BINDING_DEFAULTS.duplicate()
	_cast_modes.clear()
	for action in CAST_ACTIONS:
		var mode: Variant = config.get_value("casting", action, CAST_QUICK) if error == OK else CAST_QUICK
		_cast_modes[action] = mode if mode is String and mode in [CAST_QUICK, CAST_PRECISE] else CAST_QUICK
	if error == OK:
		for index in range(AUDIO_KEYS.size()):
			var value: Variant = config.get_value("audio", AUDIO_KEYS[index], AUDIO_DEFAULTS[index])
			if (value is int or value is float) and is_finite(float(value)):
				_audio_levels[index] = clampf(float(value), 0.0, 100.0)
		var candidate := BINDING_DEFAULTS.duplicate()
		for action in BINDING_DEFAULTS:
			candidate[action] = config.get_value("bindings", action, BINDING_DEFAULTS[action])
		# Treat all seven bindings as a unit: partial corrupt swaps cannot steal keys.
		if valid_bindings(candidate):
			_binding_codes = candidate
	_loaded_path = settings_path

static func get_damage_numbers() -> bool:
	if _loaded_path != settings_path: reload_preferences()
	return _damage_numbers

static func set_damage_numbers(enabled: bool) -> Error:
	return _write_values("combat_ui", {"damage_numbers": enabled})

static func get_audio_levels() -> Array:
	if _loaded_path != settings_path: reload_preferences()
	return _audio_levels.duplicate()

static func set_audio_level(index: int, value: float) -> Error:
	if index < 0 or index >= AUDIO_KEYS.size() or not is_finite(value):
		return ERR_INVALID_PARAMETER
	var error := _write_values("audio", {AUDIO_KEYS[index]: clampf(value, 0.0, 100.0)})
	if error == OK: apply_audio_preferences()
	return error

static func reset_audio() -> Error:
	var values := {}
	for index in range(AUDIO_KEYS.size()): values[AUDIO_KEYS[index]] = AUDIO_DEFAULTS[index]
	var error := _write_values("audio", values)
	if error == OK: apply_audio_preferences()
	return error

## sound.gd supplies its authored mix after rebuilding buses. Remember the baseline
## rather than multiplying already-adjusted bus levels on each slider movement.
## Game's mute flag and every bus mute flag remain under their existing owner's control.
static func apply_audio_preferences(authored_mix: Dictionary = {}) -> void:
	var levels := get_audio_levels()
	for index in range(AUDIO_GROUPS.size()):
		for bus_name: String in AUDIO_GROUPS[index]:
			var bus := AudioServer.get_bus_index(bus_name)
			if bus < 0: continue
			if authored_mix.has(bus_name):
				_audio_baselines[bus_name] = float(authored_mix[bus_name])
			elif not _audio_baselines.has(bus_name):
				_audio_baselines[bus_name] = AudioServer.get_bus_volume_db(bus)
			AudioServer.set_bus_volume_linear(bus, db_to_linear(_audio_baselines[bus_name]) * float(levels[index]) / 100.0)

static func get_bindings() -> Dictionary:
	if _loaded_path != settings_path: reload_preferences()
	return _binding_codes.duplicate()

static func get_cast_mode(action: String) -> String:
	if _loaded_path != settings_path: reload_preferences()
	return str(_cast_modes.get(action, CAST_QUICK))

static func set_cast_mode(action: String, mode: String) -> Error:
	if action not in CAST_ACTIONS or mode not in [CAST_QUICK, CAST_PRECISE]: return ERR_INVALID_PARAMETER
	return _write_values("casting", {action: mode})

static func reset_cast_modes() -> Error:
	var values := {}
	for action in CAST_ACTIONS: values[action] = CAST_QUICK
	return _write_values("casting", values)

static func set_bindings(codes: Dictionary) -> Error:
	if not valid_bindings(codes): return ERR_INVALID_PARAMETER
	return _write_values("bindings", codes)

static func valid_binding_code(value: Variant) -> bool:
	if not value is int or value in RESERVED_KEYS or value <= 0 or value > 0x7fffff:
		return false
	# Reject arbitrary integers and modifier masks while retaining supported physical
	# letters, punctuation, numeric keys, keypad keys, and unreserved function keys.
	var name := OS.get_keycode_string(value)
	return not name.is_empty() and OS.find_keycode_from_string(name) == value

static func valid_bindings(codes: Dictionary) -> bool:
	if codes.size() != BINDING_DEFAULTS.size(): return false
	var used := {}
	for action in BINDING_DEFAULTS:
		if not codes.has(action) or not valid_binding_code(codes[action]) or used.has(codes[action]):
			return false
		used[codes[action]] = true
	return true

static func _write_values(section: String, values: Dictionary) -> Error:
	var config := ConfigFile.new()
	var error := config.load(settings_path)
	if error != OK and error != ERR_FILE_NOT_FOUND: return error
	for key in values: config.set_value(section, key, values[key])
	error = config.save(settings_path)
	if error == OK: reload_preferences()
	return error
