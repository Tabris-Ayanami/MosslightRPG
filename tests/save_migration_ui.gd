extends "res://tests/frontend.gd"
## Real App/native-control UI coverage with an explicitly fake migration service
## for failure paths. Optional source/target args also exercise the real service.
## All preferences and destination repositories are installed under unique Temp
## before App enters the tree; never reads default player saves.
const Release = preload("res://rpg/content_release.gd")
const Database = preload("res://combat/combat_database.gd")
var evidence := ""
var source_save := ""
var source_release := ""
var target_release := ""
var panel: Control
var finished := false
var real_checked := false
var watchdog: SceneTreeTimer
var gpu := false
var screenshots: Array[String] = []

class FakeMigration:
	extends RefCounted
	var repository: RefCounted
	var preflights := 0
	var commits := 0
	var fail_preflight := false
	var fail_commit := false
	var planned := false
	func _init(target: RefCounted) -> void: repository = target
	func preflight(_source: String, _release: String) -> Dictionary:
		preflights += 1
		planned = not fail_preflight
		if fail_preflight: return {"ok":false, "error":"测试夹具：旧版本与冒险不匹配"}
		return {"ok":true, "error":"", "metadata":{"name":"旧日旅人", "level":3, "location":"风息原野", "display_time":"2026-09-30 12:00"}, "changes":["测试夹具：原有物品、技能与任务进度保留", "新增内容在新冒险中按正常途径获得"], "source_label":"旧发行 0.2.0", "target_label":"当前发行 0.3.0"}
	func commit(value: String, slot: int) -> Dictionary:
		commits += 1
		var ready := planned
		planned = false
		if fail_commit or not ready: return {"ok":false, "error":"测试夹具：所选空槽刚被占用"}
		# Fake service writes a normal empty slot solely to verify UI handoff. This
		# is never reported as migration-data evidence; the optional real case is.
		return repository.create(value, slot)

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--source-save="): source_save = argument.trim_prefix("--source-save=")
		elif argument.begins_with("--source-release="): source_release = argument.trim_prefix("--source-release=")
		elif argument.begins_with("--target-release="): target_release = argument.trim_prefix("--target-release=")
		elif argument.begins_with("--evidence="): evidence = argument.trim_prefix("--evidence=")
		elif argument == "--gpu": gpu = true
	call_deferred("run")

func click(button: Button) -> void:
	var point: Vector2 = button.get_global_rect().get_center()
	mouse(point, true)
	await ticks(1)
	mouse(point, false)
	await ticks(2)

func tap(code: Key) -> void:
	key(code, true)
	key(code, false)
	await ticks(2)

func button_named(value: String) -> Button:
	for child in panel.page.get_children():
		if child is Button and child.text == value: return child
	return null

func enter_selector() -> void:
	app.start_adventure()
	app._process(app.JOURNEY_SECONDS + .1)
	app.choice.age = 2
	await ticks(2)

func open_fake() -> FakeMigration:
	# Migration remains available to internal tooling, without a player-facing
	# entry in the opening sequence. Exercise its controller explicitly.
	app._open_save_migration()
	await ticks(2)
	check(panel.visible and not app.choice.visible and app.stage == app.Stage.CHOOSING, "internal migration entry opens isolated wizard without changing App stage")
	var fake := FakeMigration.new(app.saves)
	panel.service = fake
	panel.user_data_directory = test_workspace
	return fake

func set_paths() -> void:
	panel.source_input.text = test_workspace.path_join("source.json")
	panel.release_input.text = test_workspace.path_join("old-release")

func to_target() -> void:
	set_paths()
	await click(panel.next_button)
	check(panel.step == panel.Step.REVIEW, "source preflight reaches review before a destination can be chosen")
	await click(panel.next_button)
	check(panel.step == panel.Step.TARGET, "review advances to destination and name without creating a slot")

func run() -> void:
	test_workspace = OS.get_temp_dir().path_join("mosslight-save-migration-ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(test_workspace)
	DirAccess.make_dir_recursive_absolute(test_workspace.path_join("releases"))
	Preferences.settings_path = test_workspace.path_join("preferences.cfg")
	if evidence.is_empty(): evidence = ProjectSettings.globalize_path("res://.work/content-migration-ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not evidence.is_absolute_path():
		check(false, "evidence directory must be absolute")
		finish()
		return
	if gpu and DisplayServer.get_name() == "headless":
		check(false, "GPU capture requires an actual display")
		finish()
		return
	if gpu: root.size = Vector2i(1280, 720)
	watchdog = create_timer(180 if gpu else 100, true)
	watchdog.timeout.connect(_timeout)
	if not target_release.is_empty():
		var activation: Dictionary = Release.activate(target_release, test_workspace.path_join("releases"))
		check(activation.ok, "real target release activates before first App Database")
		if not activation.ok:
			finish()
			return
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = app.SAVE_REPOSITORY.new(test_workspace.path_join("ui-adventures"))
	check(app.saves.create("已有冒险", 0).ok, "occupied fixture is created only in isolated target repository")
	var interrupted := FileAccess.open(app.saves.directory.path_join("slot_03.json.tmp"), FileAccess.WRITE)
	interrupted.store_string("interrupted fixture")
	interrupted.close()
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	panel = app.save_migration_panel
	await enter_selector()
	check(app.choice.slot_buttons.size() == 20 and app.choice.buttons.size() == 22, "ordinary continue page has twenty slots, Continue and Back")
	check(not is_instance_valid(app.game), "no world is mounted while choosing old records")
	var original_selection: int = app.choice.selected_slot
	var fake: FakeMigration = await open_fake()
	await tap(KEY_RIGHT)
	check(app.choice.selected_slot == original_selection, "arrow input in wizard does not move the hidden save selector")
	await click(panel.next_button)
	check(fake.preflights == 0 and panel.step == panel.Step.SOURCE and not panel.error_label.text.is_empty(), "missing paths are explained without invoking preflight or writing a slot")
	await click(button_named("选择文件"))
	check(panel.source_dialog.visible and panel.source_dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE and panel.source_dialog.filters[0].contains("*.bak"), "native source picker accepts JSON and backup records")
	check(panel.source_dialog.current_dir.replace("\\", "/").trim_suffix("/") == test_workspace.path_join("releases"), "source picker starts in the injected releases folder without browsing real player files")
	panel.user_data_directory = test_workspace.path_join("absent-releases")
	check(panel._source_start_directory() == panel.user_data_directory, "source picker falls back to game data root when no releases directory exists")
	panel.user_data_directory = test_workspace
	# Supply the native picker result explicitly, without browsing real user files.
	panel.source_dialog.file_selected.emit(test_workspace.path_join("source.json"))
	panel.source_dialog.hide()
	await click(button_named("选择文件夹"))
	check(panel.release_dialog.visible and panel.release_dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR, "native old-version picker selects a complete game directory")
	panel.release_dialog.dir_selected.emit(test_workspace.path_join("old-release"))
	panel.release_dialog.hide()
	check(panel.source_input.text.ends_with("source.json") and panel.release_input.text.ends_with("old-release"), "picker callbacks fill the editable full paths")
	fake.fail_preflight = true
	await click(panel.next_button)
	check(fake.preflights == 1 and panel.step == panel.Step.SOURCE and not app.saves.slot(1).occupied, "failed preflight keeps source selection and does not create an adventure")
	fake.fail_preflight = false
	await click(panel.next_button)
	var summary := ""
	for child in panel.page.get_children():
		if child is RichTextLabel: summary = child.text
	check(panel.step == panel.Step.REVIEW and summary.contains("旧日旅人") and summary.contains("0.2.0") and summary.contains("0.3.0") and summary.contains("原冒险会完整保留"), "review contains source identity, versions, actual changes and old-save retention")
	await tap(KEY_ESCAPE)
	check(panel.visible and panel.step == panel.Step.SOURCE and panel.checked.is_empty() and app.stage == app.Stage.CHOOSING, "Escape from review goes back inside wizard and invalidates the displayed plan")
	await to_target()
	check(panel.slot_buttons.size() == 20 and panel.slot_buttons[0].disabled and panel.slot_buttons[2].disabled and not panel.slot_buttons[1].disabled, "target keeps twenty slots and refuses occupied or interrupted records")
	check(panel.selected_slot == 1 and panel.name_input.text == "旧日旅人副本", "first empty slot and a readable copy name are suggested")
	panel.name_input.text = "已有冒险"
	await click(panel.next_button)
	check(fake.commits == 0 and panel.step == panel.Step.TARGET and not panel.error_label.text.is_empty(), "duplicate name is rejected without consuming the migration plan")
	panel.name_input.text = "   "
	await click(panel.next_button)
	check(fake.commits == 0 and not app.saves.slot(1).occupied, "blank name cannot create a copied slot")
	panel.busy = true
	panel.request_close()
	panel._next()
	check(panel.visible and fake.commits == 0, "busy wizard blocks closing and duplicate actions")
	panel.busy = false
	await tap(KEY_ESCAPE)
	await tap(KEY_ESCAPE)
	await tap(KEY_ESCAPE)
	check(not panel.visible and app.choice.visible and app.stage == app.Stage.CHOOSING and app.choice.slot_buttons[app.choice.selected_slot].has_focus(), "Escape returns through steps to the original selector and restores slot focus")
	check(not app.saves.slot(1).occupied and not is_instance_valid(app.game), "cancelled wizard never creates or launches an adventure")
	fake = await open_fake()
	await to_target()
	panel.name_input.text = "副本旅人"
	var confirm: Button = panel.next_button
	confirm.pressed.emit()
	confirm.pressed.emit()
	await ticks(2)
	check(fake.commits == 1 and app.saves.slot(1).name == "副本旅人", "repeated confirm signals submit exactly one copy")
	check(not panel.visible and app.choice.visible and app.choice.selected_slot == 1 and app.choice.slot_buttons.size() == 20, "success refreshes ordinary slots and selects the new copy")
	check(is_instance_valid(app.choice.notice_panel) and app.choice.notice_panel.mouse_filter == Control.MOUSE_FILTER_IGNORE and app.choice.notice_panel.get_child_count() == 1 and app.choice.notice_panel.get_child(0) is Label and app.choice.notice_panel.get_child(0).text.contains("副本已保存"), "copy completion has a readable notice that cannot intercept Continue input")
	check(app.selected_save == -1 and app.pending_snapshot.is_empty() and not is_instance_valid(app.game), "successful copying waits for normal Continue rather than starting the world in preflight")
	app.choice.age = 2
	fake = await open_fake()
	fake.fail_commit = true
	await to_target()
	panel.name_input.text = "失败副本"
	await click(panel.next_button)
	panel._commit()
	check(fake.commits == 1 and panel.step == panel.Step.SOURCE and panel.checked.is_empty(), "commit failure consumes the plan and requires a new source preflight")
	check(panel.source_input.text.ends_with("source.json") and panel.error_label.text.contains("重新检查") and not app.saves.slot(3).occupied, "failure preserves chosen paths, explains retry and leaves target empty")
	panel.request_close()
	for index in range(20):
		if not app.saves.slot(index).occupied: app.saves.create("满槽夹具%02d" % index, index)
	fake = await open_fake()
	await to_target()
	check(panel.selected_slot == -1 and panel.next_button.disabled and panel.slot_buttons.size() == 20 and panel.error_label.text.contains("20"), "full destination has actionable feedback and no overwrite route")
	panel.request_close()
	if not source_save.is_empty() or not source_release.is_empty() or not target_release.is_empty(): await real_case()
	check(Preferences.settings_path.begins_with(test_workspace + "/") and app.saves.directory.begins_with(test_workspace + "/"), "preferences and every target repository remain in the unique Temp workspace")
	finish()

func real_case() -> void:
	if source_save.is_empty() or source_release.is_empty() or target_release.is_empty():
		check(false, "real integration requires source-save, source-release and target-release together")
		return
	var source_hash := FileAccess.get_sha256(source_save)
	var frozen_identity := JSON.stringify(Release.identity())
	app.saves = app.SAVE_REPOSITORY.new(test_workspace.path_join("real-adventures"))
	app.choice.set_save_slots(app.saves.list_slots())
	app.choice.present("continue")
	app.choice.age = 2
	app._open_save_migration()
	await ticks(2)
	panel.source_input.text = source_save
	panel.release_input.text = source_release
	await capture_sizes("01-source")
	await click(panel.next_button)
	check(panel.step == panel.Step.REVIEW and panel.checked.get("ok", false), "real service preflights actual old release and save through the App wizard")
	if panel.step != panel.Step.REVIEW:
		print("REAL_PREFLIGHT_ERROR ", panel.error_label.text)
		return
	var old_metadata: Dictionary = panel.checked.metadata.duplicate(true)
	var review_text := ""
	for child in panel.page.get_children():
		if child is RichTextLabel: review_text = child.text
	check(not panel.checked.changes.is_empty() and panel.checked.changes.all(func(change: Variant) -> bool: return review_text.contains(str(change))), "real review visibly lists every preflight change before confirmation")
	print("REAL_REVIEW_TEXT ", JSON.stringify(review_text))
	await capture_sizes("02-review")
	if gpu:
		for child in panel.page.get_children():
			if child is RichTextLabel: child.get_v_scroll_bar().value = child.get_v_scroll_bar().max_value
		await capture_sizes("02-review-bottom")
	await click(panel.next_button)
	panel.name_input.text = "真实迁移副本"
	await capture_sizes("03-target")
	await click(panel.next_button)
	check(not panel.visible and app.choice.selected_slot == 0 and app.saves.slot(0).valid, "real commit creates a readable selected target slot through native controls")
	if panel.visible:
		print("REAL_COMMIT_ERROR ", panel.error_label.text)
		return
	await capture_sizes("04-copied-selector")
	check(FileAccess.get_sha256(source_save) == source_hash, "real UI migration leaves source bytes unchanged")
	check(JSON.stringify(Release.identity()) == frozen_identity and JSON.stringify(app.saves.database.identity()) == frozen_identity, "preflight and copy never switch the current release or database")
	var loaded: Dictionary = app.saves.load_slot(0)
	check(loaded.ok and loaded.metadata.name == "真实迁移副本" and loaded.metadata.level == old_metadata.level, "real copied slot retains source level with the chosen new name")
	app.choice.age = 2
	await tap(KEY_ENTER)
	check(app.stage == app.Stage.DISSOLVING and app.selected_save == 0 and app.selected_name == "真实迁移副本", "ordinary Continue accepts the migrated slot and starts the existing journey")
	await mount_selected()
	check(is_instance_valid(app.game) and app.game.rpg.display_name == "真实迁移副本" and app.pending_snapshot.is_empty(), "real migrated snapshot restores into the actual game through App")
	if not is_instance_valid(app.game): return
	# Pending rewards may legitimately settle on entry. Capture the settled state
	# once, then prove full App/Repository reconstruction cannot pay it again.
	var inventory: Dictionary = app.game.rpg.inventory.export_state()
	var progression: Dictionary = app.game.rpg.progression.export_state()
	var loadout: Dictionary = app.game.rpg.loadout.export_state()
	var stock: Dictionary = app.game.world_state.get_object("economy.shop.village_supply")
	check(app.save_adventure(), "migrated adventure saves through the actual App")
	var saved: Dictionary = app.saves.load_slot(0)
	check(saved.ok, "saved migrated adventure is verified from disk before reconstruction")
	app.selected_save = -1
	app.queue_free()
	await ticks(5)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = app.SAVE_REPOSITORY.new(test_workspace.path_join("real-adventures"))
	var reread: Dictionary = app.saves.load_slot(0)
	check(reread.ok and same(reread.snapshot, saved.snapshot), "entirely new Repository rereads the identical copied adventure from disk")
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	panel = app.save_migration_panel
	await enter_selector()
	await tap(KEY_ENTER)
	await mount_selected()
	check(is_instance_valid(app.game) and app.selected_save == 0 and app.selected_name == "真实迁移副本", "fresh App continues the migrated adventure through its ordinary slot selector")
	if not is_instance_valid(app.game): return
	check(same(app.game.rpg.inventory.export_state(), inventory) and same(app.game.rpg.progression.export_state(), progression), "full reconstruction retains quantities and reward receipts without a second pending payout")
	check(same(app.game.rpg.loadout.export_state(), loadout) and same(app.game.world_state.get_object("economy.shop.village_supply"), stock), "full reconstruction retains career, prepared skill and finite merchant stock")
	check(app.game.quests.status("village_patrol") == "rewarded" and FileAccess.get_sha256(source_save) == source_hash, "rewarded quest stays rewarded and old save still has identical bytes after continued play")
	real_checked = true

func same(left: Variant, right: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))

func mount_selected() -> void:
	# Continue owns a threaded request; consume that request exactly as App's
	# LOADING stage does, rather than opening another load beside it.
	var scene: PackedScene = ResourceLoader.load_threaded_get(app.GAME_PATH) if app.load_requested else load(app.GAME_PATH)
	app._enter_world(scene)
	if not is_instance_valid(app.game): return
	# Movement/combat is outside migration acceptance. Stop time before waiting
	# and exercise the real reward reconciliation explicitly once per restore.
	app.game.combat_world.set_physics_process(false)
	for enemy in app.game.combat_world.enemies:
		if is_instance_valid(enemy): enemy.set_physics_process(false)
	await ticks(3)
	app.game.combat_world._retry_pending()

func _timeout() -> void:
	check(false, "migration UI suite finishes within its bounded deadline")
	finish()

func capture_sizes(label: String) -> void:
	if not gpu: return
	DirAccess.make_dir_recursive_absolute(evidence)
	var original: Vector2i = root.size
	for extent in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = extent
		await ticks(3)
		if app.choice.visible:
			# Sample the finished glyph reveal, without waiting for the cinematic.
			app.choice.age = 3
			for word in app.choice.words:
				word.age = 3
				word._process(0)
			app.choice._process(0)
		await RenderingServer.frame_post_draw
		var path := evidence.path_join("%s-%dx%d.png" % [label, extent.x, extent.y])
		var picture := root.get_texture().get_image()
		check(picture != null and picture.get_size() == extent and picture.save_png(path) == OK, "capture %s at %dx%d" % [label, extent.x, extent.y])
		screenshots.append(path)
	root.size = original
	await ticks(3)

func finish() -> void:
	if finished: return
	finished = true
	if watchdog != null and watchdog.timeout.is_connected(_timeout): watchdog.timeout.disconnect(_timeout)
	watchdog = null
	if is_instance_valid(app):
		app.queue_free()
	await ticks(18)
	app = null
	panel = null
	DirAccess.make_dir_recursive_absolute(evidence)
	var report := {"ok":failures.is_empty(), "checks":count, "failures":failures, "isolated":test_workspace, "real_service":real_checked, "source_save":source_save, "source_release":source_release, "target_release":target_release, "gpu":gpu, "renderer":RenderingServer.get_current_rendering_method(), "screenshots":screenshots, "scope":"Native App UI; fake service explicitly isolates error paths; real-service assertions only when all release fixture arguments are supplied."}
	var file := FileAccess.open(evidence.path_join("report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("SAVE_MIGRATION_UI %d/%d report=%s" % [count - failures.size(), count, evidence.path_join("report.json")])
	quit(0 if failures.is_empty() else 1)
