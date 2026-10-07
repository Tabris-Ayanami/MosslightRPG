extends RefCounted
## Detached, read-only catalog context for validating/migrating saves from an
## older fixed release. This never activates content or constructs a Database.
const Bundle = preload("res://rpg/content_bundle.gd")
const Release = preload("res://rpg/content_release.gd")
const COMBAT_CATALOGS := Bundle.CATALOGS
const REQUIRED_WORLDS := ["shops", "quests", "objects", "npcs", "encounters", "chapters"]
const RULE_FILES := ["rpg/race_catalog.gd", "combat/resource_recovery.gd"]
const MAX_SOURCE_MANIFEST_BYTES := 4194304

var careers: Dictionary = {}
var weapons: Dictionary = {}
var skills: Dictionary = {}
var passives: Dictionary = {}
var equipment: Dictionary = {}
var enemies: Dictionary = {}
var status_effects: Dictionary = {}
var actions: Dictionary = {}
var combat_feel: Dictionary = {}
var reactions: Dictionary = {}
var items: Dictionary = {}
var progression: Dictionary = {}
var _catalogs: Dictionary = {}
var _worlds: Dictionary = {}
var _identity: Dictionary = {}

func identity() -> Dictionary:
	return _identity.duplicate(true)

func is_active() -> bool:
	return false

func world_catalog(name: String) -> Dictionary:
	return _worlds.get(name, {}).duplicate(true)

func catalog_snapshot() -> Dictionary:
	var snapshot: Dictionary = {}
	for catalog: String in COMBAT_CATALOGS:
		snapshot[catalog] = get(catalog).duplicate(true)
	return snapshot

## Test and migration-helper factory. Inputs are copied; the returned context is
## deliberately detached from CombatDatabase and ContentRelease globals.
static func from_catalogs(catalogs: Dictionary, worlds: Dictionary, identity: Dictionary) -> RefCounted:
	var context: RefCounted = load("res://rpg/save_source_context.gd").new()
	context._set_data(catalogs, worlds, identity)
	return context

static func open_release(directory: String) -> Dictionary:
	if directory.is_empty() or not directory.is_absolute_path():
		return _failure("旧发行目录必须是明确的绝对路径")
	var root := ProjectSettings.globalize_path(directory).simplify_path()
	var folder := DirAccess.open(root)
	if folder == null:
		return _failure("旧发行目录不存在或无法读取")
	for child in ["release.json", "MosslightRPG.pck", "source-manifest.json", "content"]:
		if folder.is_link(child):
			return _failure("旧发行成员不能是符号链接或目录联接：" + child)

	var fingerprints: Dictionary = {}
	var release_path := root.path_join("release.json")
	var release_bytes := _read_absolute(release_path, 65536)
	if not release_bytes.ok:
		return _failure("旧发行清单无法读取：" + str(release_bytes.error))
	fingerprints["release.json"] = Bundle.digest(release_bytes.bytes)
	var release_parse := _parse_object(release_bytes.bytes)
	if not release_parse.ok:
		return _failure("旧发行清单无效：" + str(release_parse.error))
	var release: Dictionary = release_parse.data
	var manifest_error := Release._manifest_error(release)
	if not manifest_error.is_empty():
		return _failure("旧发行清单无效：" + manifest_error)

	var source_path := root.path_join("source-manifest.json")
	var source_bytes := _read_absolute(source_path, MAX_SOURCE_MANIFEST_BYTES)
	if not source_bytes.ok:
		return _failure("旧发行构建记录无法读取：" + str(source_bytes.error))
	fingerprints["source-manifest.json"] = Bundle.digest(source_bytes.bytes)
	if fingerprints["source-manifest.json"] != release.source_manifest_sha256:
		return _failure("旧发行构建记录指纹不匹配")
	var source_parse := _parse_object(source_bytes.bytes)
	if not source_parse.ok:
		return _failure("旧发行构建记录无效：" + str(source_parse.error))
	var source_manifest: Dictionary = source_parse.data
	for path: Variant in source_manifest:
		if not path is String or not Bundle._sha(source_manifest[path]):
			return _failure("旧发行构建记录必须是平面 path:sha256 映射")

	# Every bundled contract file must match. Only the explicitly registered
	# historical shops bytes may differ, for a later semantic price migration.
	var source_world_sha256: Dictionary = {}
	var source_worlds: Dictionary = {}
	var required_paths: Array[String] = []
	for catalog: String in COMBAT_CATALOGS:
		required_paths.append("data/combat/" + catalog + ".json")
	for world: String in REQUIRED_WORLDS:
		required_paths.append("data/world/" + world + ".json")
	required_paths.append_array(RULE_FILES)
	for path: String in required_paths:
		if not source_manifest.has(path):
			return _failure("基础规则不同，暂不能自动迁移：旧发行缺少 " + path)
		if path in RULE_FILES:
			if not _source_rule_matches(path, str(source_manifest[path]), OS.has_feature("formal_release")):
				return _failure("基础规则不同，暂不能自动迁移：" + path)
			continue
		if path in ["data/world/shops.json", "data/world/quests.json"]:
			var name := path.get_file().get_basename()
			var historical := Bundle.source_world_data(name, str(source_manifest[path]))
			if not historical.ok: return _failure(str(historical.error))
			source_world_sha256[name] = source_manifest[path]
			source_worlds[name] = historical.data
			continue
		var current_bytes := _read_resource("res://" + path)
		if not current_bytes.ok:
			return _failure("基础规则不同，暂不能自动迁移：当前文件不可读 " + path)
		if Bundle.digest(current_bytes.bytes) != source_manifest[path]:
			return _failure("基础规则不同，暂不能自动迁移：" + path)

	var pck_path := root.path_join("MosslightRPG.pck")
	var pck_sha := FileAccess.get_sha256(pck_path)
	if not Bundle._sha(pck_sha) or pck_sha != release.pck.sha256:
		return _failure("旧发行游戏文件与发行清单不一致")
	fingerprints["MosslightRPG.pck"] = pck_sha

	var catalogs: Dictionary = {}
	var worlds: Dictionary = {}
	var identity: Dictionary = {}
	if release.content.is_empty():
		for catalog: String in COMBAT_CATALOGS:
			var parsed := _read_resource_object("res://data/combat/" + catalog + ".json")
			if not parsed.ok:
				return _failure("内置旧发行目录无法读取：" + catalog)
			catalogs[catalog] = parsed.data
		for name: String in Bundle.WORLD_CATALOGS:
			worlds[name] = source_worlds[name].duplicate(true)
	else:
		var content_path := root.path_join("content")
		var loaded: Dictionary = Bundle.load_detached_directory(content_path, source_world_sha256)
		if not loaded.get("ok", false):
			return _failure("旧发行内容包无法验证：" + str(loaded.get("error", "")))
		if not _same_json(loaded.identity, release.content.identity):
			return _failure("旧发行内容包身份与发行清单不一致")
		var bundle: RefCounted = loaded.bundle
		catalogs = bundle.catalogs()
		worlds = bundle.world_catalogs()
		identity = bundle.identity()
		var content_fingerprints := _bundle_fingerprints(content_path, bundle)
		if not content_fingerprints.ok:
			return _failure(str(content_fingerprints.error))
		for path: String in content_fingerprints.hashes:
			fingerprints["content/" + path] = content_fingerprints.hashes[path]

	var context: RefCounted = from_catalogs(catalogs, worlds, identity)
	return {"ok": true, "error": "", "context": context, "release": release.duplicate(true),
		"source_label": _source_label(release), "fingerprints": fingerprints.duplicate(true)}

func _set_data(catalogs: Dictionary, worlds: Dictionary, identity: Dictionary) -> void:
	_catalogs = catalogs.duplicate(true)
	_worlds = worlds.duplicate(true)
	_identity = identity.duplicate(true)
	for catalog: String in COMBAT_CATALOGS:
		set(catalog, _catalogs.get(catalog, {}).duplicate(true))

static func _bundle_fingerprints(directory: String, bundle: RefCounted) -> Dictionary:
	var identity: Dictionary = bundle.identity()
	var manifest: Dictionary = bundle.metadata()
	var expected: Dictionary = {}
	# These paths and hashes come from the already verified, detached bundle
	# snapshot. Never trust paths from a second, independently read manifest.
	var receipt_read := _read_absolute(directory.path_join("receipt.json"), 4096)
	if not receipt_read.ok:
		return {"ok": false, "error": "旧发行内容回执读取失败"}
	var receipt_parse := _parse_object(receipt_read.bytes)
	if not receipt_parse.ok or not Bundle._keys(receipt_parse.data, ["format_version", "bundle_sha256"]) or not Bundle._integer(receipt_parse.data.format_version, Bundle.FORMAT, Bundle.FORMAT) or receipt_parse.data.bundle_sha256 != identity.bundle_sha256:
		return {"ok": false, "error": "旧发行内容回执与身份不一致"}
	expected["receipt.json"] = Bundle.digest(receipt_read.bytes)
	expected["bundle.json"] = identity.bundle_sha256
	expected["catalogs.json"] = identity.catalogs_sha256
	var assets: Variant = manifest.get("assets", {})
	if not assets is Dictionary:
		return {"ok": false, "error": "旧发行内容素材清单无效"}
	for id: String in assets:
		var asset: Dictionary = assets[id]
		expected[str(asset.path)] = str(asset.sha256)
	var hashes: Dictionary = {}
	for relative_path: String in expected:
		var read := _read_absolute(directory.path_join(relative_path), Bundle.MAX_ASSET_BYTES if relative_path.begins_with("assets/") else Bundle.MAX_CATALOG_BYTES)
		if not read.ok:
			return {"ok": false, "error": "旧发行内容文件读取失败：" + relative_path}
		var actual := Bundle.digest(read.bytes)
		if actual != expected[relative_path]:
			return {"ok": false, "error": "旧发行内容文件指纹不匹配：" + relative_path}
		hashes[relative_path] = actual
	return {"ok": true, "error": "", "hashes": hashes}

static func _source_label(release: Dictionary) -> String:
	var label := str(release.release_id) + " " + str(release.version)
	var content: Dictionary = release.content
	if content.is_empty():
		return label + " · builtin"
	var identity: Dictionary = content.identity
	var versions: PackedStringArray = []
	for pack: Dictionary in identity.get("packs", []):
		versions.append(str(pack.pack_id) + " " + str(pack.version))
	return label + " · " + (", ".join(versions) if not versions.is_empty() else "content")

static func _read_resource_object(path: String) -> Dictionary:
	var read := _read_resource(path)
	if not read.ok:
		return read
	var parsed := _parse_object(read.bytes)
	return parsed

static func _read_resource(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "文件不存在"}
	return {"ok": true, "bytes": FileAccess.get_file_as_bytes(path)}

static func _read_absolute(path: String, limit: int) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "文件不存在或不可读"}
	if file.get_length() > limit:
		file.close()
		return {"ok": false, "error": "文件超过读取上限"}
	var expected_length := file.get_length()
	var bytes := file.get_buffer(expected_length)
	file.close()
	if bytes.size() != expected_length:
		return {"ok": false, "error": "文件读取不完整"}
	return {"ok": true, "bytes": bytes}

static func _parse_object(bytes: PackedByteArray) -> Dictionary:
	if not _valid_utf8(bytes):
		return {"ok": false, "error": "JSON 不是有效 UTF-8"}
	var parser := JSON.new()
	var text := bytes.get_string_from_utf8()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return {"ok": false, "error": "预期 JSON 对象"}
	return {"ok": true, "data": parser.data}

static func _source_rule_matches(path: String, expected: String, formal_release: bool) -> bool:
	if path not in RULE_FILES or not Bundle._sha(expected):
		return false
	if formal_release:
		return Release.is_active() and Release.source_fingerprint(path) == expected
	var current := _read_resource("res://" + path)
	return current.ok and Bundle.digest(current.bytes) == expected

static func _valid_utf8(bytes: PackedByteArray) -> bool:
	var index := 0
	while index < bytes.size():
		var first := int(bytes[index])
		if first <= 0x7f:
			index += 1
			continue
		var count := 0
		var second_min := 0x80
		var second_max := 0xbf
		if first >= 0xc2 and first <= 0xdf:
			count = 1
		elif first >= 0xe0 and first <= 0xef:
			count = 2
			if first == 0xe0: second_min = 0xa0
			if first == 0xed: second_max = 0x9f
		elif first >= 0xf0 and first <= 0xf4:
			count = 3
			if first == 0xf0: second_min = 0x90
			if first == 0xf4: second_max = 0x8f
		else:
			return false
		if index + count >= bytes.size():
			return false
		var second := int(bytes[index + 1])
		if second < second_min or second > second_max:
			return false
		for offset in range(2, count + 1):
			var continuation := int(bytes[index + offset])
			if continuation < 0x80 or continuation > 0xbf:
				return false
		index += count + 1
	return true

static func _same_json(left: Variant, right: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "context": null, "release": {}, "source_label": "", "fingerprints": {}}
