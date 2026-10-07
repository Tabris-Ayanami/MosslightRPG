extends SceneTree
## Isolated tests for read-only legacy release catalog loading. Any fixture files
## are created only under a unique OS temporary directory.
const Source = preload("res://rpg/save_source_context.gd")
const Bundle = preload("res://rpg/content_bundle.gd")
const Release = preload("res://rpg/content_release.gd")
const Database = preload("res://combat/combat_database.gd")

var checks := 0
var failures: Array[String] = []
var args := PackedStringArray()
var temporary_root := ""
var release_root := ""
var acquisition_release_root := ""

func _initialize() -> void:
	args = OS.get_cmdline_user_args()
	call_deferred("run")

func run() -> void:
	temporary_root = OS.get_temp_dir().path_join("mosslight-save-source-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	release_root = ProjectSettings.globalize_path("res://.work/release-candidate-20260930-03")
	acquisition_release_root = ProjectSettings.globalize_path("res://.work/release-candidate-20260930-06")
	for argument in args:
		if argument.begins_with("--release-root="):
			release_root = argument.trim_prefix("--release-root=")
		elif argument.begins_with("--acquisition-release-root="):
			acquisition_release_root = argument.trim_prefix("--acquisition-release-root=")
	DirAccess.make_dir_recursive_absolute(temporary_root)
	factory_case()
	historical_registry_case()
	builtin_fixture_case()
	if DirAccess.dir_exists_absolute(release_root):
		external_release_case()
	else:
		check(false, "legacy release fixture exists")
	if DirAccess.dir_exists_absolute(acquisition_release_root):
		historical_acquisition_case()
	else:
		check(false, "legacy acquisition release fixture exists")
	check(not Database.content_started(), "legacy inspection never constructs or locks CombatDatabase")
	check(not Release.is_active(), "legacy inspection never activates ContentRelease")
	print("SAVE_SOURCE_CONTEXT %d/%d" % [checks - failures.size(), checks])
	if not failures.is_empty():
		for failure: String in failures:
			push_error(failure)
	quit(1 if not failures.is_empty() else 0)

func factory_case() -> void:
	var source_catalogs := {"careers": {"warrior": {"id": "warrior", "nested": {"value": 1}}}}
	var source_worlds := {"shops": {"village": {"goods": []}}, "quests": {}}
	var source_identity := {"bundle_sha256": "a".repeat(64)}
	var context: RefCounted = Source.from_catalogs(source_catalogs, source_worlds, source_identity)
	check(context.identity() == source_identity, "factory retains a detached identity copy")
	check(not context.is_active(), "legacy context is never active")
	check(context.careers.has("warrior"), "factory exposes combat catalog attributes")
	source_catalogs.careers.warrior.nested.value = 2
	source_worlds.shops.village.goods.append("changed")
	source_identity.clear()
	check(int(context.careers.warrior.nested.value) == 1 and context.world_catalog("shops").village.goods.is_empty(), "factory copies inputs deeply")
	var snapshot: Dictionary = context.catalog_snapshot()
	snapshot.careers.warrior.nested.value = 3
	check(int(context.catalog_snapshot().careers.warrior.nested.value) == 1, "catalog_snapshot returns a deep copy")
	context.careers.warrior.nested.value = 4
	check(int(context.catalog_snapshot().careers.warrior.nested.value) == 4, "catalog_snapshot reflects the context's current catalog property")
	var identity_copy: Dictionary = context.identity()
	identity_copy.clear()
	check(not context.identity().is_empty(), "identity returns a deep copy")
	var rule_path := "rpg/race_catalog.gd"
	var current_rule_hash := Bundle.digest(FileAccess.get_file_as_bytes("res://" + rule_path))
	check(Source._source_rule_matches(rule_path, current_rule_hash, false), "editor rule fingerprint uses current source bytes")
	check(not Source._source_rule_matches(rule_path, current_rule_hash, true), "formal rule fingerprint fails closed without an activated frozen release")

func historical_registry_case() -> void:
	var bytes := FileAccess.get_file_as_bytes(Bundle.LEGACY_SHOPS_V1_PATH)
	check(Bundle.digest(bytes) == Bundle.LEGACY_SHOPS_V1_SHA, "registered shops v1 preserves exact shipped bytes")
	var old := Bundle.source_world_data("shops", Bundle.LEGACY_SHOPS_V1_SHA)
	check(old.ok, "registered historical shops hash resolves")
	if old.ok:
		var shop: Dictionary = old.data.village_supply
		check(shop.catalog_version == 1 and _same_json(shop.goods.spell_potion, {"buy_price": 30, "sell_price": 8, "stock": 8}), "historical shops retain v1 prices and stock")
		old.data.village_supply.goods.spell_potion.buy_price = 999
		check(Bundle.source_world_data("shops", Bundle.LEGACY_SHOPS_V1_SHA).data.village_supply.goods.spell_potion.buy_price == 30, "mutating returned historical data cannot alter the registered baseline")
	var current_sha := Bundle.digest(FileAccess.get_file_as_bytes("res://data/world/shops.json"))
	var current := Bundle.source_world_data("shops", current_sha)
	check(current.ok and current_sha != Bundle.LEGACY_SHOPS_V1_SHA and current.data.village_supply.catalog_version == 2, "current v2 shops remain a separate exact baseline")
	check(not Bundle.source_world_data("shops", "0".repeat(64)).ok, "unknown historical shops hash is rejected")
	check(not Bundle.source_world_data("quests", Bundle.LEGACY_SHOPS_V1_SHA).ok, "registered shops hash cannot replace quests")
	check(not Bundle.source_world_data("objects", Bundle.LEGACY_SHOPS_V1_SHA).ok, "historical exception is restricted to supported world catalog names")
	check(not Bundle.load_detached_directory(release_root.path_join("content"), {}).ok, "detached loader rejects missing verified source world hashes")
	check(not Bundle.load_detached_directory(release_root.path_join("content"), {"shops": Bundle.LEGACY_SHOPS_V1_SHA, "quests": 1}).ok, "detached loader rejects a non-hash replacement value")

func builtin_fixture_case() -> void:
	var directory := temporary_root.path_join("builtin-release")
	_create_builtin_release(directory)
	var opened := Source.open_release(directory)
	check(opened.ok, "builtin detached release opens from matching source snapshot: " + str(opened.get("error", "")))
	if opened.ok:
		var context: RefCounted = opened.context
		check(context.identity().is_empty() and not context.is_active(), "builtin source context keeps empty identity and inactive state")
		check(context.careers.size() > 0 and context.world_catalog("shops").size() > 0, "builtin source uses parsed current catalogs")
		check(opened.fingerprints.has("release.json") and opened.fingerprints.has("source-manifest.json") and opened.fingerprints.has("MosslightRPG.pck"), "fingerprints include release metadata, source manifest and PCK")
	var pck_path := directory.path_join("MosslightRPG.pck")
	_write_bytes(pck_path, "tampered inert PCK".to_utf8_buffer())
	var tampered := Source.open_release(directory)
	check(not tampered.ok and str(tampered.error).contains("游戏文件"), "changed PCK is rejected before returning context")
	var bad_sha := temporary_root.path_join("bad-source-sha")
	_create_builtin_release(bad_sha)
	_write_bytes(bad_sha.path_join("source-manifest.json"), "{}\n".to_utf8_buffer())
	check(not Source.open_release(bad_sha).ok, "source-manifest byte changes fail its signed release hash")
	var missing_base := temporary_root.path_join("missing-required-base")
	_create_builtin_release(missing_base, "missing")
	var missing_result := Source.open_release(missing_base)
	check(not missing_result.ok and str(missing_result.error).contains("基础规则不同，暂不能自动迁移"), "re-signed source manifest cannot omit a required base rule")
	var changed_base := temporary_root.path_join("changed-required-base")
	_create_builtin_release(changed_base, "changed")
	var changed_result := Source.open_release(changed_base)
	check(not changed_result.ok and str(changed_result.error).contains("基础规则不同，暂不能自动迁移"), "re-signed source manifest cannot change a required base fingerprint")
	var invalid_utf8 := temporary_root.path_join("invalid-utf8")
	_create_builtin_release(invalid_utf8, "invalid_utf8")
	var utf8_result := Source.open_release(invalid_utf8)
	check(not utf8_result.ok and str(utf8_result.error).contains("UTF-8"), "invalid UTF-8 JSON is rejected even when its bytes are re-signed")
	var old_builtin := temporary_root.path_join("historical-builtin")
	_create_builtin_release(old_builtin, "legacy_shops")
	var historic := Source.open_release(old_builtin)
	check(historic.ok and historic.context.identity().is_empty(), "builtin v1 release opens independently of current v2 shops")
	if historic.ok:
		check(historic.context.world_catalog("shops").village_supply.catalog_version == 1 and historic.context.world_catalog("shops").village_supply.goods.spell_potion.buy_price == 30, "builtin old save validator receives old shop version and price")
	var unknown_shop := temporary_root.path_join("unknown-historical-shops")
	_create_builtin_release(unknown_shop, "unknown_shops")
	var unknown := Source.open_release(unknown_shop)
	check(not unknown.ok and str(unknown.error).contains("基础规则不同"), "re-signed source manifest cannot declare an unregistered old shop baseline")

func _create_builtin_release(directory: String, source_mode := "valid") -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	var source_manifest := _current_source_manifest()
	if source_mode == "missing": source_manifest.erase("data/combat/careers.json")
	if source_mode == "changed": source_manifest["data/combat/careers.json"] = "f".repeat(64)
	if source_mode == "legacy_shops": source_manifest["data/world/shops.json"] = Bundle.LEGACY_SHOPS_V1_SHA
	if source_mode == "unknown_shops": source_manifest["data/world/shops.json"] = "0".repeat(64)
	var source_bytes: PackedByteArray
	if source_mode == "invalid_utf8": source_bytes = PackedByteArray([123, 34, 255, 34, 58, 49, 125])
	else: source_bytes = (JSON.stringify(source_manifest, "\t") + "\n").to_utf8_buffer()
	_write_bytes(directory.path_join("source-manifest.json"), source_bytes)
	_write_bytes(directory.path_join("MosslightRPG.pck"), "isolated inert PCK fixture".to_utf8_buffer())
	_write_release_json(directory, source_bytes, {})

func _current_source_manifest() -> Dictionary:
	var source_manifest: Dictionary = {}
	var required: Array[String] = []
	for name: String in Bundle.CATALOGS:
		required.append("data/combat/" + name + ".json")
	for name in ["shops", "quests", "objects", "npcs", "encounters", "chapters"]:
		required.append("data/world/" + name + ".json")
	required.append_array(["rpg/race_catalog.gd", "combat/resource_recovery.gd"])
	for path: String in required:
		source_manifest[path] = Bundle.digest(FileAccess.get_file_as_bytes("res://" + path))
	return source_manifest

func _write_release_json(directory: String, source_bytes: PackedByteArray, content_identity: Dictionary) -> void:
	var engine := Engine.get_version_info()
	var engine_version := "%d.%d.%d.%s.%s.%s" % [engine.major, engine.minor, engine.patch, engine.status, engine.build, engine.hash]
	_write_json(directory.path_join("release.json"), {"format_version": 1, "release_id": "test_release", "version": "1.0.0", "engine_version": engine_version, "source_manifest_sha256": Bundle.digest(source_bytes), "pck": {"path": "MosslightRPG.pck", "sha256": FileAccess.get_sha256(directory.path_join("MosslightRPG.pck"))}, "content": {} if content_identity.is_empty() else {"path": "content", "identity": content_identity}})

func external_release_case() -> void:
	var opened := Source.open_release(release_root)
	check(opened.ok, "real fixed release opens read-only: " + str(opened.get("error", "")))
	if not opened.ok:
		return
	var context: RefCounted = opened.context
	var expected: Dictionary = opened.release.content.identity
	check(context.world_catalog("shops").village_supply.catalog_version == 1 and context.world_catalog("shops").village_supply.goods.spell_potion.buy_price == 30, "release 03 without acquisition uses its verified old world baseline")
	check(_same_json(context.identity(), expected), "external source context preserves the exact bundle identity")
	check(opened.source_label.contains(str(opened.release.release_id)) and opened.source_label.contains("willow_watch"), "source label names release and content pack")
	check(opened.fingerprints.has("content/receipt.json") and opened.fingerprints.has("content/bundle.json") and opened.fingerprints.has("content/catalogs.json"), "bundle fingerprints include its receipt and catalogs")
	var bundle_read := FileAccess.get_file_as_string(release_root.path_join("content/bundle.json"))
	var manifest: Dictionary = JSON.parse_string(bundle_read)
	check(opened.fingerprints.size() == 3 + manifest.assets.size() + 3, "fingerprints cover every bundle asset and release file")
	var all_catalogs: Dictionary = context.catalog_snapshot()
	check(all_catalogs.size() == Bundle.CATALOGS.size() and context.world_catalog("shops").size() > 0, "external context exposes all combat catalogs and world catalogs")
	var cloned := temporary_root.path_join("cloned-content-release")
	DirAccess.make_dir_recursive_absolute(cloned.path_join("content"))
	_copy_tree(release_root.path_join("content"), cloned.path_join("content"))
	var source_bytes := (JSON.stringify(_current_source_manifest(), "\t") + "\n").to_utf8_buffer()
	_write_bytes(cloned.path_join("source-manifest.json"), source_bytes)
	_write_bytes(cloned.path_join("MosslightRPG.pck"), "inert external content PCK".to_utf8_buffer())
	_write_release_json(cloned, source_bytes, expected)
	var receipt_path := cloned.path_join("content/receipt.json")
	var receipt_bytes := FileAccess.get_file_as_bytes(receipt_path)
	_write_bytes(receipt_path, "{}\n".to_utf8_buffer())
	var bad_receipt := Source.open_release(cloned)
	check(not bad_receipt.ok and str(bad_receipt.error).contains("内容包无法验证"), "malformed external bundle receipt is rejected")
	_write_bytes(receipt_path, receipt_bytes)
	var release_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(cloned.path_join("release.json")))
	release_json.content.identity.bundle_sha256 = "0".repeat(64)
	_write_json(cloned.path_join("release.json"), release_json)
	var wrong_identity := Source.open_release(cloned)
	check(not wrong_identity.ok and str(wrong_identity.error).contains("身份与发行清单不一致"), "verified external bundle with a re-signed wrong identity is rejected")

func historical_acquisition_case() -> void:
	var before_manifest := FileAccess.get_sha256(acquisition_release_root.path_join("source-manifest.json"))
	var before_bundle := FileAccess.get_sha256(acquisition_release_root.path_join("content/bundle.json"))
	var opened := Source.open_release(acquisition_release_root)
	check(opened.ok, "release 06 with acquisition opens against its verified old baseline: " + str(opened.get("error", "")))
	if not opened.ok: return
	var shop: Dictionary = opened.context.world_catalog("shops").village_supply
	check(shop.catalog_version == 1 and _same_json(shop.goods.spell_potion, {"buy_price": 30, "sell_price": 8, "stock": 8}), "release 06 retains v1 prices instead of borrowing current prices")
	check(shop.goods.has("willow_watch:herb_brew") and int(shop.goods["willow_watch:herb_brew"].stock) == 6, "release 06 applies its own acquisition goods to the old base")
	check(_same_json(opened.context.identity(), opened.release.content.identity), "detached historical acquisition keeps original content identity")
	var hashes: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(acquisition_release_root.path_join("source-manifest.json")))
	var worlds := {"shops": hashes["data/world/shops.json"], "quests": hashes["data/world/quests.json"]}
	var ordinary := Bundle.load_directory(acquisition_release_root.path_join("content"))
	check(not ordinary.ok and str(ordinary.error).contains("获取途径的基础目录已改变"), "ordinary loader still rejects an old acquisition bundle against current shops")
	var activation := Database.configure_content_bundle(acquisition_release_root.path_join("content"))
	check(not activation.ok and not Database.content_started(), "normal Database activation cannot use detached historical support")
	var detached := Bundle.load_detached_directory(acquisition_release_root.path_join("content"), worlds)
	check(detached.ok and detached.bundle.world_catalogs().shops.village_supply.catalog_version == 1, "explicit detached loader accepts the same verified historical bundle")
	var unknown := worlds.duplicate()
	unknown.shops = "0".repeat(64)
	check(not Bundle.load_detached_directory(acquisition_release_root.path_join("content"), unknown).ok, "detached loader rejects arbitrary source-world replacement hashes")
	var wrong_world := worlds.duplicate()
	wrong_world.shops = Bundle.digest(FileAccess.get_file_as_bytes("res://data/world/shops.json"))
	check(not Bundle.load_detached_directory(acquisition_release_root.path_join("content"), wrong_world).ok, "supported current shops cannot override an old acquisition fingerprint")
	var extra := worlds.duplicate()
	extra.objects = worlds.shops
	check(not Bundle.load_detached_directory(acquisition_release_root.path_join("content"), extra).ok, "detached loader rejects undeclared world override keys")
	var tampered := temporary_root.path_join("tampered-historical-bundle")
	DirAccess.make_dir_recursive_absolute(tampered)
	_copy_tree(acquisition_release_root.path_join("content"), tampered)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(tampered.path_join("bundle.json")))
	manifest.acquisition.world_base_sha256.shops = wrong_world.shops
	_write_json(tampered.path_join("bundle.json"), manifest)
	_write_json(tampered.path_join("receipt.json"), {"format_version": 1, "bundle_sha256": FileAccess.get_sha256(tampered.path_join("bundle.json"))})
	var replaced := Bundle.load_detached_directory(tampered, worlds)
	check(not replaced.ok and str(replaced.error).contains("获取途径的基础目录已改变"), "re-signed acquisition fingerprint cannot replace the verified source world's bytes")
	check(FileAccess.get_sha256(acquisition_release_root.path_join("source-manifest.json")) == before_manifest and FileAccess.get_sha256(acquisition_release_root.path_join("content/bundle.json")) == before_bundle, "historical source release remains unchanged after all checks")

func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "Cannot write isolated test fixture")
	file.store_buffer(bytes)
	file.close()

func _write_json(path: String, value: Variant) -> void:
	_write_bytes(path, (JSON.stringify(value, "\t") + "\n").to_utf8_buffer())

func _copy_tree(source: String, destination: String) -> void:
	DirAccess.make_dir_recursive_absolute(destination)
	for filename: String in DirAccess.get_files_at(source):
		_write_bytes(destination.path_join(filename), FileAccess.get_file_as_bytes(source.path_join(filename)))
	for directory_name: String in DirAccess.get_directories_at(source):
		_copy_tree(source.path_join(directory_name), destination.path_join(directory_name))

func check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)

func _same_json(left: Variant, right: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))
