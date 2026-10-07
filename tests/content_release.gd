extends SceneTree
## Each lifecycle case runs in a fresh process. Never reset Database/Release
## static fields: startup ordering and frozen identities are the behavior tested.
## --mode=valid --release-root=ABS --storage-root=OS_TEMP also works with a real
## --main-pack. --mode=valid_auto omits --release-root and exercises the actual
## adjacent-pack discovery. The default suite's tiny PCK bytes are hash fixtures.
const Release = preload("res://rpg/content_release.gd")
const Bundle = preload("res://rpg/content_bundle.gd")
const Database = preload("res://combat/combat_database.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
var mode := "suite"
var release_root := ""
var storage_root := ""
var evidence := ""
var checks := 0
var failures: Array[String] = []
var child_reports: Array[Dictionary] = []
var app_count := 0
var bootstrap: Node
var report_written := false
var details: Dictionary = {}

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--mode="): mode = argument.trim_prefix("--mode=")
		elif argument.begins_with("--release-root="): release_root = argument.trim_prefix("--release-root=")
		elif argument.begins_with("--storage-root="): storage_root = argument.trim_prefix("--storage-root=")
	if mode != "suite":
		var normalized := storage_root.replace("\\", "/").simplify_path()
		if not storage_root.is_absolute_path() or not normalized.begins_with(OS.get_temp_dir().replace("\\", "/").simplify_path() + "/"):
			printerr("content_release needs a dedicated absolute OS-temp storage root")
			quit(2)
			return
		DirAccess.make_dir_recursive_absolute(storage_root)
		Preferences.settings_path = storage_root.path_join("before-start-preferences.cfg")
	node_added.connect(func(node: Node):
		var script: Script = node.get_script()
		if script != null and script.resource_path == "res://scripts/frontend/app.gd": app_count += 1)
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
	print("PASS " if value else "FAIL ", label)

func ticks(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame

func same(left: Variant, right: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))

func run() -> void:
	if mode == "suite":
		await suite()
		return
	create_timer(80, true).timeout.connect(func(): check(false, "child finishes within 80 seconds"); finish())
	check(not Database.content_started() and not Release.is_active(), "fresh subprocess starts before any Database instance or release")
	if mode == "late_database":
		var database := Database.new()
		check(database.identity().is_empty(), "ordinary first Database freezes builtin content")
		var selected := Release.activate(release_root, storage_root.path_join("releases"))
		check(not selected.ok and not Release.is_active(), "formal activation refuses a process that already created a Database")
		check(Database.new().identity().is_empty() and app_count == 0, "late refusal leaves builtin identity and does not create App")
		finish()
		return
	if mode == "preview":
		preview_case()
		finish()
		return
	if mode == "activate_only":
		activation_case()
		finish()
		return
	if mode == "valid_auto":
		check(OS.has_feature("formal_release") and release_root.is_empty(), "automatic smoke uses a formal PCK and no explicit release-root argument")
		if not OS.has_feature("formal_release") or not release_root.is_empty():
			finish()
			return
		release_root = Release.distribution_directory()
	bootstrap = load("res://scenes/frontend/bootstrap.tscn").instantiate()
	if mode != "valid_auto": bootstrap.release_directory = release_root
	bootstrap.storage_root = storage_root.path_join("releases")
	# Headless production _fail quits immediately; its actual tree exit is the
	# observation point. Do not override _fail or keep a refused app alive.
	bootstrap.tree_exiting.connect(on_bootstrap_exit)
	root.add_child(bootstrap)
	await ticks(5)
	if mode == "reject":
		check(false, "invalid release must stop headless startup")
		finish()
		return
	await valid_case()
	finish()

func on_bootstrap_exit() -> void:
	if report_written: return
	if mode == "reject":
		check(not bootstrap.startup_error.is_empty(), "invalid distribution exposes a startup error")
		check(app_count == 0 and not is_instance_valid(bootstrap.app), "invalid distribution is refused before App construction")
		check(not Database.content_started() and not Release.is_active(), "invalid distribution never publishes or constructs its Database")
		check(not DirAccess.dir_exists_absolute(storage_root.path_join("releases")), "failed preflight creates no release preferences or adventure directory")
		check(Preferences.settings_path == storage_root.path_join("before-start-preferences.cfg"), "failed startup does not change preference context")
		details.startup_error = bootstrap.startup_error
	else:
		check(false, "valid bootstrap exited before completing its smoke checks: " + str(bootstrap.startup_error))
	write_report()

func expected_identity() -> Dictionary:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(release_root.path_join("release.json")))
	return manifest.get("content", {}).get("identity", {})

func activation_case() -> void:
	var context := storage_root.path_join("must-not-be-created")
	var selected := Release.activate(release_root, context)
	check(selected.ok, "release activates explicitly before first Database")
	if not selected.ok: return
	check(not DirAccess.dir_exists_absolute(context), "Release.activate itself performs no save or preferences writes")
	check(Database.content_started() and same(selected.identity, expected_identity()), "activation locks the expected identity before any instance")
	var frozen := Release.metadata()
	var identity := Release.identity()
	frozen.release_id = "tampered"
	identity.clear()
	check(Release.metadata().release_id != "tampered" and same(Release.identity(), expected_identity()), "release queries return detached metadata and identity")
	check(not Release.activate(release_root, context).ok, "duplicate activation is rejected before an instance too")
	check(not Database.configure_content_bundle(release_root.path_join("content")).ok, "release locks subsequent preview selection before an instance")
	var database := Database.new()
	check(database.errors.is_empty() and same(database.identity(), expected_identity()), "the actual first Database receives the activated identity")
	check(app_count == 0, "activation is independent of App construction")

func preview_case() -> void:
	var selected := Database.configure_content_bundle(release_root.path_join("content"))
	check(selected.ok and not Release.is_active(), "preview selection does not implicitly mark a formal release active")
	if not selected.ok: return
	var automatic := Repository.new()
	var expected := ProjectSettings.globalize_path("user://content-previews/" + str(selected.identity.bundle_sha256) + "/adventures").simplify_path()
	check(automatic.directory == expected, "default preview repository retains its existing per-hash preview namespace")
	var explicit_path := storage_root.path_join("preview/adventures")
	var explicit := Repository.new(explicit_path)
	check(explicit.directory == explicit_path and explicit.directory != automatic.directory, "explicit temporary preview repository remains injected")
	var created := explicit.create("预览隔离旅人", 0)
	check(created.ok and same(created.snapshot.content_set, selected.identity), "preview save writes only to its explicit isolated repository")
	check(not Release.activate(release_root, storage_root.path_join("releases")).ok and not Release.is_active(), "formal release cannot replace an already selected preview")
	check(not DirAccess.dir_exists_absolute(storage_root.path_join("releases")) and app_count == 0, "preview-to-formal refusal creates no formal directory or App")
	details.preview_directory = explicit.directory
	details.automatic_preview_directory = automatic.directory

func pristine(snapshot: Dictionary) -> bool:
	return int(snapshot.loadout.level) == 0 and snapshot.loadout.career_ids.is_empty() and snapshot.loadout.learned_skills.is_empty() and snapshot.inventory.stacks.is_empty() and not snapshot.progression.starter_granted and snapshot.progression.claimed_rewards.is_empty()

func no_generated_grants(actor: Node) -> bool:
	for id: String in actor.inventory.export_state().stacks:
		if ":" in id or id == "magic_candy": return false
	for id: String in actor.loadout.career_ids:
		if ":" in id: return false
	for id: String in actor.loadout.export_state().learned_skills:
		if ":" in id: return false
	return true

func valid_case() -> void:
	check(bootstrap.startup_error.is_empty() and is_instance_valid(bootstrap.app), "actual Bootstrap starts its real App after release preflight")
	if not is_instance_valid(bootstrap.app): return
	var app: Node = bootstrap.app
	app.set_process(false)
	var identity := expected_identity()
	check(str(ProjectSettings.get_setting("application/run/main_scene")) == "res://scenes/frontend/bootstrap.tscn", "project entrypoint is the release-aware Bootstrap")
	check(app_count == 1 and Release.is_active(), "startup constructs exactly one App and publishes formal context")
	check(bootstrap.mouse_filter == Control.MOUSE_FILTER_IGNORE, "full-screen Bootstrap does not intercept gameplay pointer input")
	if mode == "valid_auto":
		check(bootstrap.release_directory == release_root and FileAccess.file_exists(release_root.path_join("release.json")), "unconfigured Bootstrap discovers its real adjacent release manifest automatically")
	check(app.stage == app.Stage.TITLE and is_instance_valid(app.menu), "formal startup opens the actual title UI, including with --sample")
	check(same(Release.identity(), identity) and same(app.saves.database.identity(), identity) and app.saves.database.errors.is_empty(), "App's initializer-created first Repository Database already has the release identity")
	check(app.saves.directory == Release.save_directory() and app.saves.directory.begins_with(storage_root + "/"), "default App saves use the injected formal release namespace")
	check(Preferences.settings_path == Release.preferences_path() and Preferences.settings_path.begins_with(storage_root + "/"), "formal preference path is bound before App enters the tree")
	var preview_default := ProjectSettings.globalize_path("user://content-previews/" + str(identity.get("bundle_sha256", "builtin")) + "/adventures").simplify_path()
	check(app.saves.directory != preview_default and app.saves.directory != ProjectSettings.globalize_path("user://adventures").simplify_path(), "formal saves are separate from both preview and ordinary adventures")
	var isolated_preview := Repository.new(storage_root.path_join("explicit-preview/adventures"))
	check(isolated_preview.directory == storage_root.path_join("explicit-preview/adventures"), "formal context preserves explicitly injected test or preview repositories")
	var preview_save := isolated_preview.create("隔离预览哨兵", 0)
	check(preview_save.ok and not app.saves.slot(0).occupied, "an explicit preview slot never occupies the same-numbered formal slot")
	check(not app.saves.slot(0).occupied, "formal startup does not create a sample adventure")
	var frozen_path: String = Release.save_directory()
	check(not Release.activate(release_root, storage_root.path_join("other")).ok and Release.save_directory() == frozen_path, "second activation cannot redirect the live release or storage")
	check(not Database.configure_content_bundle(release_root.path_join("content")).ok and same(Database.new().identity(), identity), "late preview configuration cannot replace formal Database identity")
	check(Preferences.set_damage_numbers(false) == OK and FileAccess.file_exists(Release.preferences_path()), "preferences save only to the formal temporary location")
	var created: Dictionary = app.saves.create("正式发行验证旅人", 0)
	check(created.ok, "formal named adventure can be created")
	if not created.ok: return
	check(pristine(created.snapshot), "formal new adventure remains Lv0 with no careers, learned skills, items or claimed sample rewards")
	var preview_again := isolated_preview.load_slot(0)
	check(preview_again.ok and preview_again.snapshot.name == "隔离预览哨兵" and pristine(preview_again.snapshot), "formal adventure creation leaves the independent preview slot untouched")
	check(same(created.snapshot.content_set, identity), "formal new adventure records the release content identity")
	app.selected_save = 0
	app.selected_name = created.snapshot.name
	app.pending_snapshot = created.snapshot.duplicate(true)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.close_panel(true)
	await ticks(5)
	check(is_instance_valid(app.game), "actual main map can restore the formal new adventure")
	if not is_instance_valid(app.game): return
	var game: Node = app.game
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy: Node in game.combat_world.enemies: enemy.set_physics_process(false)
	check(same(game.rpg.loadout.database.identity(), identity), "actual gameplay actor receives the same frozen release identity")
	check(game.rpg.loadout.level == 0 and no_generated_grants(game.rpg) and game.rpg.inventory.export_state().stacks.is_empty(), "--sample grants nothing when the real main map is entered")
	check(game.rpg.progression.choose_career("warrior") and no_generated_grants(game.rpg), "normal starter choice grants only normal starter content")
	check(app.save_adventure(), "formal live character saves successfully")
	var restored: Dictionary = app.saves.load_slot(0)
	check(restored.ok and same(restored.snapshot.content_set, identity) and int(restored.snapshot.loadout.level) == 1, "formal disk roundtrip retains identity and normal progression")
	details.identity = identity
	details.formal_directory = app.saves.directory
	details.preferences_path = Preferences.settings_path
	details.sample_argument = "--sample" in OS.get_cmdline_user_args()
	details.real_main_pack = OS.has_feature("formal_release")
	bootstrap.tree_exiting.disconnect(on_bootstrap_exit)
	bootstrap.queue_free()
	await ticks(3)

func write_bytes(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "Cannot write isolated release fixture: " + path)
	file.store_buffer(bytes)
	file.close()

func write_json(path: String, value: Variant) -> void:
	write_bytes(path, (JSON.stringify(value, "\t") + "\n").to_utf8_buffer())

func fixture(directory: String, builtin := false) -> void:
	# These inert bytes only test release fingerprint validation. Actual PCK
	# verification invokes --mode=valid externally against the built main-pack.
	write_bytes(directory.path_join("MosslightRPG.pck"), "inert release test PCK hash fixture\n".to_utf8_buffer())
	write_json(directory.path_join("source-manifest.json"), {"fixture": "not an exported PCK"})
	var identity: Dictionary = {}
	if not builtin:
		var catalogs: Dictionary = {}
		var base: Dictionary = {}
		for catalog: String in Bundle.CATALOGS:
			var raw := FileAccess.get_file_as_bytes("res://data/combat/" + catalog + ".json")
			catalogs[catalog] = JSON.parse_string(raw.get_string_from_utf8())
			base[catalog] = Bundle.digest(raw)
		var item: Dictionary = catalogs.items.healing_potion.duplicate(true)
		item.id = "release_test:tonic"
		catalogs.items[item.id] = item
		var picture := Image.create(8, 4, false, Image.FORMAT_RGBA8)
		picture.fill(Color.CORNFLOWER_BLUE)
		var image := picture.save_png_to_buffer()
		var hash_value := Bundle.digest(image)
		var asset_path := "assets/" + hash_value + ".png"
		var catalogs_raw := (JSON.stringify(catalogs) + "\n").to_utf8_buffer()
		var manifest := {"format_version": 1, "contract": Bundle.CONTRACT, "catalogs_file": "catalogs.json", "catalogs_sha256": Bundle.digest(catalogs_raw), "base_sha256": base, "packs": [{"pack_id": "release_test", "version": "1.0.0", "sha256": "a".repeat(64)}], "assets": {"release_test:icon": {"kind": "icon", "path": asset_path, "sha256": hash_value, "bytes": image.size(), "width": 8, "height": 4}}, "bindings": [{"catalog": "items", "id": item.id, "assets": {"icon": "release_test:icon"}}]}
		var manifest_raw := (JSON.stringify(manifest) + "\n").to_utf8_buffer()
		var content := directory.path_join("content")
		write_bytes(content.path_join(asset_path), image)
		write_bytes(content.path_join("catalogs.json"), catalogs_raw)
		write_bytes(content.path_join("bundle.json"), manifest_raw)
		write_json(content.path_join("receipt.json"), {"format_version": 1, "bundle_sha256": Bundle.digest(manifest_raw)})
		var loaded := Bundle.load_directory(content)
		assert(loaded.ok, str(loaded.error))
		identity = loaded.identity
	# The manifest uses the command-line version convention; Engine's .string
	# is human-facing ("4.7.2-stable (official)") and intentionally differs.
	var engine := Engine.get_version_info()
	var engine_version := "%d.%d.%d.%s.%s.%s" % [engine.major, engine.minor, engine.patch, engine.status, engine.build, engine.hash]
	write_json(directory.path_join("release.json"), {"format_version": 1, "release_id": "release_test", "version": "1.0.0", "engine_version": engine_version, "source_manifest_sha256": FileAccess.get_sha256(directory.path_join("source-manifest.json")), "pck": {"path": "MosslightRPG.pck", "sha256": FileAccess.get_sha256(directory.path_join("MosslightRPG.pck"))}, "content": {} if builtin else {"path": "content", "identity": identity}})

func suite() -> void:
	storage_root = OS.get_temp_dir().path_join("mosslight-content-release-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	evidence = ProjectSettings.globalize_path("res://.work/content-release-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(storage_root)
	DirAccess.make_dir_recursive_absolute(evidence)
	var cases := ["valid", "builtin", "activate_only", "late_database", "preview", "bad_pck", "bad_source", "bad_receipt", "bad_catalog", "wrong_identity", "unknown_field", "unsafe_content_path", "missing_manifest", "wrong_engine"]
	for name: String in cases:
		var distribution := storage_root.path_join(name + "/distribution")
		fixture(distribution, name == "builtin")
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(distribution.path_join("release.json")))
		match name:
			"bad_pck": write_bytes(distribution.path_join("MosslightRPG.pck"), "changed".to_utf8_buffer())
			"bad_source": write_json(distribution.path_join("source-manifest.json"), {})
			"bad_receipt": write_json(distribution.path_join("content/receipt.json"), {})
			"bad_catalog": write_json(distribution.path_join("content/catalogs.json"), {})
			"wrong_identity": manifest.content.identity.bundle_sha256 = "0".repeat(64)
			"unknown_field": manifest.sample = true
			"unsafe_content_path": manifest.content.path = "../outside"
			"wrong_engine": manifest.engine_version = "0.0.0.stable.fixture"
		write_json(distribution.path_join("release.json"), manifest)
		if name == "missing_manifest": DirAccess.remove_absolute(distribution.path_join("release.json"))
		var child_mode: String = name if name in ["valid", "activate_only", "late_database", "preview"] else ("valid" if name == "builtin" else "reject")
		var isolated := storage_root.path_join(name + "/storage")
		var output: Array = []
		var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--log-file", evidence.path_join(name + ".log"), "--script", "res://tests/content_release.gd", "--", "--mode=" + child_mode, "--release-root=" + distribution, "--storage-root=" + isolated, "--sample"])
		var code := OS.execute(OS.get_executable_path(), args, output, true)
		write_bytes(evidence.path_join(name + ".stdout.log"), "\n".join(output).to_utf8_buffer())
		var report_path := isolated.path_join("release-smoke-report.json")
		var report: Variant = JSON.parse_string(FileAccess.get_file_as_string(report_path)) if FileAccess.file_exists(report_path) else null
		check(code == (1 if child_mode == "reject" else 0), name + " exits with the expected real process status")
		check(report is Dictionary and report.get("ok", false), name + " subprocess report passes every lifecycle check")
		if report is Dictionary:
			child_reports.append({"case": name, "report": report, "returncode": code})
			write_json(evidence.path_join(name + ".json"), report)
			print("CASE ", name, " ", report.checks - report.failures.size(), "/", report.checks)
	check(not Database.content_started(), "parent never constructs or resets Database while running lifecycle subprocesses")
	details.evidence = evidence
	details.children = child_reports
	finish()

func write_report() -> void:
	if report_written: return
	report_written = true
	var report := {"ok": failures.is_empty(), "checks": checks, "failures": failures, "mode": mode, "pid": OS.get_process_id(), "app_count": app_count, "release_root": release_root, "storage_root": storage_root, "details": details}
	write_json(storage_root.path_join("release-smoke-report.json"), report)
	if not evidence.is_empty(): write_json(evidence.path_join("report.json"), report)
	print("CONTENT_RELEASE %d/%d mode=%s report=%s" % [checks - failures.size(), checks, mode, storage_root.path_join("release-smoke-report.json")])

func finish() -> void:
	write_report()
	quit(0 if failures.is_empty() else 1)
