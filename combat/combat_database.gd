extends RefCounted
class_name CombatDatabase

## Content catalog. All combat numbers live in JSON and are copied per action instance.
## get_action's combo index is zero based and wraps to the family's first attack.
const DATA_ROOT := "res://data/combat/"
const CATALOGS := ["careers", "weapons", "skills", "passives", "equipment", "enemies", "status_effects", "actions", "combat_feel", "reactions", "items", "progression"]
const ContentBundle = preload("res://rpg/content_bundle.gd")
static var _frozen_catalogs: Dictionary = {}
static var _frozen_world_catalogs: Dictionary = {}
static var _frozen_errors: PackedStringArray = []
static var _selected_bundle: RefCounted
static var _constructed := false
static var _selection_locked := false

var careers: Dictionary = {}
var weapons: Dictionary = {}
var skills: Dictionary = {}
var passives: Dictionary = {}
var equipment: Dictionary = {}
var enemies: Dictionary = {}
var status_effects: Dictionary = {}
var actions: Dictionary = {}
var combat_feel: Dictionary = {}
var shields: Dictionary = {}
var reactions: Dictionary = {}
var items: Dictionary = {}
var progression: Dictionary = {}
var errors: PackedStringArray = []
var _action_lookup: Dictionary = {}
var _world_catalogs: Dictionary = {}
var _builtin_icons: Dictionary = {}

func _init() -> void:
	_constructed = true
	if _frozen_catalogs.is_empty():
		for catalog: String in CATALOGS:
			_frozen_catalogs[catalog] = _read_catalog(catalog)
		for catalog: String in ContentBundle.WORLD_CATALOGS:
			_frozen_world_catalogs[catalog] = _read_world_catalog(catalog)
		_frozen_errors = errors.duplicate()
	errors = _frozen_errors.duplicate()
	_world_catalogs = _frozen_world_catalogs.duplicate(true)
	for catalog in CATALOGS:
		set(catalog, _frozen_catalogs[catalog].duplicate(true))
	_index_shields()
	_index_actions()
	for catalog in [skills, actions]:
		for action in catalog.values():
			var reason := preload("res://combat/resource_recovery.gd").spell_error(action)
			if not reason.is_empty(): _record_error(str(action.get("id", "")) + ": " + reason)
			var motion_error := preload("res://combat/melee_motion.gd").error_for(action)
			if not motion_error.is_empty(): _record_error(str(action.get("id", "")) + ": " + motion_error)

## Explicit startup selection only. Every Database in this process shares one
## identity. A formal release also checks the identity before publishing it.
static func configure_content_bundle(path: String, expected_identity: Variant = null) -> Dictionary:
	if _constructed or _selection_locked: return {"ok": false, "error": "内容集已固定，请重启游戏后再选择", "identity": {}}
	var result := ContentBundle.load_directory(path)
	if not result.ok: return result
	if expected_identity != null and (not expected_identity is Dictionary or JSON.parse_string(JSON.stringify(result.identity)) != JSON.parse_string(JSON.stringify(expected_identity))):
		return {"ok": false, "error": "内容包身份与发行清单不一致", "identity": {}}
	_selected_bundle = result.bundle
	_frozen_catalogs = _selected_bundle.catalogs()
	_frozen_world_catalogs = _selected_bundle.world_catalogs()
	_frozen_errors.clear()
	return {"ok": true, "error": "", "identity": _selected_bundle.identity()}

static func content_started() -> bool:
	return _constructed or _selection_locked or is_instance_valid(_selected_bundle)

static func lock_content_selection() -> void:
	_selection_locked = true

func is_active() -> bool: return is_instance_valid(_selected_bundle) and _selected_bundle.is_active()
func identity() -> Dictionary: return _selected_bundle.identity() if is_active() else {}
func world_catalog(name: String) -> Dictionary: return _world_catalogs.get(name, {}).duplicate(true)
func get_content_icon(catalog: String, id: String) -> Texture2D:
	var supplied := get_content_texture(catalog, id, "icon")
	if supplied != null: return supplied
	if catalog not in ["weapons", "equipment"] or not get(catalog).has(id): return null
	if not _builtin_icons.has(id):
		var path := "res://assets/ui/antigravity-v1/" + id + ".jpg"
		_builtin_icons[id] = load(path) if ResourceLoader.exists(path) else null
	return _builtin_icons[id]
func get_content_texture(catalog: String, id: String, role: String) -> Texture2D:
	return _selected_bundle.get_texture(catalog, id, role) if is_active() else null

func _index_shields() -> void:
	# Compatibility view: weapons.json is the single source of shield data.
	shields.clear()
	for id in weapons:
		if str(weapons[id].get("weapon_type", "")) == "Shield":
			shields[id] = weapons[id]

func _read_catalog(catalog: String) -> Dictionary:
	var path := DATA_ROOT + catalog + ".json"
	if not FileAccess.file_exists(path):
		_record_error("Missing combat catalog: " + path)
		return {}
	var parser := JSON.new()
	var result := parser.parse(FileAccess.get_file_as_string(path))
	if result != OK or not parser.data is Dictionary:
		_record_error("Invalid combat catalog %s at line %d: %s" % [path, parser.get_error_line(), parser.get_error_message()])
		return {}
	var catalog_data: Dictionary = parser.data
	for id in catalog_data:
		if not catalog_data[id] is Dictionary or str(catalog_data[id].get("id", "")) != str(id):
			_record_error("Combat catalog ID mismatch: %s/%s" % [catalog, id])
	return catalog_data

func _read_world_catalog(catalog: String) -> Dictionary:
	var path := "res://data/world/" + catalog + ".json"
	var parser := JSON.new()
	if not FileAccess.file_exists(path) or parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary or parser.data.is_empty():
		_record_error("Invalid world catalog: " + path)
		return {}
	return parser.data

func _record_error(message: String) -> void:
	errors.append(message)
	push_error(message)

func _index_actions() -> void:
	_action_lookup.clear()
	for action in actions.values():
		var key := str(action.get("animation_family", "")) + ":" + str(action.get("semantic", ""))
		if not _action_lookup.has(key):
			_action_lookup[key] = []
		_action_lookup[key].append(action)
	for action_list in _action_lookup.values():
		action_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("combo_index", 0)) < int(b.get("combo_index", 0)))

func get_action(family: String, semantic: String, combo: int = 0) -> Dictionary:
	var key := family.to_upper() + ":" + semantic.to_upper()
	var action_list: Array = _action_lookup.get(key, [])
	if action_list.is_empty():
		return {}
	var action: Dictionary = action_list[posmod(combo, action_list.size())].duplicate(true)
	if semantic.to_upper() == "PRIMARY_TAP": action["combo_count"] = action_list.size()
	return action

func get_combo_count(family: String) -> int:
	return _action_lookup.get(family.to_upper() + ":PRIMARY_TAP", []).size()
