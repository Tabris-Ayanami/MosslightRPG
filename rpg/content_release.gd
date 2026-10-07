extends RefCounted
## A fixed author-produced release. Activation precedes App and SaveRepository;
## it neither imports saves nor grants preview samples. Hashes detect mismatch,
## not authorship. Runtime assets remain handled by the existing ContentBundle.
const Database = preload("res://combat/combat_database.gd")
const Bundle = preload("res://rpg/content_bundle.gd")
const FORMAT := 1
const PCK_FILE := "MosslightRPG.pck"
static var _release: Dictionary = {}
static var _identity: Dictionary = {}
static var _source_manifest: Dictionary = {}
static var _storage := ""

static func is_active() -> bool: return not _release.is_empty()
static func metadata() -> Dictionary: return _release.duplicate(true)
static func identity() -> Dictionary: return _identity.duplicate(true)
## Source scripts are compiled during export. Their baseline fingerprints come
## from the build record verified alongside the actual current PCK at startup.
static func source_fingerprint(path: String) -> String:
	var value: Variant = _source_manifest.get(path, "")
	return value if Bundle._sha(value) else ""
static func save_directory() -> String: return _storage.path_join("adventures") if is_active() else ""
static func preferences_path() -> String: return _storage.path_join("preferences.cfg") if is_active() else ""

## storage_root is dependency injection for tools/tests; normal startup uses
## user://releases. It is not read from the release manifest or player settings.
static func activate(directory: String, storage_root := "user://releases") -> Dictionary:
	if is_active() or Database.content_started(): return _failure("发行内容必须在游戏数据库创建前确定，请重新启动")
	if directory.is_empty() or not directory.is_absolute_path(): return _failure("发行目录必须是明确的绝对路径")
	if storage_root.is_empty() or not storage_root.is_absolute_path(): return _failure("存档根目录无效")
	var root := ProjectSettings.globalize_path(directory).simplify_path()
	if OS.has_feature("formal_release") and not _same_directory(root, distribution_directory()):
		return _failure("发行清单必须与当前游戏文件放在同一目录")
	var folder := DirAccess.open(root)
	if folder == null: return _failure("发行目录不存在或无法读取")
	for name in ["release.json", PCK_FILE, "source-manifest.json", "content"]:
		if folder.is_link(name): return _failure("发行成员不能是符号链接或目录联接：" + name)
	var read: Dictionary = Bundle._read_json(root.path_join("release.json"), 65536)
	if not read.ok: return _failure("发行清单无法加载：" + str(read.error))
	var data: Dictionary = read.data
	var reason := _manifest_error(data)
	if not reason.is_empty(): return _failure(reason)
	if FileAccess.get_sha256(root.path_join(PCK_FILE)) != data.pck.sha256: return _failure("游戏文件与发行清单不一致，请恢复完整发行目录")
	var sources: Dictionary = Bundle._read_bytes(root.path_join("source-manifest.json"), 4 * 1024 * 1024)
	if not sources.ok or Bundle.digest(sources.raw) != data.source_manifest_sha256: return _failure("发行构建记录缺失或已改变")
	var source_record: Variant = JSON.parse_string(sources.raw.get_string_from_utf8())
	var selected: Dictionary = {}
	if not data.content.is_empty():
		selected = Database.configure_content_bundle(root.path_join("content"), data.content.identity)
		if not selected.ok: return _failure(str(selected.error))
	# No work below this point can fail. Freeze only the validated choice, then
	# publish context; failed checks above leave content selection untouched.
	Database.lock_content_selection()
	_identity = selected.get("identity", {}).duplicate(true)
	_source_manifest = source_record.duplicate(true) if source_record is Dictionary else {}
	_release = data.duplicate(true)
	_storage = ProjectSettings.globalize_path(storage_root).simplify_path().path_join(data.release_id).path_join(str(_identity.get("bundle_sha256", "builtin")))
	return {"ok": true, "error": "", "identity": identity(), "release": metadata(), "saves_directory": save_directory(), "preferences_path": preferences_path()}

static func _manifest_error(data: Dictionary) -> String:
	if not Bundle._keys(data, ["format_version", "release_id", "version", "engine_version", "source_manifest_sha256", "pck", "content"]): return "发行清单字段无效"
	if not Bundle._integer(data.format_version, FORMAT, FORMAT): return "不支持的发行清单版本"
	if not Bundle._match(data.release_id, "^[a-z][a-z0-9_]{0,47}$"): return "发行系列名称无效"
	if not Bundle._match(data.version, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$"): return "发行版本无效"
	var version_core: String = data.version.get_slice("+", 0)
	var prerelease: PackedStringArray = version_core.split("-", true, 1)
	if prerelease.size() > 1:
		for part: String in prerelease[1].split("."):
			if Bundle._match(part, "^[0-9]+$") and part.length() > 1 and part.begins_with("0"): return "发行版本无效"
	var engine := Engine.get_version_info()
	var stem := "%d.%d.%d.%s." % [engine.major, engine.minor, engine.patch, engine.status]
	if not data.engine_version is String or data.engine_version.length() > 128 or not data.engine_version.begins_with(stem): return "游戏引擎版本与发行版本不兼容"
	if not Bundle._sha(data.source_manifest_sha256): return "发行构建记录指纹无效"
	if not data.pck is Dictionary or not Bundle._keys(data.pck, ["path", "sha256"]) or data.pck.path != PCK_FILE or not Bundle._sha(data.pck.sha256): return "游戏文件引用无效"
	if not data.content is Dictionary: return "发行内容引用无效"
	if not data.content.is_empty():
		if not Bundle._keys(data.content, ["path", "identity"]) or data.content.path != "content" or not data.content.identity is Dictionary or data.content.identity.is_empty(): return "发行内容引用无效"
	return ""

static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "error": reason, "identity": {}}

static func distribution_directory() -> String:
	return distribution_pack().get_base_dir()

static func distribution_pack() -> String:
	# Godot consumes --main-pack before exposing get_cmdline_args; a packed
	# res:// also has no physical resource directory. Our editor-based PCK
	# runner therefore sets cwd/--path to the distribution it is verifying.
	# Native exports always use their executable directory, independent of cwd.
	if OS.has_feature("editor") and OS.has_feature("formal_release"):
		return DirAccess.open(".").get_current_dir().path_join(PCK_FILE)
	return OS.get_executable_path().get_base_dir().path_join(PCK_FILE)

static func _same_directory(a: String, b: String) -> bool:
	var left := a.simplify_path().replace("\\", "/").trim_suffix("/")
	var right := b.simplify_path().replace("\\", "/").trim_suffix("/")
	return left.to_lower() == right.to_lower() if OS.has_feature("windows") else left == right
