extends SceneTree
## Child-process probe. The Python driver supplies a fresh temporary save directory.
const Repository = preload("res://rpg/save_repository.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
var mode := ""
var directory := ""
var checks := 0
var failed := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--mode": mode = args[i + 1]
		if args[i] == "--directory": directory = args[i + 1]
	call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failed = true
	print("PASS " if ok else "FAIL ", label)

func run() -> void:
	# Never fall back to the repository's real user:// destination.
	var temp_prefix := OS.get_temp_dir().replace("\\", "/").simplify_path() + "/mosslight-close-"
	if not directory.replace("\\", "/").simplify_path().begins_with(temp_prefix) or mode not in ["close", "freed"]:
		printerr("FAIL probe requires a scoped driver temporary directory and known mode")
		quit(80)
		return
	root.size = Vector2i(1280, 720)
	Preferences.settings_path = directory.path_join("preferences.cfg")
	var app: Node = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = Repository.new(directory)
	root.add_child(app)
	current_scene = app
	await ticks(5)
	verify(not auto_accept_quit, "frontend intercepts close while it owns the window")
	if mode == "freed":
		app.queue_free()
		await ticks(3)
		verify(not is_instance_valid(app) and auto_accept_quit, "freeing frontend restores SceneTree auto_accept_quit")
		print("SAVE_CLOSE_PROBE mode=freed checks=%d failures=%d" % [checks, int(failed)])
		quit(1 if failed else 0)
		return
	if mode == "close":
		var created: Dictionary = app.saves.create("Close probe", 4)
		verify(created.ok, "probe adventure is created only in temporary directory")
		if not created.ok:
			quit(81)
			return
		app.selected_name = "Close probe"
		app.selected_save = 4
		app.pending_snapshot = created.snapshot
		app._enter_world(load("res://scenes/main.tscn"))
		app._finish_arrival()
		if app.ui.panel != "": app.ui.close_panel(true)
		await ticks(3)
		var actor: Node = app.game.rpg
		verify(actor.progression.choose_career("warrior"), "real main-world character chooses career before close")
		verify(actor.inventory.count("magic_candy") == 0 and actor.inventory.add_item("magic_candy", 9), "close fixture explicitly grants its initial nine debug candies")
		actor.inventory.add_item("magic_candy", 3)
		verify(actor.inventory.use_item("magic_candy") and actor.inventory.use_item("magic_candy"), "latest unsaved state reaches level three through actual items")
		actor.inventory.add_item("healing_potion", 17)
		actor.progression.add_experience(42)
		verify(actor.loadout.level == 3 and actor.inventory.count("magic_candy") == 10 and actor.inventory.count("healing_potion") == 22 and actor.progression.experience == 42, "latest unsaved inventory and growth are known before window close")
		verify(app.saves.load_slot(4).snapshot.loadout.level == 0, "disk still contains initial Lv0 snapshot before close request")
		verify(app.stage == app.Stage.PLAYING and not auto_accept_quit, "close request reaches PLAYING frontend save handler")
		# Frozen input protects this narrow close test from enemies, not save logic.
		app.game.player.set_physics_process(false)
		var marker := FileAccess.open(directory.path_join("close_expected.json"), FileAccess.WRITE)
		marker.store_string(JSON.stringify({"slot": 4, "level": 3, "experience": 42, "magic_candy": 10, "healing_potion": 22}))
		marker.close()
	if failed:
		quit(82)
		return
	print("SAVE_CLOSE_DISPATCH mode=%s checks=%d auto_accept=%s" % [mode, checks, str(auto_accept_quit)])
	# Deliver the OS close notification through the node tree. Emitting the
	# Window signal alone does not synthesize this engine notification headlessly.
	root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await create_timer(3.0, true).timeout
	printerr("FAIL window close request did not terminate the child process")
	quit(83)
