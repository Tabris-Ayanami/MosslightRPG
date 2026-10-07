extends SceneTree
## Hermetic runtime bundle tests. All writes are confined to fresh OS-temp
## directories; no scenes, preferences, repositories, or user:// saves are used.
## Optional --bundle=<absolute build.py output> exercises the real compiler.
const Bundle = preload("res://rpg/content_bundle.gd")
const Database = preload("res://combat/combat_database.gd")
var checks := 0
var failures: Array[String] = []
var temp_root := ""
var source: Dictionary = {}
var case_number := 0

func _initialize() -> void: call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func run() -> void:
	if "--default-only" in OS.get_cmdline_user_args():
		var db := Database.new()
		verify(not db.is_active() and db.identity().is_empty() and db.errors.is_empty(), "ordinary startup uses builtin content and empty identity")
		verify(not Database.configure_content_bundle(OS.get_temp_dir()).ok, "first builtin Database permanently locks configuration")
		finish()
		return
	var child_output: Array = []
	var child_code := OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/content_bundle.gd", "--", "--default-only"], child_output, true)
	verify(child_code == 0, "separate normal startup never activates a content pack")
	temp_root = OS.get_temp_dir().path_join("mosslight_bundle_test_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	verify(DirAccess.make_dir_absolute(temp_root) == OK, "create exclusive OS-temp fixture root")
	source = fixture()
	if source.is_empty():
		verify(false, "fixture could be read")
		finish()
		return
	var good := write_case(source)
	var loaded: Dictionary = Bundle.load_directory(good)
	verify(loaded.ok, "complete compiled bundle loads: " + loaded.error)
	if not loaded.ok:
		finish()
		return
	var bundle: RefCounted = loaded.bundle
	var icon_binding: Dictionary = {}
	for binding: Dictionary in source.manifest.bindings:
		if binding.assets.has("icon"):
			icon_binding = binding
			break
	verify(not icon_binding.is_empty(), "fixture contains a real icon binding")
	if icon_binding.is_empty():
		finish()
		return
	var asset_id: String = icon_binding.assets.icon
	var asset: Dictionary = source.manifest.assets[asset_id]
	var texture: Texture2D = bundle.get_texture(icon_binding.catalog, icon_binding.id)
	verify(texture != null and Vector2i(texture.get_size()) == Bundle.display_size(int(asset.width), int(asset.height), str(asset.kind)), "PNG fully decodes and produces a correctly sized display Texture2D")
	verify(bundle.get_texture(icon_binding.catalog, icon_binding.id, "model") == null and bundle.get_texture("items", "missing") == null, "unsupported renderer roles and absent bindings return no texture")
	verify(bundle.identity() == loaded.identity and not JSON.stringify(loaded.identity).contains(temp_root), "identity is reproducible pure data without host paths")
	var catalogs: Dictionary = bundle.catalogs()
	catalogs[icon_binding.catalog][icon_binding.id].name = "mutated"
	var metadata: Dictionary = bundle.metadata()
	metadata.assets.clear()
	var identity: Dictionary = bundle.identity()
	identity.packs.clear()
	var bytes: PackedByteArray = bundle.asset_bytes(asset_id)
	bytes[0] = 0
	verify(bundle.catalogs()[icon_binding.catalog][icon_binding.id].get("name") != "mutated" and not bundle.metadata().assets.is_empty() and not bundle.identity().packs.is_empty() and bundle.asset_bytes(asset_id)[0] == 137, "catalogs, metadata, identity and encoded bytes are detached query results")
	write_bytes(good.path_join(asset.path), PackedByteArray([0]))
	verify(bundle.get_texture(icon_binding.catalog, icon_binding.id) == texture and bundle.asset_bytes(asset_id).size() == int(asset.bytes), "activated assets never drift when source files change")
	verify(not Bundle.load_directory(good).ok, "a new load rejects the now changed source asset")
	verify(not Bundle.load_directory("relative/bundle").ok and not Bundle.load_directory(temp_root.path_join("absent")).ok, "relative and missing bundle directories fail explicitly")
	var retained: Dictionary = source.duplicate(true)
	# Valid empty PCM WAV: retained as bytes, deliberately no audio/player API.
	var wav := PackedByteArray([82,73,70,70,36,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,64,31,0,0,128,62,0,0,2,0,16,0,100,97,116,97,0,0,0,0])
	var audio_id := asset_id.get_slice(":", 0) + ":sound"
	var audio_hash := Bundle.digest(wav)
	var audio_path := "assets/" + audio_hash + ".wav"
	retained.files[audio_path] = wav
	retained.manifest.assets[audio_id] = {"kind": "audio", "path": audio_path, "sha256": audio_hash, "bytes": wav.size()}
	retained.manifest.bindings[0].assets.audio = audio_id
	var retained_result: Dictionary = Bundle.load_directory(write_case(retained))
	verify(retained_result.ok and retained_result.bundle.asset_bytes(audio_id) == wav and retained_result.bundle.get_texture(retained.manifest.bindings[0].catalog, retained.manifest.bindings[0].id, "audio") == null, "non-PNG assets retain verified bytes without promising runtime rendering")
	cache_coverage(asset_id, icon_binding)

	reject("receipt hash", func(m: Dictionary): m["receipt_override"] = {"format_version": 1, "bundle_sha256": "0".repeat(64)})
	reject("unknown receipt field", func(m: Dictionary): m["receipt_extra"] = true)
	reject("manifest byte drift", func(m: Dictionary): m["manifest_drift"] = true)
	reject("catalog byte drift", func(m: Dictionary): m["catalog_drift"] = true)
	reject("missing catalog file", func(m: Dictionary): m["omit"] = "catalogs.json")
	reject("wrong contract", func(m: Dictionary): m.manifest.contract = "old-mana-v1")
	reject("unknown manifest field", func(m: Dictionary): m.manifest.extra = true)
	reject("changed base fingerprint", func(m: Dictionary): m.manifest.base_sha256.items = "0".repeat(64))
	reject("missing base fingerprint", func(m: Dictionary): m.manifest.base_sha256.erase("skills"))
	reject("missing catalog", func(m: Dictionary): m.catalogs.erase("weapons"))
	reject("non-dictionary catalog", func(m: Dictionary): m.catalogs.items = [])
	reject("mismatched entry id", func(m: Dictionary): m.catalogs[icon_binding.catalog][icon_binding.id].id = "wrong")
	reject("unknown content namespace", func(m: Dictionary): m.catalogs.items["unknown_pack:item"] = {"id": "unknown_pack:item"})
	reject("duplicate pack identity", func(m: Dictionary): m.manifest.packs.append(m.manifest.packs[0].duplicate(true)))
	reject("unsafe asset path", func(m: Dictionary): m.manifest.assets[asset_id].path = "../outside.png")
	reject("backslash asset path", func(m: Dictionary): m.manifest.assets[asset_id].path = str(m.manifest.assets[asset_id].path).replace("/", "\\"))
	reject("noncanonical asset basename", func(m: Dictionary): m.manifest.assets[asset_id].path = "assets/" + "0".repeat(64) + ".png")
	reject("asset wrong length", func(m: Dictionary): m.manifest.assets[asset_id].bytes += 1)
	reject("asset altered bytes", func(m: Dictionary): m.files[asset.path] = PackedByteArray([1, 2, 3]))
	reject("missing asset", func(m: Dictionary): m["omit"] = asset.path)
	reject("declared PNG size mismatch", func(m: Dictionary): m.manifest.assets[asset_id].width = int(asset.width) + 1)
	reject("role-format mismatch", func(m: Dictionary): m.manifest.assets[asset_id].kind = "model")
	reject("missing binding target", func(m: Dictionary): m.manifest.bindings[0].id = str(icon_binding.id).get_slice(":", 0) + ":does_not_exist")
	reject("missing binding asset", func(m: Dictionary): m.manifest.bindings[0].assets = {"icon": str(asset_id).get_slice(":", 0) + ":absent"})
	reject("duplicate binding", func(m: Dictionary): m.manifest.bindings.append(m.manifest.bindings[0].duplicate(true)))
	reject("PNG invalid signature with correct hashes", func(m: Dictionary): replace_asset(m, asset_id, PackedByteArray([0, 1, 2, 3])))
	reject("PNG excessive decode dimensions", func(m: Dictionary):
		var raw: PackedByteArray = m.files[asset.path].duplicate()
		raw[16] = 0; raw[17] = 0; raw[18] = 32; raw[19] = 0
		m.manifest.assets[asset_id].erase("width")
		replace_asset(m, asset_id, raw))
	reject("truncated PNG with correct hashes", func(m: Dictionary): replace_asset(m, asset_id, m.files[asset.path].slice(0, 33)))
	reject("PNG trailing bytes with correct hashes", func(m: Dictionary):
		var raw: PackedByteArray = m.files[asset.path].duplicate()
		raw.append(0)
		replace_asset(m, asset_id, raw))
	reject("cumulative decoded-image memory", func(m: Dictionary):
		var large := Image.create(2048, 2048, false, Image.FORMAT_RGBA8)
		large.fill(Color(0.2, 0.3, 0.4, 1))
		var raw := large.save_png_to_buffer()
		m.manifest.assets[asset_id].width = 2048
		m.manifest.assets[asset_id].height = 2048
		m.manifest.assets[asset_id].kind = "texture"
		for binding: Dictionary in m.manifest.bindings:
			if binding.assets.get("icon", "") == asset_id:
				binding.assets.erase("icon")
				binding.assets.texture = asset_id
		replace_asset(m, asset_id, raw)
		for index in range(2):
			m.manifest.assets[str(asset_id).get_slice(":", 0) + ":extra_%d" % index] = m.manifest.assets[asset_id].duplicate(true))

	var selected := write_case(source)
	var configured: Dictionary = Database.configure_content_bundle(selected)
	verify(configured.ok and configured.identity == loaded.identity, "explicit pre-instantiation configuration succeeds")
	var bad_path := write_case(source)
	write_bytes(bad_path.path_join("receipt.json"), "{}".to_utf8_buffer())
	verify(not Database.configure_content_bundle(bad_path).ok, "failed reconfiguration reports failure before first instance")
	var first := Database.new()
	var second := Database.new()
	verify(first.is_active() and first.identity() == configured.identity and second.identity() == configured.identity and first.errors.is_empty(), "failed configuration leaves the prior valid frozen selection intact")
	var before: Dictionary = second.get(icon_binding.catalog)[icon_binding.id].duplicate(true)
	first.get(icon_binding.catalog)[icon_binding.id].name = "instance edit"
	var third := Database.new()
	verify(second.get(icon_binding.catalog)[icon_binding.id] == before and third.get(icon_binding.catalog)[icon_binding.id] == before, "each Database receives independent deeply copied catalogs")
	verify(first.get_content_icon(icon_binding.catalog, icon_binding.id) == second.get_content_icon(icon_binding.catalog, icon_binding.id), "databases share cached read-only icon textures")
	verify(not Database.configure_content_bundle(selected).ok and first.identity() == configured.identity, "configuration cannot change after any Database is constructed")
	write_bytes(selected.path_join(asset.path), PackedByteArray([0]))
	write_bytes(selected.path_join("catalogs.json"), "{}".to_utf8_buffer())
	var fourth := Database.new()
	verify(fourth.identity() == configured.identity and fourth.get(icon_binding.catalog)[icon_binding.id] == before and fourth.get_content_icon(icon_binding.catalog, icon_binding.id) != null, "future databases and icons remain frozen after on-disk content changes")
	finish()

func cache_coverage(asset_id: String, binding: Dictionary) -> void:
	var model: Dictionary = source.duplicate(true)
	var picture := Image.create(1254, 1254, false, Image.FORMAT_RGBA8)
	picture.fill(Color(0.2, 0.5, 0.3, 1))
	picture.fill_rect(Rect2i(0, 0, 200, 200), Color.TRANSPARENT)
	var raw := picture.save_png_to_buffer()
	model.manifest.assets[asset_id].width = 1254
	model.manifest.assets[asset_id].height = 1254
	replace_asset(model, asset_id, raw)
	for index in range(23):
		model.manifest.assets[asset_id.get_slice(":", 0) + ":cached_%d" % index] = model.manifest.assets[asset_id].duplicate(true)
	var result: Dictionary = Bundle.load_directory(write_case(model))
	verify(result.ok, "24 large source icons load within the display plus transient decode budget")
	if result.ok:
		var icon: Texture2D = result.bundle.get_texture(binding.catalog, binding.id)
		verify(icon.get_size() == Vector2(512, 512) and icon.get_image().has_mipmaps(), "large icons use a mipmapped 512-square display texture")
		verify(icon.get_image().get_pixel(0, 0).a == 0 and icon.get_image().get_pixel(256, 256).a > .99, "display cache preserves transparent background and opaque subject")
		verify(result.bundle.asset_bytes(asset_id) == raw and int(result.bundle.metadata().assets[asset_id].width) == 1254, "source bytes and source size metadata remain exact after display resize")
	# A separate wide source must retain its aspect ratio, while portrait data
	# at the same resolution must retain its full display dimensions.
	model = source.duplicate(true)
	picture = Image.create(1254, 627, false, Image.FORMAT_RGBA8)
	picture.fill(Color(0.3, 0.4, 0.7, 1))
	raw = picture.save_png_to_buffer()
	model.manifest.assets[asset_id].width = 1254
	model.manifest.assets[asset_id].height = 627
	replace_asset(model, asset_id, raw)
	var portrait_id := asset_id.get_slice(":", 0) + ":portrait"
	model.manifest.assets[portrait_id] = model.manifest.assets[asset_id].duplicate(true)
	model.manifest.assets[portrait_id].kind = "portrait"
	for entry: Dictionary in model.manifest.bindings:
		if entry.catalog == binding.catalog and entry.id == binding.id: entry.assets.portrait = portrait_id
	result = Bundle.load_directory(write_case(model))
	verify(result.ok and result.bundle.get_texture(binding.catalog, binding.id).get_size() == Vector2(512, 256), "non-square icon display keeps its original aspect ratio")
	verify(result.ok and result.bundle.get_texture(binding.catalog, binding.id, "portrait").get_size() == Vector2(1254, 627), "portrait display remains at source resolution")
	model = source.duplicate(true)
	picture = Image.create(2048, 2048, false, Image.FORMAT_RGBA8)
	picture.fill(Color(0.2, 0.3, 0.4, 1))
	raw = picture.save_png_to_buffer()
	model.manifest.assets[asset_id].width = 2048
	model.manifest.assets[asset_id].height = 2048
	replace_asset(model, asset_id, raw)
	for index in range(21):
		model.manifest.assets[asset_id.get_slice(":", 0) + ":peak_%d" % index] = model.manifest.assets[asset_id].duplicate(true)
	result = Bundle.load_directory(write_case(model))
	verify(not result.ok and result.error.contains("128 MiB"), "cache budget still rejects a large batch whose transient decode exceeds the limit")
	# Measure real Godot mip data, including one-pixel and odd-sized images,
	# rather than assuming every mip chain is only 4/3 of its base pixels.
	var mip_budget_matches := true
	for size: Vector2i in [Vector2i(1, 4096), Vector2i(4096, 1), Vector2i(3, 5), Vector2i(512, 512)]:
		picture = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
		picture.generate_mipmaps()
		mip_budget_matches = mip_budget_matches and Bundle.cache_memory_bytes(size.x, size.y) == maxi(size.x * size.y * 12, picture.get_data().size() * 2)
	verify(mip_budget_matches, "cache budget covers native complete RGBA8 mip chains in both CPU and texture")
	model = source.duplicate(true)
	for size: Vector2i in [Vector2i(1, 4096), Vector2i(1024, 1024)]:
		picture = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
		picture.fill(Color(0.2, 0.5, 0.3, 1))
		raw = picture.save_png_to_buffer()
		var hash_value := Bundle.digest(raw)
		var path := "assets/" + hash_value + ".png"
		model.files[path] = raw
		for index in range(1600 if size.x == 1 else 4):
			var id := asset_id.get_slice(":", 0) + ":mip_%d_%d" % [size.x, index]
			model.manifest.assets[id] = {"kind": "portrait", "path": path, "sha256": hash_value, "bytes": raw.size(), "width": size.x, "height": size.y}
	result = Bundle.load_directory(write_case(model))
	verify(not result.ok and result.error.contains("128 MiB"), "mixed narrow and square PNG batch rejects its complete mip cache above 128 MiB")

func fixture() -> Dictionary:
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--bundle="): continue
		var root := argument.trim_prefix("--bundle=")
		var direct: Dictionary = Bundle.load_directory(root)
		verify(direct.ok, "unmodified build.py output passes runtime preflight: " + direct.error)
		if not direct.ok: return {}
		var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(root.path_join("bundle.json")))
		var catalogs: Variant = JSON.parse_string(FileAccess.get_file_as_string(root.path_join("catalogs.json")))
		if not manifest is Dictionary or not catalogs is Dictionary: return {}
		var files: Dictionary = {}
		for entry: Dictionary in manifest.assets.values(): files[entry.path] = FileAccess.get_file_as_bytes(root.path_join(entry.path))
		return {"manifest": manifest, "catalogs": catalogs, "files": files}
	var catalogs: Dictionary = {}
	var base: Dictionary = {}
	for name: String in Bundle.CATALOGS:
		var raw := FileAccess.get_file_as_bytes("res://data/combat/" + name + ".json")
		catalogs[name] = JSON.parse_string(raw.get_string_from_utf8())
		base[name] = Bundle.digest(raw)
	var item: Dictionary = catalogs.items.values()[0].duplicate(true)
	item.id = "runtime_test:tonic"
	catalogs.items[item.id] = item
	var image := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.CORNFLOWER_BLUE)
	var raw := image.save_png_to_buffer()
	var hash_value := Bundle.digest(raw)
	var path := "assets/" + hash_value + ".png"
	return {"catalogs": catalogs, "files": {path: raw}, "manifest": {
		"format_version": 1, "contract": Bundle.CONTRACT, "catalogs_file": "catalogs.json", "catalogs_sha256": "",
		"base_sha256": base, "packs": [{"pack_id": "runtime_test", "version": "1.0.0", "sha256": "a".repeat(64)}],
		"assets": {"runtime_test:icon": {"kind": "icon", "path": path, "sha256": hash_value, "bytes": raw.size(), "width": 8, "height": 4}},
		"bindings": [{"catalog": "items", "id": item.id, "assets": {"icon": "runtime_test:icon"}}]}}

func reject(label: String, edit: Callable) -> void:
	var model: Dictionary = source.duplicate(true)
	edit.call(model)
	var result: Dictionary = Bundle.load_directory(write_case(model))
	verify(not result.ok and not result.error.is_empty() and not result.has("bundle") and result.identity.is_empty(), "whole bundle rejects " + label)

func replace_asset(model: Dictionary, id: String, raw: PackedByteArray) -> void:
	var asset: Dictionary = model.manifest.assets[id]
	asset.sha256 = Bundle.digest(raw)
	asset.bytes = raw.size()
	asset.path = "assets/" + asset.sha256 + ".png"
	model.files[asset.path] = raw

func write_case(model: Dictionary) -> String:
	case_number += 1
	var root := temp_root.path_join("case_%03d" % case_number)
	DirAccess.make_dir_absolute(root)
	DirAccess.make_dir_absolute(root.path_join("assets"))
	var manifest: Dictionary = model.manifest.duplicate(true)
	var catalogs_raw := (JSON.stringify(model.catalogs) + "\n").to_utf8_buffer()
	manifest.catalogs_sha256 = Bundle.digest(catalogs_raw)
	var manifest_raw := (JSON.stringify(manifest) + "\n").to_utf8_buffer()
	var receipt: Dictionary = model.get("receipt_override", {"format_version": 1, "bundle_sha256": Bundle.digest(manifest_raw)}).duplicate(true)
	if model.get("receipt_extra", false): receipt.extra = true
	if model.get("manifest_drift", false): manifest_raw.append(32)
	if model.get("catalog_drift", false): catalogs_raw.append(32)
	var files: Dictionary = model.files.duplicate(true)
	files["receipt.json"] = (JSON.stringify(receipt) + "\n").to_utf8_buffer()
	files["bundle.json"] = manifest_raw
	files["catalogs.json"] = catalogs_raw
	for path: String in files:
		if path == model.get("omit", ""): continue
		write_bytes(root.path_join(path), files[path])
	return root

func write_bytes(path: String, raw: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		verify(false, "write OS-temp fixture: " + path)
		return
	file.store_buffer(raw)
	file.close()

func finish() -> void:
	print("content_bundle: %d/%d checks passed" % [checks - failures.size(), checks])
	if not temp_root.is_empty(): print("Fixtures: ", temp_root)
	quit(0 if failures.is_empty() else 1)
