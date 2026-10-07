extends SceneTree
## Real Forward+ projection, character book, input and recovery. This test owns
## fresh OS-temp preferences/saves before creating App; evidence goes to .work.
const Preferences = preload("res://rpg/game_preferences.gd")
var app: Node
var game: Node
var arena: Node
var overlay: Control
var output := ""
var isolated := ""
var checks := 0
var failures: Array[String] = []
var report: PackedStringArray = []
var images: PackedStringArray = []
var measurements: Array[Dictionary] = []
var capture_enabled := not "--no-captures" in OS.get_cmdline_user_args()

func _initialize() -> void:
	isolated = OS.get_temp_dir().path_join("mosslight-resource-ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path = isolated.path_join("preferences.cfg")
	output = ProjectSettings.globalize_path("res://.work/resource-ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(output)
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	var line := ("PASS " if ok else "FAIL ") + label
	print(line)
	report.append(line)

func tick(count := 1) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame

func key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)
	await tick()

func capture(label: String) -> void:
	if not capture_enabled: return
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	verify(frame.get_size() == root.size and frame.save_png(output.path_join(label + ".png")) == OK, "GPU capture " + label)
	images.append(label + ".png")

func geometry(ring: RefCounted, label: String) -> void:
	var actor: Node = arena.controlled_actor()
	var maximum: int = int(actor.resources.max_value("Stamina"))
	verify(ring.visible and ring.centers.size() == maximum and ring.pips.debug_state().slots.size() == maximum, label + " projects every real stamina point")
	if ring.centers.is_empty(): return
	var near := Vector3(arena.camera.global_basis.z.x, 0, arena.camera.global_basis.z.z).normalized()
	var flat := true
	var projected := true
	var in_front := true
	var min_y := INF
	var max_y := -INF
	var spacing := INF
	var center_x := 0.0
	var logical_size := root.get_visible_rect().size
	var pixel_scale := minf(float(root.size.x) / logical_size.x, float(root.size.y) / logical_size.y)
	for index in range(ring.centers.size()):
		var point: Vector3 = ring.ground_points[index]
		flat = flat and absf(point.y - actor.global_position.y - .025) < .001
		projected = projected and ring.centers[index].distance_to(arena.world_to_screen(point)) < .01
		in_front = in_front and (point - actor.global_position).dot(near) > 0
		min_y = minf(min_y, ring.centers[index].y)
		max_y = maxf(max_y, ring.centers[index].y)
		center_x += ring.centers[index].x
		for previous in range(index):
			spacing = minf(spacing, ring.centers[index].distance_to(ring.centers[previous]))
	verify(flat and projected and in_front, label + " stays on the camera-near ground arc")
	verify((max_y - min_y) * pixel_scale > 2.0 / 3.0, label + " retains a diagonal projected arc")
	var pixel_spacing := spacing * pixel_scale
	var pixel_radius: float = ring.pip_radius * pixel_scale
	verify(pixel_spacing > pixel_radius * 2.0 + .1, label + " all circles have clear physical gaps (spacing %.2f px, radius %.2f px)" % [pixel_spacing, pixel_radius])
	verify(pixel_spacing >= pixel_radius * 2.6 - .05, label + " zoom keeps the preferred bean spacing instead of tightening gaps")
	verify(pixel_radius >= 1.19, label + " compact points remain at least 2.4 physical pixels wide")
	verify(ring.pip_radius * 2.0 >= ring.stroke_width * 4.0, label + " beans are visibly wider than the guide line")
	verify(center_x / ring.centers.size() > arena.world_to_screen(actor.global_position).x + 2.0 / 3.0, label + " remains on the near right side")
	var feet: Vector2 = arena.world_to_screen(actor.global_position) * pixel_scale
	measurements.append({"label":label, "radius_px":pixel_radius, "spacing_px":pixel_spacing, "feet_px":[feet.x, feet.y], "world_radius":ring.radius_world, "span_degrees":rad_to_deg(ring.pip_span)})

func zoom(ring: RefCounted, camera_owner: Node, label: String) -> void:
	var smallest := INF
	var largest := 0.0
	var radii: Array[float] = []
	var spans: Array[float] = []
	for height in [8.0, 18.0, 32.0]:
		camera_owner.camera_height = height
		camera_owner.target_camera_height = height
		await tick(12)
		var sample := "%s-zoom-%d-%dx%d" % [label, height, root.size.x, root.size.y]
		geometry(ring, sample)
		smallest = minf(smallest, ring.pip_radius)
		largest = maxf(largest, ring.pip_radius)
		radii.append(ring.radius_world)
		spans.append(ring.pip_span)
		await capture(sample)
	verify(largest - smallest < .15, label + " near, normal and far zoom retain the same readable bean size")
	var previous_change := radii[1] * (18.0 - 8.0) / 18.0
	verify(absf((radii[1] - radii[0]) / previous_change - .25) < .005, label + " ring retains the quarter zoom response while arc space is available")
	verify(spans[2] > spans[1] + .1, label + " far zoom expands the occupied arc before enlarging the ring")
	verify(absf(spans[2] - deg_to_rad(168.0)) < .001 and radii[2] / radii[1] > .75 + .25 * 32.0 / 18.0 + .005, label + " a full arc enlarges the ring to preserve bean gaps")
	camera_owner.camera_height = 18.0
	camera_owner.target_camera_height = 18.0
	await tick(12)

func book(capacity: int, label: String) -> void:
	var actor: Node = game.player
	actor.set_physics_process(false)
	actor.resources.change("Stamina", -2)
	app.ui.character_tab = 0
	app.ui.show_panel("character")
	var deadline := Time.get_ticks_msec() + 4000
	while app.ui.is_animating() and Time.get_ticks_msec() < deadline: await process_frame
	await tick(3)
	verify(app.ui.panel == "character" and not app.ui.is_animating(), label + " real character book opens")
	verify(app.ui.rpg_state.resources.Stamina.max == capacity and app.ui.rpg_state.resources.Stamina.current == capacity - 2, label + " book receives all points including its final two empty slots")
	await capture(label)
	app.ui.close_panel(true)
	actor.set_physics_process(true)
	await tick(3)

func recover(ring: RefCounted) -> void:
	game.player.resources.configure("Stamina", 10)
	game.player.combat.engage()
	await key(KEY_SPACE, true)
	await key(KEY_SPACE, false)
	verify(game.player.resources.current("Stamina") == 9, "real dodge spends one of ten points")
	verify(ring.recovery_progress < 0, "dodge does not display recovery before the controller permits it")
	var outline := false
	var fill := false
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		await tick()
		var state: Dictionary = ring.pips.debug_state()
		if ring.recovery_progress > .25 and ring.recovery_progress < .8 and not outline:
			var slot: Dictionary = state.slots[int(state.available_count)]
			verify(slot.predicted and slot.fill == 0 and slot.outline > .25, "actual recovery progress traces the next empty outline")
			verify(absf(ring.recovery_progress - game.player.combat.stamina_recovery_progress()) < .12, "ring uses controller recovery progress without a fixed 1.5-second assumption")
			await capture("main-recovery-outline-1280")
			outline = true
		if state.available_count == 10 and state.slots[9].phase == "fill": fill = true
		if outline and fill and state.available_count == 10 and state.slots[9].phase == "full": break
	verify(outline and fill and game.player.resources.current("Stamina") == 10, "real resource gain completes the outline and fills the final point")
	await capture("main-recovered-1280")

func orbit(ring: RefCounted) -> void:
	var before: float = game.camera_yaw
	var before_ground: Vector3 = ring.ground_points[0]
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_MIDDLE
	press.pressed = true
	Input.parse_input_event(press)
	await tick()
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(170, 0)
	drag.screen_relative = Vector2(170, 0)
	Input.parse_input_event(drag)
	await tick()
	press = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_MIDDLE
	Input.parse_input_event(press)
	await tick(35)
	verify(absf(game.camera_yaw - before) > .4 and ring.ground_points[0].distance_to(before_ground) > .15, "real middle drag repositions the arc on the camera near side")
	geometry(ring, "main 10-point orbit")
	await capture("main-orbit-1280")

func run() -> void:
	create_timer(180, true).timeout.connect(func(): printerr("STAMINA VISUAL TIMEOUT"); quit(1))
	if DisplayServer.get_name() == "headless":
		printerr("This visual test requires Forward+ GPU rendering")
		quit(2)
		return
	root.size = Vector2i(1280, 720)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = app.SAVE_REPOSITORY.new(isolated.path_join("adventures"))
	root.add_child(app)
	app.set_process(false)
	await tick(3)
	app.selected_name = "体力显示测试"
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	game = app.game
	arena = game.combat_world
	verify(game.player.progression.choose_career("warrior"), "real main-world warrior fixture is ready")
	app.ui.close_panel(true)
	app.ui.modulate.a = 1
	app.ui.region_clock = 0
	game.sound.muted = true
	game.toast_time = 0
	arena.encounters_started = true
	for enemy in arena.enemies: enemy.set_physics_process(false)
	for child in game.get_children():
		if child.get_script() and child.get_script().resource_path == "res://rpg/world_overlay.gd": overlay = child
	await tick(25)
	verify(is_instance_valid(overlay) and overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE, "ground overlay never captures pointer input")
	var ring: RefCounted = overlay.stamina_ring
	for window: Vector2i in [Vector2i(960, 540), Vector2i(1280, 720)]:
		root.size = window
		await tick(10)
		for capacity in [3, 7, 10, 12]:
			game.player.resources.configure("Stamina", capacity)
			await tick(3)
			var label := "main-%d-%dx%d" % [capacity, window.x, window.y]
			geometry(ring, label)
			if capacity >= 10:
				await capture(label)
				await book(capacity, "book-%d-%dx%d" % [capacity, window.x, window.y])
		await zoom(ring, game, "main-12")
	await recover(ring)
	await orbit(ring)
	game.paused = true
	await tick(2)
	verify(not ring.visible, "paused main menu hides ground stamina")
	game.paused = false
	var location: Vector3 = game.player.global_position
	game.player.global_position += Vector3(1000, 0, 1000)
	ring.update(arena, 0)
	verify(not ring.visible and ring.centers.is_empty(), "offscreen player emits no points")
	game.player.global_position = location
	game.player.combat.state = "DEAD"
	ring.update(arena, 0)
	verify(not ring.visible, "dead player emits no points")
	verify(app.saves.directory == isolated.path_join("adventures") and Preferences.settings_path == isolated.path_join("preferences.cfg"), "all main-world settings and saves stay inside injected OS-temp")
	app.queue_free()
	await tick(5)
	paused = false
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	await tick(4)
	arena.player.loadout.select_career("warrior")
	arena.ui.toggle_menu(false)
	arena.sound.muted = true
	for enemy in arena.enemies: enemy.ai_enabled = false
	arena.toast_time = 0
	ring = arena.ui.stamina_ring
	for window: Vector2i in [Vector2i(960, 540), Vector2i(1280, 720)]:
		root.size = window
		await tick(10)
		for capacity in [3, 7, 10, 12]:
			arena.player.resources.configure("Stamina", capacity)
			await tick(3)
			var label := "arena-%d-%dx%d" % [capacity, window.x, window.y]
			geometry(ring, label)
			if capacity >= 10: await capture(label)
		await zoom(ring, arena.renderer, "arena-12")
	verify(not "体力" in arena.ui._resources.text, "arena HUD does not duplicate the foot stamina display")
	arena.ui.toggle_menu(true)
	await tick(2)
	verify(not ring.visible, "arena character menu hides ground stamina")
	arena.queue_free()
	await tick(3)
	var summary := "COMBAT_STAMINA_VISUAL_RESULT checks=%d failures=%d captures=%d" % [checks, failures.size(), images.size()]
	print(summary, " output=", output, " isolated=", isolated)
	report.append(summary)
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	report.append("Isolated: " + isolated)
	var file := FileAccess.open(output.path_join("stamina-visual.log"), FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	file.close()
	file = FileAccess.open(output.path_join("measurements.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(measurements, "\t"))
	file.close()
	quit(0 if failures.is_empty() else 1)
