extends SceneTree
## Real frontend, village NPC, imported dialogue, combat death and modal input.
const Preferences = preload("res://rpg/game_preferences.gd")
const OUT := "res://docs/narrative-world/"
var app: Node
var game: Node
var npc: Node3D
var checks := 0
var failures: Array[String] = []
var gpu := false

func _initialize() -> void: call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		await ticks(2)
	await ticks(3)

func shot(label: String) -> void:
	if not gpu: return
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	check(picture.get_size() == root.size, "native screenshot dimensions: " + label)
	check(picture.save_png(OUT + label + ".png") == OK, "GPU screenshot saved: " + label)

func run() -> void:
	create_timer(80, true).timeout.connect(func():
		printerr("Narrative world test timed out")
		quit(1))
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-narrative-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	gpu = DisplayServer.get_name() != "headless"
	root.size = Vector2i(1920, 1080)
	if gpu: DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = app.SAVE_REPOSITORY.new(Preferences.settings_path + "-adventures")
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.close_panel(true)
	app.ui.modulate.a = 1
	app.ui.region_clock = 0
	game = app.game
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	await ticks(8)
	check(game.narrative_npcs.size() == 2, "warden and merchant populate the actual main world")
	if game.narrative_npcs.is_empty():
		app.queue_free()
		await ticks(2)
		quit(1)
		return
	npc = game.narrative_npcs[0]
	check(npc.get_world_3d() == game.player.get_world_3d(), "NPC belongs to the gameplay physics world")
	check(npc.global_position.y < 3 and npc.global_position.y > 1.8, "NPC feet rest on terrain instead of its own collision capsule")
	check(npc.marker.visible and npc.marker.text == "!", "available quest has a world marker")
	check(game.nearest_interactable() != npc, "distant NPC cannot be interacted with")
	npc.interact(game)
	check(not game.dialogue_open(), "direct distant interaction also refuses conversation")
	game.player.global_position = npc.global_position + Vector3(0, .03, 1.25)
	game.player.velocity = Vector3.ZERO
	await ticks(28)
	check(game.nearest_interactable() == npc, "village approach selects the nearby NPC")
	await shot("01-warden")
	await key(KEY_F)
	check(game.dialogue_open() and paused and game.paused, "F starts conversation and pauses the gameplay world")
	check(game.ui_pointer_blocked and game.player.input_router.held.is_empty(), "conversation clears held combat input and captures pointer")
	check(game.dialogue_panel.body.text.contains("角色书页"), "civilian dialogue is rendered in the real panel")
	check(not game.begin_dialogue(npc.definition), "duplicate conversation is refused")
	await key(KEY_J)
	check(app.ui.panel.is_empty() and game.dialogue_open(), "journal shortcut does not open a second modal over dialogue")
	await key(KEY_ESCAPE)
	check(not game.dialogue_open() and not paused and not game.paused, "Esc closes conversation and resumes gameplay")
	check(app.ui.panel.is_empty(), "dialogue Esc does not also open settings")
	await key(KEY_F)
	await key(KEY_F)
	await key(KEY_F)
	check(not game.dialogue_open() and not paused, "F advances civilian dialogue to END without reopening it")
	check(game.player.progression.choose_career("warrior"), "player chooses a real starting career")
	await key(KEY_F)
	await key(KEY_F)
	check(game.dialogue_panel.choice_buttons.size() == 2, "quest offers real dialogue choices")
	await shot("02-patrol-offer")
	await key(KEY_ENTER)
	check(game.quests.status("village_patrol") == "active", "Enter accepts quest through the live dialogue bridge")
	check(not npc.marker.visible, "world marker updates when quest becomes active")
	await key(KEY_ESCAPE)
	var enemy: Node = game.combat_world.spawn_enemy("soldier", game.player.global_position + Vector3.RIGHT * 9)
	enemy.set_physics_process(false)
	enemy.combat.receive_damage({"formula": {"base": 999999}, "can_crit": false, "damage_type": "PHYSICAL"}, game.player, Vector3.FORWARD)
	await ticks(3)
	check(game.quests.status("village_patrol") == "ready" and npc.marker.visible and npc.marker.text == "?", "actual enemy defeat updates quest and NPC turn-in marker")
	var before: int = game.player.inventory.count("healing_potion")
	await key(KEY_F)
	await shot("03-patrol-ready")
	await key(KEY_ENTER)
	check(game.quests.status("village_patrol") == "rewarded", "live panel submits quest at the NPC")
	check(game.player.inventory.count("healing_potion") == before + 2, "NPC submission grants the actual reward once")
	check(npc.marker.visible and npc.marker.text == "!", "follow-up quest is now available at the same NPC")
	await key(KEY_ENTER)
	check(not game.dialogue_open(), "confirmation advances reward text to a clean close")
	game.player.combat.state = "STUN"
	check(not game.begin_dialogue(npc.definition), "incapacitated player cannot interrupt combat with conversation")
	game.player.combat.reset()
	await key(KEY_F)
	check(game.dialogue_open(), "conversation can reopen after combat state clears")
	app.queue_free()
	await ticks(4)
	check(not paused, "freeing an open conversation releases its gameplay pause")
	Preferences.settings_path = Preferences.DEFAULT_PATH
	print("NARRATIVE_WORLD ", checks - failures.size(), "/", checks, " passed")
	for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)
