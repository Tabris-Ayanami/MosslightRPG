extends SceneTree
## Live character page and unbound art fallback; no race-changing controls.
const OUTPUT := "res://docs/rpg/race/"
var app: Node
var checks := 0
var failures := 0
var report: PackedStringArray = []

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	var text := ("PASS " if ok else "FAIL ") + label
	print(text)
	report.append(text)

func frames(count: int) -> void:
	for i in range(count):
		await process_frame
		await RenderingServer.frame_post_draw

func settled() -> void:
	await frames(3)
	for i in range(120):
		if not app.ui.is_animating(): break
		await frames(1)
	await frames(3)

func capture(name: String) -> void:
	check(root.get_texture().get_image().save_png(OUTPUT + name + ".png") == OK, "capture " + name)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1920, 1080)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await frames(3)
	app._enter_world(load("res://scenes/main.tscn"))
	await frames(3)
	app._finish_arrival()
	app.game.sound.muted = true
	app.ui.close_panel(true)
	app.ui.region_clock = 0
	app.ui.character_tab = 0
	var press := InputEventKey.new()
	press.physical_keycode = KEY_X
	press.keycode = KEY_X
	press.pressed = true
	Input.parse_input_event(press)
	await frames(1)
	press = InputEventKey.new()
	press.physical_keycode = KEY_X
	press.keycode = KEY_X
	press.pressed = false
	Input.parse_input_event(press)
	await settled()
	check(app.ui.panel == "character" and app.ui.character_tab == 0 and app.ui.has_rpg(), "physical C opens the actual bound character attributes page")
	check(app.game.player.race_id == "human" and app.ui.rpg_state.race_id == "human" and app.ui.rpg_state.race == "人类", "human actor identity reaches the view model in both forms")
	capture("character_human_1920")
	root.size = Vector2i(960, 540)
	await frames(12)
	capture("character_human_960")
	root.size = Vector2i(1920, 1080)
	app.ui.bind_rpg(null)
	app.ui._build_modal()
	await frames(12)
	check(not app.ui.has_rpg() and app.ui.panel == "character", "unbound character art fallback remains available")
	capture("character_human_fallback_1920")
	var result := "RACE_IDENTITY_VISUAL_RESULT checks=%d failures=%d captures=3" % [checks, failures]
	print(result)
	report.append(result)
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	var file := FileAccess.open(OUTPUT + "visual_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	file.close()
	app.queue_free()
	await frames(3)
	quit(0 if failures == 0 else 1)
