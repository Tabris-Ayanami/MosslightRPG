extends SceneTree
## Copied outside the project by tools/export/build.py; deliberately absent from PCK.
const Preferences = preload("res://rpg/game_preferences.gd")
const Database = preload("res://combat/combat_database.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Bridge = preload("res://rpg/dialogue_bridge.gd")
var workspace := ""
var expected: Dictionary = {}
var app: Node
var checks := 0
var failures: Array[String] = []
var manifest: Array[String] = []
var bundle := ""

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--workspace="): workspace = argument.trim_prefix("--workspace=")
		elif argument.begins_with("--bundle="): bundle = argument.trim_prefix("--bundle=")
	if workspace.is_empty() or not workspace.is_absolute_path() or not workspace.simplify_path().begins_with(OS.get_temp_dir().simplify_path() + "/"):
		printerr("EXPORT_SMOKE requires its own absolute OS-temp workspace")
		quit(2)
		return
	Preferences.settings_path = workspace.path_join("preferences.cfg")
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func ticks(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame

func collect(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null: return
	directory.include_hidden = true
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if name not in [".", ".."]:
			var entry := path.path_join(name)
			if directory.current_is_dir(): collect(entry)
			else: manifest.append(entry)
		name = directory.get_next()
	directory.list_dir_end()

func make_app(snapshot: Dictionary = {}) -> Node:
	var instance: Node = load("res://scenes/frontend/app.tscn").instantiate()
	instance.saves = Repository.new(workspace.path_join("adventures"))
	root.add_child(instance)
	instance.set_process(false)
	await ticks(3)
	if not snapshot.is_empty():
		instance.selected_save = 0
		instance.selected_name = snapshot.name
		instance.pending_snapshot = snapshot.duplicate(true)
		instance._enter_world(load("res://scenes/main.tscn"))
		instance._finish_arrival()
		instance.ui.close_panel(true)
		await ticks(5)
		instance.game.sound.muted = true
		instance.game.combat_world.encounters_started = true
		for enemy in instance.game.combat_world.enemies: enemy.set_physics_process(false)
	return instance

func run() -> void:
	create_timer(120, true).timeout.connect(func(): printerr("EXPORT_SMOKE timed out"); quit(1))
	# A main-pack has a virtual res:// root: this editor returns an empty
	# globalized path, even with --path. The physical cwd must still be isolated.
	var resource_root := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	check(DirAccess.open(".").get_current_dir().simplify_path() == workspace.simplify_path() and resource_root in ["", workspace.simplify_path()], "PCK uses a virtual resource root in the isolated physical working directory")
	check(not FileAccess.file_exists(workspace.path_join("project.godot")), "runtime directory has no loose project.godot fallback")
	check(not FileAccess.file_exists(workspace.path_join("scripts/frontend/app.gd")) and not FileAccess.file_exists(workspace.path_join("data/combat/careers.json")), "runtime directory has no loose game code or catalog fallback")
	check(str(ProjectSettings.get_setting("application/run/main_scene")) == "res://scenes/frontend/bootstrap.tscn", "export retains the release-aware frontend entrypoint")
	collect("res://")
	manifest.sort()
	var exclusions_ok := true
	for path: String in manifest:
		for excluded in [".work/", "docs/", "tests/", "tools/", "source_assets/", "content_packs/", "build/", "test-results/"]:
			if path.begins_with("res://" + excluded): exclusions_ok = false
		if "/provenance/" in path: exclusions_ok = false
		if path.begins_with("res://assets/") and path.get_file() in ["source.json", "prompts.json", "manifest.json"]: exclusions_ok = false
	check(exclusions_ok and not manifest.is_empty(), "PCK excludes development, tests, raw sources, candidate packs and provenance")
	var contents := FileAccess.open(workspace.path_join("pck-files.json"), FileAccess.WRITE)
	contents.store_string(JSON.stringify(manifest, "\t"))
	contents.close()
	expected = JSON.parse_string(FileAccess.get_file_as_string(workspace.path_join("expected-data.json")))
	for path: String in expected:
		var bytes := FileAccess.get_file_as_bytes(path)
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		context.update(bytes)
		check(not bytes.is_empty() and context.finish().hex_encode() == expected[path], "raw JSON bytes survive export: " + path)
	if not bundle.is_empty():
		var configured := Database.configure_content_bundle(bundle)
		check(configured.ok, "explicit external compiled bundle validates against the PCK base hashes")
		if not configured.ok:
			finish()
			return
	var database := Database.new()
	check(database.errors.is_empty(), "all combat catalogs load without errors from the PCK")
	check(database.is_active() == not bundle.is_empty(), "external candidate content is never enabled implicitly")
	if not bundle.is_empty():
		var bundle_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(bundle.path_join("bundle.json")))
		for binding: Dictionary in bundle_data.get("bindings", []):
			if not binding.get("assets", {}).has("icon"): continue
			var texture: Texture2D = database.get_content_icon(str(binding.catalog), str(binding.id))
			check(texture != null and texture.get_width() > 0 and texture.get_height() > 0, "external PNG resolves to a real texture outside PCK: " + str(binding.id))
	for catalog: String in Database.CATALOGS:
		check(not database.get(catalog).is_empty(), "runtime catalog is present: " + catalog)
	for path: String in ["res://data/dialogue/village_warden.dialogue", "res://data/dialogue/village_merchant.dialogue"]:
		var dialogue: Resource = load(path)
		check(dialogue != null and not dialogue.get("lines").is_empty() and dialogue.get("titles").has("start"), "imported DialogueResource resolves from PCK: " + path)
	check(Preferences.set_damage_numbers(false) == OK and FileAccess.file_exists(Preferences.settings_path), "preferences write only to the injected OS-temp file")
	app = await make_app()
	check(app.stage == app.Stage.TITLE and is_instance_valid(app.menu), "exported title scene and its actual UI instantiate")
	var created: Dictionary = app.saves.create("导出验证旅人", 0)
	check(created.ok, "new named adventure is created in the isolated repository")
	if not created.ok:
		finish()
		return
	app.queue_free()
	await ticks(3)
	app = await make_app(created.snapshot)
	var game: Node = app.game
	check(is_instance_valid(game.reference_map) and game.rpg.loadout.level == 0, "actual main map and Lv0 actor load from PCK")
	check(game.narrative_npcs.size() == 2 and game.chapter.phase() == "patrol_available", "NPC and chapter JSON instantiate their real services")
	var deadline := Time.get_ticks_msec() + 5000
	while not game.world_navigation.navigation_ready() and Time.get_ticks_msec() < deadline: await physics_frame
	check(game.world_navigation.navigation_ready(), "exported navigation resource publishes its map")
	check(game.rpg.progression.choose_career("warrior"), "real starter career can be chosen in the exported game")
	check(game.rpg.inventory.count("magic_candy") == 0, "exported starter does not contain debug level items")
	check(game.rpg.progression.learn_skill("warrior_whirlwind") and game.rpg.loadout.assign_skill(0, 0, "warrior_whirlwind"), "real skill learning and preparation work after export")
	var bridge := Bridge.new()
	bridge.setup(game)
	var manager: Node = root.get_node("DialogueManager")
	var line: Variant = await manager.get_next_dialogue_line(load("res://data/dialogue/village_warden.dialogue"), "start", [bridge])
	check(line != null and not str(line.text).is_empty(), "Dialogue Manager executes the imported NPC dialogue against live state")
	check(app.save_adventure(), "exported game saves its prepared character to disk")
	var restored: Dictionary = app.saves.load_slot(0)
	# JSON numbers reload as floats; compare every identity field in the same
	# serialized representation, as the production repository does.
	var expected_identity: Dictionary = JSON.parse_string(JSON.stringify(database.identity()))
	check(restored.ok and restored.snapshot.content_set == expected_identity, "disk save retains the correct content identity")
	app.queue_free()
	await ticks(3)
	app = await make_app(restored.snapshot)
	check(app.game.rpg.loadout.level == 1 and app.game.rpg.skill_at(0).get("id") == "warrior_whirlwind", "fresh App reconstructs career and prepared skill from the saved export")
	check(app.saves.directory == workspace.path_join("adventures") and Preferences.settings_path == workspace.path_join("preferences.cfg"), "all adventure and preference paths remain in OS-temp")
	app.queue_free()
	await ticks(4)
	finish()

func finish() -> void:
	var report := {"ok": failures.is_empty(), "checks": checks, "failures": failures, "workspace": workspace,
		"engine": Engine.get_version_info().string, "resource_count": manifest.size(), "external_bundle": not bundle.is_empty()}
	var file := FileAccess.open(workspace.path_join("smoke-report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("EXPORT_SMOKE %d/%d isolated=%s" % [checks - failures.size(), checks, workspace])
	quit(0 if failures.is_empty() else 1)
