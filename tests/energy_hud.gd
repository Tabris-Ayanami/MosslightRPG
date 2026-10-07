extends SceneTree
## Real HUDs read the same continuous runtime pool for martial and magic careers.
const OUTPUT := "res://docs/hud/"
const BAR = preload("res://scripts/frontend/hud_energy_bar.gd")
var app: Node
var game: Node
var actor: Node
var checks := 0
var failures := 0
var report: PackedStringArray = []
var warrior_blue := Color.TRANSPARENT

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	var line := ("PASS " if ok else "FAIL ") + label
	print(line)
	report.append(line)
func screenshot(label: String) -> Image:
	if DisplayServer.get_name() == "headless": return null
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	check(frame.get_size() == Vector2i(1920, 1080) and frame.save_png(OUTPUT + label + ".png") == OK, "GPU capture " + label)
	return frame
func energy_pixel(frame: Image, offset: Vector2) -> Color:
	var rect: Rect2 = app.ui.hud_energy_rect()
	var point: Vector2 = app.ui.get_global_transform() * (rect.position + offset)
	return frame.get_pixel(int(point.x), int(point.y))
func close_color(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) < .055
func set_energy(value: float) -> void:
	actor.resources.change("Energy", value - actor.resources.current("Energy"))
	await ticks(2)
	check(is_equal_approx(app.ui.hud_energy_ratio(), value / actor.resources.max_value("Energy")), "HUD ratio tracks exact runtime energy " + str(value))
func build(career: String) -> void:
	app = load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	game = app.game
	actor = game.player
	check(actor.progression.choose_career(career), "choose real " + career + " career")
	app.ui.close_panel(true)
	app.ui.region_clock = 0
	app.ui.modulate.a = 1
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	await ticks(4)
	actor.set_physics_process(false)
	check(app.ui.hud_resource_id == "Energy" and actor.resources.max_value("Energy") > 0, career + " uses the same Energy resource ID")
	check(app.ui.hud_energy_rect() == Rect2(121, 85, 183, 14), "energy is a thin slanted meter touching the HP bottom edge at 75 percent HP width")
func dispose() -> void:
	game._release_actions()
	app.queue_free()
	await ticks(4)
func run() -> void:
	root.size = Vector2i(1920, 1080)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	check(BAR.ratio(20, 0) == 0 and BAR.ratio(-1, 60) == 0 and BAR.ratio(80, 60) == 1, "bar clamps empty, negative and overfilled resource values")
	for career: String in ["warrior", "mage"]:
		await build(career)
		await set_energy(actor.resources.max_value("Energy"))
		var full := await screenshot("energy-" + career + "-full-1080")
		if full:
			var color := energy_pixel(full, Vector2(35, 3))
			check(close_color(color, BAR.FILL), career + " full meter renders blue")
			if career == "warrior": warrior_blue = color
			else: check(close_color(color, warrior_blue), "mage and warrior meter have the identical rendered blue")
		var skill := "warrior_whirlwind" if career == "warrior" else "mage_fireball"
		check(actor.progression.learn_skill(skill) and actor.loadout.assign_skill(0, 0, skill), career + " learns and prepares its real Q skill")
		var before: float = actor.resources.current("Energy")
		# Start through the real controller, then freeze simulation for exact
		# visual samples without regeneration advancing between captures.
		actor.set_physics_process(true)
		actor.combat.command("skill_q")
		actor.set_physics_process(false)
		await ticks(2)
		var cost: float = actor.skill_at(0).get("costs", {}).get("Energy", 0)
		print("ENERGY_SKILL ", career, " before=", before, " after=", actor.resources.current("Energy"), " cost=", cost)
		check(cost > 0 and is_equal_approx(actor.resources.current("Energy"), before - cost) and is_equal_approx(app.ui.hud_energy_ratio(), (before - cost) / actor.resources.max_value("Energy")), career + " real skill immediately decreases the shared meter by its actual energy cost")
		actor.combat.reset()
		await set_energy(0)
		var empty := await screenshot("energy-" + career + "-empty-1080")
		if empty: check(close_color(energy_pixel(empty, Vector2(35, 3)), BAR.BACKGROUND), career + " empty meter retains only its dark blue track")
		# 140 is deliberately above 100: this is a pool capacity, never a percentage cap.
		actor.resources.configure("Energy", 140)
		await set_energy(52.5)
		check(is_equal_approx(app.ui.hud_energy_ratio(), .375), "fractional 52.5 / 140 energy fills exactly 37.5 percent")
		var partial := await screenshot("energy-" + career + "-fractional-1080")
		if partial:
			check(close_color(energy_pixel(partial, Vector2(35, 3)), BAR.FILL) and close_color(energy_pixel(partial, Vector2(100, 3)), BAR.BACKGROUND), career + " fractionally consumed bar has a filled left portion and an empty right portion")
		check(actor.resources.pay({"Energy": 2.25}), "continuous Energy permits a fractional payment")
		await ticks(2)
		check(is_equal_approx(app.ui.hud_energy_ratio(), 50.25 / 140), "fractional payment updates without rounding into discrete pips")
		await dispose()
	var arena: Node = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	await ticks(3)
	check(arena.player.loadout.select_career("warrior"), "laboratory chooses warrior")
	arena.ui.toggle_menu(false)
	arena.sound.muted = true
	arena.player.set_physics_process(false)
	arena.player.resources.configure("Energy", 140)
	arena.player.resources.change("Energy", -87.5)
	await ticks(3)
	check(arena.ui._resources.get_script() == BAR and is_equal_approx(arena.ui._resources.current, 52.5) and is_equal_approx(arena.ui._resources.maximum, 140), "laboratory reuses the same slanted blue meter and exact fractional pool")
	arena.ui._refresh_character_info()
	check("能量 52.5 / 140" in arena.ui._character_info.text and not "斗气" in arena.ui._character_info.text and not "法术位" in arena.ui._character_info.text, "laboratory character sheet shows only the shared energy value")
	check(not "体力" in arena.ui._resources.text and arena.ui.stamina_ring.visible, "stamina remains on the foot ring rather than the energy HUD")
	await screenshot("energy-laboratory-fractional-1080")
	arena.queue_free()
	await ticks(4)
	var summary := "ENERGY_HUD_RESULT checks=%d failures=%d" % [checks, failures]
	print(summary)
	report.append(summary)
	var file := FileAccess.open(OUTPUT + "energy-hud-test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	file.close()
	quit(0 if failures == 0 else 1)
