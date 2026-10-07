extends SceneTree
## Developer preview only. Bundle selection happens before App/Repository exist.
## Each compiled hash owns separate settings and saves, never formal adventures.
const Database = preload("res://combat/combat_database.gd")
const Preferences = preload("res://rpg/game_preferences.gd")

func _initialize() -> void:
	call_deferred("_start")

func _start() -> void:
	var bundle_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--bundle="):
			bundle_path = argument.trim_prefix("--bundle=")
	if bundle_path.is_empty():
		printerr("Usage: godot --path PROJECT --script res://tools/content_preview.gd -- --bundle=ABSOLUTE_BUILD_DIRECTORY")
		quit(2)
		return
	var selected: Dictionary = Database.configure_content_bundle(bundle_path)
	if not selected.ok:
		printerr("Content preview refused: ", selected.error)
		quit(1)
		return
	var isolated := OS.get_user_data_dir().path_join("content-previews").path_join(str(selected.identity.bundle_sha256))
	if "--temporary" in OS.get_cmdline_user_args():
		isolated = OS.get_temp_dir().path_join("mosslight-content-preview-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if DirAccess.make_dir_recursive_absolute(isolated) != OK:
		printerr("Cannot create isolated content preview directory")
		quit(1)
		return
	Preferences.settings_path = isolated.path_join("preferences.cfg")
	var app: Node = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = app.SAVE_REPOSITORY.new(isolated.path_join("adventures"))
	root.add_child(app)
	root.title = "内容预览 · 独立冒险 · " + str(selected.identity.bundle_sha256).left(8)
	print("CONTENT_PREVIEW ", JSON.stringify({"identity":selected.identity, "directory":isolated}))
	if "--sample" in OS.get_cmdline_user_args():
		await _sample(app)

## Explicit developer fixture, not a production reward or a new-player grant.
## Reopening --sample resumes that preview slot without issuing items again.
func _sample(app: Node) -> void:
	await process_frame
	var entry: Dictionary = app.saves.slot(0)
	var fresh: bool = not entry.occupied
	var adventure: Dictionary = app.saves.create("内容包试玩", 0) if fresh else app.saves.load_slot(0)
	if not adventure.ok:
		printerr("Cannot prepare preview sample: ", adventure.error)
		return
	app.selected_save = 0
	app.selected_name = adventure.snapshot.name
	app.pending_snapshot = adventure.snapshot
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	var actor: Node = app.game.rpg
	if fresh:
		if not actor.progression.choose_career("warrior"):
			printerr("Cannot prepare sample career: ", actor.progression.last_error)
			return
		for step in range(2):
			if not actor.progression.level_up():
				printerr("Cannot prepare sample level: ", actor.progression.last_error)
				return
		var database: RefCounted = actor.loadout.database
		for catalog: String in ["items", "weapons", "equipment"]:
			for id: String in database.get(catalog):
				if ":" in id:
					actor.inventory.add_item(id, 3 if catalog == "items" else 1)
		# The documented six-family sample has a warrior advancement. Other
		# bundles still expose their actual careers and learning requirements.
		if database.careers.has("trail_guard:warden"):
			actor.progression.choose_career("trail_guard:warden")
		if actor.inventory.count("trail_guard:watch_sword") > 0:
			actor.loadout.equip_weapon(0, "trail_guard:watch_sword")
		if actor.inventory.count("trail_guard:scout_hood") > 0:
			actor.loadout.equip_item("head", "trail_guard:scout_hood")
		if database.skills.has("trail_guard:guard_cut") and actor.progression.learn_skill("trail_guard:guard_cut"):
			actor.loadout.assign_skill(0, 0, "trail_guard:guard_cut")
		if actor.inventory.count("trail_guard:herbal_draught") > 0:
			actor.inventory.assign_quick_slot(0, "trail_guard:herbal_draught")
		if not app.save_adventure(): printerr(app.ui.save_note)
	app.ui.close_panel(true)
	app.ui.show_panel("bag")
