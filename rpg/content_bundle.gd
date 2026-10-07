extends RefCounted
## Read-only consumer of build.py output. Hashes detect changed bytes, not trusted
## authorship: only reviewed compiler output belongs here. No scripts are loaded.
const FORMAT := 1
const CONTRACT := "mosslight-energy-v1"
const CATALOGS := ["careers", "weapons", "skills", "passives", "equipment", "enemies", "status_effects", "actions", "combat_feel", "reactions", "items", "progression"]
const ADDITIONS := ["items", "weapons", "equipment", "careers", "skills", "passives"]
const WORLD_CATALOGS := ["shops", "quests"]
# Deliberate migration support for known shipped bytes. These files are data,
# never mounted code or caller-provided replacements for the active world.
const LEGACY_SHOPS_V1_SHA := "bffb87377807f07961f18460d253c79c6390f9fa44b69ed193124f4abfd80b5c"
const LEGACY_SHOPS_V1_PATH := "res://data/world/legacy_shops_v1.json"
const ROLES := ["icon", "portrait", "texture", "model", "animation", "audio", "vfx"]
const MAX_MANIFEST_BYTES := 4 * 1024 * 1024
const MAX_CATALOG_BYTES := 16 * 1024 * 1024
const MAX_ASSET_BYTES := 64 * 1024 * 1024
const MAX_TOTAL_BYTES := 256 * 1024 * 1024
const MAX_IMAGE_SIDE := 4096
const MAX_IMAGE_PIXELS := 4194304
# Conservative CPU image + renderer texture + mipmap allowance per pixel.
const MAX_IMAGE_MEMORY := 128 * 1024 * 1024
const MAX_ICON_SIDE := 512
const MAX_ASSETS := 2048

var _catalogs: Dictionary = {}
var _world_catalogs: Dictionary = {}
var _manifest: Dictionary = {}
var _identity: Dictionary = {}
var _bytes: Dictionary = {}
var _images: Dictionary = {}
var _textures: Dictionary = {}
var _bindings: Dictionary = {}

func is_active() -> bool: return not _identity.is_empty()
func identity() -> Dictionary: return _identity.duplicate(true)
func catalogs() -> Dictionary: return _catalogs.duplicate(true)
func world_catalogs() -> Dictionary: return _world_catalogs.duplicate(true)
func metadata() -> Dictionary: return _manifest.duplicate(true)
func asset_bytes(id: String) -> PackedByteArray: return _bytes.get(id, PackedByteArray()).duplicate()

static func display_size(width: int, height: int, kind: String) -> Vector2i:
	var longest := maxi(width, height)
	if kind != "icon" or longest <= MAX_ICON_SIDE: return Vector2i(width, height)
	return Vector2i(maxi(1, floori(float(width) * MAX_ICON_SIDE / longest)), maxi(1, floori(float(height) * MAX_ICON_SIDE / longest)))

static func cache_memory_bytes(width: int, height: int) -> int:
	var base_pixels := width * height
	var mip_pixels := base_pixels
	while width > 1 or height > 1:
		width = maxi(1, width >> 1)
		height = maxi(1, height >> 1)
		mip_pixels += width * height
	# A one-pixel-wide image has nearly twice its base pixels in the full
	# mip chain. Keep the normal allowance, but cover CPU and GPU RGBA8 copies.
	return maxi(base_pixels * 12, mip_pixels * 8)

## Returned textures are shared read-only presentation resources. Callers must
## not update them. Icons have a longest side of at most 512; metadata and
## asset_bytes retain the full source. Queries never reopen files after loading.
func get_texture(catalog: String, id: String, role := "icon") -> Texture2D:
	if role not in ["icon", "portrait", "texture"]: return null
	var asset_id: String = _bindings.get(catalog + "/" + id, {}).get(role, "")
	if not _images.has(asset_id): return null
	if not _textures.has(asset_id): _textures[asset_id] = ImageTexture.create_from_image(_images[asset_id])
	return _textures[asset_id]

static func load_directory(path: String) -> Dictionary:
	return _load_directory(path, {})

## Only SaveSourceContext calls this after verifying the selected source release
## and its source manifest. No Database activation API accepts these hashes.
## Callers select known hashes, never arbitrary paths or replacement JSON.
static func load_detached_directory(path: String, verified_world_sha256: Dictionary) -> Dictionary:
	if not _keys(verified_world_sha256, WORLD_CATALOGS): return _failure("旧内容集缺少完整世界目录指纹")
	for name: String in WORLD_CATALOGS:
		if not _sha(verified_world_sha256[name]): return _failure("旧世界目录指纹无效：" + name)
		var resolved := source_world_data(name, verified_world_sha256[name])
		if not resolved.ok: return resolved
	return _load_directory(path, verified_world_sha256.duplicate(true))

## Resolve only exact current bytes or an explicitly registered historical
## shops file. Source manifests do not authorize unknown old rules.
static func source_world_data(name: String, expected_sha256: String) -> Dictionary:
	if name not in WORLD_CATALOGS or not _sha(expected_sha256): return _failure("旧世界目录或指纹无效")
	var current := _read_json("res://data/world/" + name + ".json", MAX_MANIFEST_BYTES)
	if not current.ok: return current
	if digest(current.raw) == expected_sha256: return current
	if name != "shops" or expected_sha256 != LEGACY_SHOPS_V1_SHA:
		return _failure("基础规则不同，暂不能自动迁移：data/world/" + name + ".json")
	var historical := _read_json(LEGACY_SHOPS_V1_PATH, MAX_MANIFEST_BYTES)
	if not historical.ok or digest(historical.get("raw", PackedByteArray())) != expected_sha256:
		return _failure("受支持的旧商店基线缺失或已改变")
	return historical

static func _load_directory(path: String, verified_world_sha256: Dictionary) -> Dictionary:
	if path.is_empty() or not path.is_absolute_path(): return _failure("内容集路径必须是明确的绝对目录")
	var root := ProjectSettings.globalize_path(path).simplify_path()
	var directory := DirAccess.open(root)
	if directory == null: return _failure("内容集目录不存在或无法读取")
	# The caller selected the root explicitly. Fixed children and assets must not
	# redirect through symlinks/junctions to unrelated files outside that root.
	for child in ["receipt.json", "bundle.json", "catalogs.json", "assets"]:
		if directory.is_link(child): return _failure("内容集成员不能是符号链接或目录联接：" + child)
	var receipt_read := _read_json(root.path_join("receipt.json"), 4096)
	if not receipt_read.ok: return receipt_read
	var receipt: Dictionary = receipt_read.data
	if not _keys(receipt, ["format_version", "bundle_sha256"]) or not _integer(receipt.format_version, FORMAT, FORMAT) or not _sha(receipt.bundle_sha256): return _failure("内容集校验回执格式无效")
	var manifest_read := _read_json(root.path_join("bundle.json"), MAX_MANIFEST_BYTES)
	if not manifest_read.ok: return manifest_read
	if digest(manifest_read.raw) != receipt.bundle_sha256: return _failure("内容集清单校验失败")
	var manifest: Dictionary = manifest_read.data
	var reason := _manifest_error(manifest)
	if not reason.is_empty(): return _failure(reason)
	var catalogs_read := _read_json(root.path_join("catalogs.json"), MAX_CATALOG_BYTES)
	if not catalogs_read.ok: return catalogs_read
	if digest(catalogs_read.raw) != manifest.catalogs_sha256: return _failure("内容集目录数据校验失败")
	var catalogs: Dictionary = catalogs_read.data
	reason = _catalog_error(catalogs, manifest.packs)
	if not reason.is_empty(): return _failure(reason)
	for catalog in ["skills", "actions"]:
		for action in catalogs[catalog].values():
			reason = preload("res://combat/resource_recovery.gd").spell_error(action)
			if not reason.is_empty(): return _failure(str(action.get("id", "")) + ": " + reason)
	# A changed bundled base needs a deliberate rebuild, never a silent merge
	# with whichever files another Database instance happened to read later.
	for name: String in CATALOGS:
		var base := _read_bytes("res://data/combat/" + name + ".json", MAX_CATALOG_BYTES)
		if not base.ok: return base
		if digest(base.raw) != manifest.base_sha256[name]: return _failure("基础目录已改变，请重新编译内容集：" + name)
	# World acquisition rules are part of the same startup snapshot. Legacy
	# bundles inherit bundled world definitions; additions explicitly pin them.
	var worlds: Dictionary = {}
	for name: String in WORLD_CATALOGS:
		var world_read := _read_json("res://data/world/" + name + ".json", MAX_MANIFEST_BYTES) if verified_world_sha256.is_empty() else source_world_data(name, str(verified_world_sha256[name]))
		if not world_read.ok: return world_read
		if manifest.has("acquisition") and digest(world_read.raw) != manifest.acquisition.world_base_sha256[name]:
			return _failure("获取途径的基础目录已改变，请重新编译内容集：" + name)
		worlds[name] = world_read.data
	if manifest.has("acquisition"):
		var acquired: Dictionary = load("res://rpg/content_acquisition.gd").apply(manifest.acquisition, catalogs, worlds, manifest.packs)
		if not acquired.ok: return _failure(acquired.error)
		catalogs = acquired.catalogs
		worlds = acquired.world_catalogs
	var bundle: RefCounted = load("res://rpg/content_bundle.gd").new()
	var total: int = receipt_read.raw.size() + manifest_read.raw.size() + catalogs_read.raw.size()
	var image_memory := 0
	var decode_workspace := 0
	var assets_dir := DirAccess.open(root.path_join("assets"))
	if assets_dir == null and not manifest.assets.is_empty(): return _failure("内容集素材目录不存在")
	var frozen_paths: Dictionary = {}
	for id: String in manifest.assets:
		var asset: Dictionary = manifest.assets[id]
		if assets_dir.is_link(str(asset.path).get_file()): return _failure("素材不能是符号链接：" + id)
		var raw: PackedByteArray
		if frozen_paths.has(asset.path):
			raw = frozen_paths[asset.path]
		else:
			var read := _read_bytes(root.path_join(asset.path), MAX_ASSET_BYTES)
			if not read.ok: return read
			raw = read.raw
			total += raw.size()
			if total > MAX_TOTAL_BYTES: return _failure("内容集累计文件数据超过 256 MiB")
			frozen_paths[asset.path] = raw
		if raw.size() != int(asset.bytes) or digest(raw) != asset.sha256: return _failure("素材长度或 SHA256 不匹配：" + id)
		bundle._bytes[id] = raw
		if str(asset.path).ends_with(".png"):
			if raw.size() < 33 or raw.slice(0, 8) != PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]) or _u32(raw, 8) != 13 or raw.slice(12, 16).get_string_from_ascii() != "IHDR": return _failure("PNG 文件头无效：" + id)
			var width := _u32(raw, 16)
			var height := _u32(raw, 20)
			if width < 1 or height < 1 or width > MAX_IMAGE_SIDE or height > MAX_IMAGE_SIDE or width * height > MAX_IMAGE_PIXELS: return _failure("PNG 解码尺寸超过预览限制：" + id)
			if (asset.has("width") and int(asset.width) != width) or (asset.has("height") and int(asset.height) != height): return _failure("PNG 实际尺寸与清单不符：" + id)
			var cached_size := display_size(width, height, str(asset.kind))
			image_memory += cache_memory_bytes(cached_size.x, cached_size.y)
			# Decode sources sequentially. Reserve transient source/convert/resize
			# space in addition to every retained display image and texture.
			if cached_size != Vector2i(width, height): decode_workspace = maxi(decode_workspace, width * height * 16)
			if image_memory + decode_workspace > MAX_IMAGE_MEMORY: return _failure("内容集累计图像与解码临时内存预算超过 128 MiB")
			if not _png_has_complete_chunks(raw): return _failure("PNG 数据块不完整：" + id)
			var decoded := Image.new()
			if decoded.load_png_from_buffer(raw) != OK or decoded.is_empty() or decoded.get_width() != width or decoded.get_height() != height: return _failure("PNG 完整解码失败：" + id)
			decoded.convert(Image.FORMAT_RGBA8)
			if cached_size != Vector2i(width, height): decoded.resize(cached_size.x, cached_size.y, Image.INTERPOLATE_LANCZOS)
			decoded.generate_mipmaps()
			bundle._images[id] = decoded
	# Every declared binding must resolve before the bundle can become visible.
	for binding: Dictionary in manifest.bindings:
		var key: String = binding.catalog + "/" + binding.id
		if bundle._bindings.has(key): return _failure("内容集存在重复素材绑定：" + key)
		if not catalogs[binding.catalog].has(binding.id): return _failure("素材绑定内容不存在：" + key)
		for role: String in binding.assets:
			var asset_id: String = binding.assets[role]
			if not manifest.assets.has(asset_id) or manifest.assets[asset_id].kind != role or asset_id.get_slice(":", 0) != binding.id.get_slice(":", 0): return _failure("素材绑定角色或所属包不匹配：" + key)
		bundle._bindings[key] = binding.assets.duplicate(true)
	bundle._catalogs = catalogs.duplicate(true)
	bundle._world_catalogs = worlds.duplicate(true)
	bundle._manifest = manifest.duplicate(true)
	bundle._identity = {"format_version": FORMAT, "contract": CONTRACT, "bundle_sha256": receipt.bundle_sha256,
		"catalogs_sha256": manifest.catalogs_sha256, "base_sha256": manifest.base_sha256.duplicate(true), "packs": manifest.packs.duplicate(true)}
	return {"ok": true, "error": "", "bundle": bundle, "identity": bundle.identity()}

static func _manifest_error(data: Dictionary) -> String:
	if not _keys(data, ["format_version", "contract", "catalogs_file", "catalogs_sha256", "base_sha256", "packs", "assets", "bindings"], ["acquisition"]): return "内容集清单字段无效"
	if not _integer(data.format_version, FORMAT, FORMAT) or data.contract != CONTRACT or data.catalogs_file != "catalogs.json" or not _sha(data.catalogs_sha256): return "内容集格式或运行时契约不兼容"
	if data.has("acquisition"):
		var plan: Variant = data.acquisition
		if not plan is Dictionary or not _keys(plan, ["format_version", "world_base_sha256", "shops", "quests", "enemy_drops"]) or not _integer(plan.format_version, 1, 1): return "获取途径清单字段或版本无效"
		if not plan.world_base_sha256 is Dictionary or not _keys(plan.world_base_sha256, WORLD_CATALOGS): return "获取途径缺少完整世界目录指纹"
		for value in plan.world_base_sha256.values():
			if not _sha(value): return "获取途径世界目录指纹无效"
	if not data.base_sha256 is Dictionary or not _keys(data.base_sha256, CATALOGS): return "内容集缺少完整基础目录指纹"
	for hash_value in data.base_sha256.values():
		if not _sha(hash_value): return "基础目录指纹无效"
	if not data.packs is Array or data.packs.is_empty() or data.packs.size() > 128: return "内容包列表无效"
	var packs: Dictionary = {}
	for pack in data.packs:
		if not pack is Dictionary or not _keys(pack, ["pack_id", "version", "sha256"]) or not _match(pack.pack_id, "^[a-z][a-z0-9_]{1,47}$") or not _match(pack.version, "^[0-9]+\\.[0-9]+\\.[0-9]+$") or not _sha(pack.sha256): return "内容包身份或版本无效"
		if packs.has(pack.pack_id): return "内容包身份重复"
		packs[pack.pack_id] = true
	if not data.assets is Dictionary or data.assets.size() > MAX_ASSETS or not data.bindings is Array or data.bindings.size() > 16384: return "素材或绑定列表超出限制"
	for id in data.assets:
		if not _namespaced(id, packs): return "素材 ID 或所属包无效"
		var asset: Variant = data.assets[id]
		if not asset is Dictionary or not _keys(asset, ["kind", "path", "sha256", "bytes"], ["width", "height", "license", "source"]) or asset.kind not in ROLES or not _sha(asset.sha256) or not _integer(asset.bytes, 1, MAX_ASSET_BYTES): return "素材元数据无效：" + id
		if not _match(asset.path, "^assets/[a-f0-9]{64}\\.(png|glb|wav|ogg)$") or str(asset.path).get_file().get_basename() != asset.sha256: return "素材路径不是编译器生成的规范相对路径：" + id
		var suffix: String = str(asset.path).get_extension()
		if (asset.kind in ["icon", "portrait", "texture"] and suffix != "png") or (asset.kind in ["model", "animation"] and suffix != "glb") or (asset.kind == "audio" and suffix not in ["wav", "ogg"]) or (asset.kind == "vfx" and suffix not in ["png", "glb"]): return "素材角色与格式不匹配：" + id
		for field: String in ["width", "height"]:
			if asset.has(field) and (suffix != "png" or not _integer(asset[field], 1, 16384)): return "素材尺寸元数据无效：" + id
		for field: String in ["license", "source"]:
			if asset.has(field) and (not asset[field] is String or str(asset[field]).length() > 4096): return "素材来源元数据无效：" + id
	for binding in data.bindings:
		if not binding is Dictionary or not _keys(binding, ["catalog", "id", "assets"]) or binding.catalog not in ADDITIONS or not _namespaced(binding.id, packs) or not binding.assets is Dictionary or binding.assets.is_empty() or binding.assets.size() > ROLES.size(): return "素材绑定字段无效"
		for role in binding.assets:
			if role not in ROLES or not _namespaced(binding.assets[role], packs): return "素材绑定角色或 ID 无效"
	return ""

static func _catalog_error(data: Dictionary, pack_entries: Array) -> String:
	if not _keys(data, CATALOGS): return "内容集必须包含完整的十二份目录"
	var packs: Dictionary = {}
	for entry: Dictionary in pack_entries: packs[entry.pack_id] = true
	for name: String in CATALOGS:
		if not data[name] is Dictionary or data[name].is_empty() or data[name].size() > 16384: return "内容目录类型或数量无效：" + name
		for id in data[name]:
			# Existing animation-family keys such as SINGLE_BLADE are uppercase.
			# Added content still uses the compiler's lowercase pack namespace.
			if not id is String or id.length() > 160 or not _match(id, "^[A-Za-z][A-Za-z0-9_]*(?::[a-z][a-z0-9_]*)?$") or (":" in id and not _namespaced(id, packs)): return "内容目录 ID 无效：" + name
			var entry: Variant = data[name][id]
			if not entry is Dictionary or entry.get("id") != id: return "内容目录条目身份不匹配：" + name + "/" + id
	return ""

static func _read_json(path: String, limit: int) -> Dictionary:
	var read := _read_bytes(path, limit)
	if not read.ok: return read
	var source: String = read.raw.get_string_from_utf8()
	if source.to_utf8_buffer() != read.raw: return _failure("内容集文件不是完整 UTF-8：" + path.get_file())
	var parser := JSON.new()
	if parser.parse(source) != OK or not parser.data is Dictionary: return _failure("内容集 JSON 无效：" + path.get_file())
	var reason := _json_error(parser.data, 0, [0])
	if not reason.is_empty(): return _failure(reason)
	return {"ok": true, "error": "", "raw": read.raw, "data": parser.data}

static func _read_bytes(path: String, limit: int) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return _failure("内容集文件无法读取：" + path.get_file())
	var length := file.get_length()
	if length < 1 or length > limit:
		file.close()
		return _failure("内容集文件为空或超过大小限制：" + path.get_file())
	var raw := file.get_buffer(length)
	file.close()
	if raw.size() != length: return _failure("内容集文件读取不完整：" + path.get_file())
	return {"ok": true, "error": "", "raw": raw}

static func digest(raw: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(raw)
	return context.finish().hex_encode()

static func _json_error(value: Variant, depth: int, budget: Array) -> String:
	budget[0] += 1
	if depth > 32 or int(budget[0]) > 500000: return "内容集 JSON 深度或节点数量超限"
	if value is Dictionary:
		for key in value:
			if not key is String or key.length() > 4096: return "内容集 JSON 字段名无效"
			var reason := _json_error(value[key], depth + 1, budget)
			if not reason.is_empty(): return reason
	elif value is Array:
		for entry in value:
			var reason := _json_error(entry, depth + 1, budget)
			if not reason.is_empty(): return reason
	elif value is float and not is_finite(value): return "内容集 JSON 包含非有限数值"
	elif value is String and value.length() > 65536: return "内容集 JSON 文本超限"
	return ""

static func _u32(raw: PackedByteArray, at: int) -> int:
	return (int(raw[at]) << 24) | (int(raw[at + 1]) << 16) | (int(raw[at + 2]) << 8) | int(raw[at + 3])

## Reject truncated/trailing chunk data before invoking the native decoder.
## This is a bounds check, not a replacement for full image decoding below.
static func _png_has_complete_chunks(raw: PackedByteArray) -> bool:
	var offset := 8
	var seen_data := false
	while offset + 12 <= raw.size():
		var length := _u32(raw, offset)
		if length > raw.size() - offset - 12: return false
		var kind := raw.slice(offset + 4, offset + 8).get_string_from_ascii()
		if kind == "IHDR" and offset != 8: return false
		if kind == "IDAT": seen_data = true
		if kind == "IEND": return seen_data and length == 0 and offset + 12 == raw.size()
		offset += length + 12
	return false

static func _sha(value: Variant) -> bool: return _match(value, "^[a-f0-9]{64}$")
static func _namespaced(value: Variant, packs: Dictionary) -> bool:
	return _match(value, "^[a-z][a-z0-9_]{1,47}:[a-z][a-z0-9_]{0,95}$") and packs.has(value.get_slice(":", 0))
static func _match(value: Variant, pattern: String) -> bool:
	if not value is String: return false
	var expression := RegEx.new()
	expression.compile(pattern)
	return expression.search(value) != null
static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= minimum and value <= maximum and float(value) == floorf(float(value))
static func _keys(data: Dictionary, required: Array, optional: Array = []) -> bool:
	for key in required:
		if not data.has(key): return false
	for key in data:
		if key not in required and key not in optional: return false
	return true
static func _failure(reason: String) -> Dictionary: return {"ok": false, "error": reason, "identity": {}}
