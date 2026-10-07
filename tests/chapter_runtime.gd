extends SceneTree
## Real App/map/quests/lives/save recovery. Rules use actual lethal damage;
## route coverage walks actual static colliders with the shared ogre actor.
## This does not claim that all careers or boss difficulty are balanced.
const Preferences = preload("res://rpg/game_preferences.gd")
const Compiler = preload("res://addons/dialogue_manager/compiler/compiler.gd")
const Bridge = preload("res://rpg/dialogue_bridge.gd")
const SOLDIER := "encounter.forest.soldier_01"
const HEAVY := "encounter.forest.heavy_guard_01"
const OGRE := "encounter.forest.ogre_01"
const FIRE := "encounter.forest.fire_elemental_01"
var app: Node
var game: Node
var checks := 0
var failures: Array[String] = []
var temp := ""
var initial: Dictionary = {}
var final_snapshot: Dictionary = {}
func _initialize() -> void:
	temp = OS.get_temp_dir().path_join("mosslight-chapter-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	Preferences.settings_path = temp.path_join("preferences.cfg")
	call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func ticks(count: int) -> void:
	for _i in range(count):
		await physics_frame
		await process_frame
func freeze() -> void:
	game.player.set_physics_process(false)
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
func body(id: String) -> Node: return game.combat_world._encounter_nodes.get(id)
func kill(enemy: Node) -> void:
	enemy.combat.receive_damage({"formula": {"base": 1000000}, "can_crit": false, "damage_type": "PHYSICAL"}, game.player, Vector3.FORWARD)
func at(point: Vector3) -> Vector3: return game.reference_map.to_global(point)
func walk_protagonist() -> void:
	# Continuous actual movement from the saved arrival, with no teleports between
	# segments. This follows the visible path around the garden shrine.
	game.player.set_control_mode("human")
	game.player.set_physics_process(true)
	var arrived := true
	var dry := true
	for point: Vector2 in [Vector2(.5, -3.8), Vector2(.5, -8.5), Vector2(0, -12), Vector2(0, -26), Vector2(-2.8, -31.2)]:
		var target := at(Vector3(point.x, 2.3, point.y))
		for _frame in range(900):
			game._release_actions()
			var offset: Vector3 = target - game.player.global_position
			offset.y = 0
			if offset.length() < .32: break
			var direction := offset.normalized()
			var horizontal: float = direction.dot(game.camera_right())
			var vertical: float = direction.dot(game.camera_forward())
			Input.action_press("move_right" if horizontal >= 0 else "move_left", absf(horizontal))
			Input.action_press("move_up" if vertical >= 0 else "move_down", absf(vertical))
			await ticks(1)
			if game.player.global_position.y < 1.1: dry = false
		game._release_actions()
		var remaining: Vector3 = target - game.player.global_position
		remaining.y = 0
		if remaining.length() >= .4:
			arrived = false
			print("PROTAGONIST_ROUTE_BLOCKED ", game.reference_map.to_local(game.player.global_position), " toward ", point)
			break
	check(arrived, "real protagonist continuously walks from Lv0 arrival to village warden")
	check(dry, "actual garden and north-bridge walk stays on land")
	game.player.set_physics_process(false)
func walk(start: Vector3, target: Vector3, label: String, via: Array[Vector3] = []) -> void:
	# Shared actors intentionally stop while the real protagonist is frozen.
	# Keep the protagonist active, with input disabled, while probing traversal.
	game.player.set_control_mode("none")
	game.player.set_physics_process(true)
	var template: Dictionary = preload("res://combat/unit_definition.gd").for_enemy(game.combat_world.database, "ogre")
	# Neutral to all combatants, so the route probe uses return-home navigation.
	# Only test movement speed changes; body, steps, gravity and movement are real.
	template.faction_id = "chapter_route_probe"
	template.movement.speed = 5.2
	var walker: Node = game.combat_world.spawn_unit(template, at(start))
	var fell := false
	var reachable := true
	var route: Array[Vector3] = via.duplicate()
	route.append(target)
	for point in route:
		walker.spawn_point = at(point)
		reachable = reachable and game.world_navigation.is_reachable(walker.global_position, walker.spawn_point)
		for _frame in range(1800):
			await physics_frame
			if walker.global_position.y < 1.1: fell = true
			if Vector2(walker.global_position.x - walker.spawn_point.x, walker.global_position.z - walker.spawn_point.z).length() < .65: break
		if Vector2(walker.global_position.x - walker.spawn_point.x, walker.global_position.z - walker.spawn_point.z).length() >= .75: break
	check(reachable, label + " has connected navigation segments")
	var remaining := Vector2(walker.global_position.x - walker.spawn_point.x, walker.global_position.z - walker.spawn_point.z).length()
	if remaining >= .75 and walker.get_last_slide_collision() != null:
		print("ROUTE_BLOCKER ", walker.get_last_slide_collision().get_collider().get_path())
	check(remaining < .75 and not fell, label + " shared actor arrives on land (%.2fm, at %s)" % [remaining, game.reference_map.to_local(walker.global_position)])
	game.world_navigation.forget(walker)
	walker.queue_free()
	await ticks(2)
	game.player.set_physics_process(false)
	game.player.set_control_mode("human")
func run() -> void:
	create_timer(180, true).timeout.connect(func(): printerr("CHAPTER_RUNTIME timeout"); quit(1))
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = app.SAVE_REPOSITORY.new(temp.path_join("adventures"))
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	var created: Dictionary = app.saves.create("风铃归途测试", 0)
	check(created.ok, "new named adventure is created only in OS-temp")
	initial = created.snapshot.duplicate(true)
	app.selected_save = 0
	app.selected_name = initial.name
	app.pending_snapshot = initial.duplicate(true)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	game = app.game
	var global_ogre: Dictionary = game.combat_world.database.enemies.ogre.duplicate(true)
	game.sound.muted = true
	check(game.player.loadout.level == 0 and app.ui.career_picker and app.ui.panel == "character", "real Lv0 arrival opens the existing career page")
	app.ui.close_panel(true)
	await ticks(8)
	freeze()
	check(is_instance_valid(body(SOLDIER)) and not is_instance_valid(body(HEAVY)) and not is_instance_valid(body(OGRE)) and not is_instance_valid(body(FIRE)), "new arrival exposes only the introductory encounter")
	check(game.player.progression.choose_career("warrior") and game.player.loadout.level == 1 and game.player.inventory.count("magic_candy") == 0, "formal career choice grants Lv1 equipment without debug candy")
	check(game.player.loadout.learned_skills.is_empty(), "career recommendations do not silently teach skills")
	check(game.player.progression.learn_skill("warrior_thrust") and game.player.loadout.assign_skill(0, 0, "warrior_thrust"), "real learning and preparation APIs make the tutorial skill usable")
	var deadline := Time.get_ticks_msec() + 5000
	while not game.world_navigation.navigation_ready() and Time.get_ticks_msec() < deadline: await physics_frame
	check(game.world_navigation.navigation_ready(), "actual map navigation has published")
	var boss_point: Array = game.encounters.definition(OGRE).position
	var destination := Vector3(boss_point[0], boss_point[1], boss_point[2])
	await walk_protagonist()
	await walk(Vector3(11, 2.3, 1.7), Vector3(27, 2.3, -2), "east bridge to introductory forest")
	await walk(Vector3(27, 2.3, -2), destination, "forest path to isolated final clearing")
	check(destination.distance_to(Vector3(29, 2.4, -4)) > 24 and destination.distance_to(Vector3(30, 2.4, -15)) > 12, "final clearing is outside the introductory fight and guard unlock radius")
	if "--route-only" in OS.get_cmdline_user_args():
		await finish()
		return
	var source := FileAccess.get_file_as_string("res://data/dialogue/village_warden.dialogue")
	var compiled: Variant = Compiler.compile_string(source, "res://data/dialogue/village_warden.dialogue")
	check(compiled.errors.is_empty(), "chapter dialogue passes the pinned upstream compiler")
	var manager: Node = root.get_node("DialogueManager")
	var resource: Resource = load("res://data/dialogue/village_warden.dialogue")
	var bridge := Bridge.new()
	bridge.setup(game)
	check(bridge.accept_quest("village_patrol"), "dialogue bridge accepts actual first commission")
	var soldier: Node = body(SOLDIER)
	kill(soldier)
	check(game.quests.status("village_patrol") == "ready" and game.player.progression.experience == 40, "actual introductory death records its quest event and 40 XP")
	check(bridge.claim_quest("village_patrol") and game.player.loadout.level == 2 and game.player.progression.experience == 0, "first actual report reaches exactly Lv2 without debug levels")
	game.combat_world._tick_encounters(0)
	check(is_instance_valid(body(FIRE)) and not is_instance_valid(body(HEAVY)) and not is_instance_valid(body(OGRE)), "first reward opens optional fire encounter, not final challenge")
	check(bridge.accept_quest("forest_investigation"), "second commission unlocks through its existing prerequisite")
	game.combat_world._tick_encounters(0)
	freeze()
	check(is_instance_valid(body(HEAVY)) and not is_instance_valid(body(OGRE)), "newly eligible alive guard is reconciled without a cooldown record")
	var midway: Dictionary = app.saves.save(0, initial.name, game.player, game)
	check(midway.ok, "mid-chapter progress saves with original stable IDs")
	check(app.saves.restore(midway.snapshot, game.player, game).ok and is_instance_valid(body(HEAVY)) and not is_instance_valid(body(OGRE)), "mid-chapter restore respects the same encounter gates")
	freeze()
	var qi_before: int = game.player.inventory.count("qi_potion")
	game.player.inventory.stacks.qi_potion = 1000000
	kill(body(HEAVY))
	check(game.encounters.record(HEAVY).phase == "pending" and not game.chapter.objective_complete("forest_investigation", "break_guard") and not game.chapter.encounter_enabled(OGRE), "unpaid guard death cannot unlock the final challenge")
	var pending_guard: Dictionary = app.saves.save(0, initial.name, game.player, game)
	check(pending_guard.ok and app.saves.restore(pending_guard.snapshot, game.player, game).ok and game.encounters.record(HEAVY).phase == "pending" and not is_instance_valid(body(OGRE)), "guard reward pending survives real disk save and restore with boss still locked")
	freeze()
	game.player.inventory.stacks.qi_potion = qi_before
	game.combat_world._retry_pending()
	check(game.encounters.record(HEAVY).phase == "cooldown" and game.chapter.objective_complete("forest_investigation", "break_guard") and game.player.progression.experience == 70, "settling guard loot unlocks chapter objective and XP together exactly once")
	game.player.global_position = at(destination)
	game.combat_world._tick_encounters(0)
	var arriving_boss: Node = body(OGRE)
	check(is_instance_valid(arriving_boss) and game.combat_world._safe_position(arriving_boss.global_position, 12) and game.encounters.record(OGRE).generation == 1, "boss unlock uses a distant entry when hero occupies its clearing")
	game.player.global_position = at(Vector3(1.6, 2.35, 4.8))
	var possessed: Node = body(FIRE)
	possessed.global_position = at(destination)
	check(game.combat_world.control.possess(possessed, 100), "possess actual optional encounter beside final clearing")
	game.combat_world._tick_encounters(0)
	check(is_instance_valid(arriving_boss) and body(OGRE) == arriving_boss and game.combat_world._safe_position(arriving_boss.global_position, 12) and game.encounters.record(OGRE).generation == 1, "existing arrival stays distant from possessed body without a duplicate generation")
	game.combat_world.control.release()
	possessed.global_position = possessed.spawn_point
	game.combat_world._tick_encounters(0)
	freeze()
	var boss: Node = body(OGRE)
	check(is_instance_valid(boss) and boss.loadout.level == 3 and boss.enemy_id == "ogre" and boss in game.combat_world.enemies and boss in game.combat_world.units(), "chapter boss uses its level profile with all shared combat registrations")
	check(game.combat_world.database.enemies.ogre == global_ogre, "chapter spawn does not rewrite the global ogre template")
	var before_death: Dictionary = game.player.progression.export_state()
	var items_before_death: Dictionary = game.player.inventory.export_state()
	game.player.combat.receive_damage({"formula": {"base": 1000000}, "can_crit": false, "damage_type": "PHYSICAL"}, boss, Vector3.FORWARD)
	check(game.player.combat.state == "DEAD" and game.death_time == 2.5, "actual player death schedules the existing checkpoint recovery")
	game.respawn()
	check(game.player.combat.state != "DEAD" and game.player.global_position == game.checkpoint and before_death == game.player.progression.export_state() and items_before_death == game.player.inventory.export_state(), "checkpoint recovery preserves chapter XP and inventory")
	check(game.encounters.record(OGRE).phase == "alive" and game.encounters.record(OGRE).generation == 1 and game.chapter.phase() == "final_challenge", "player death cannot reward or advance the final enemy life")
	var candy: int = game.player.inventory.count("magic_candy")
	var healing_before: int = game.player.inventory.count("healing_potion")
	game.player.inventory.stacks.healing_potion = 1000000
	kill(boss)
	check(game.encounters.record(OGRE).phase == "pending" and game.chapter.phase() == "final_challenge" and not game.quests.can_claim("forest_investigation").is_empty(), "unpaid boss death cannot finish the objective or pay chapter reward")
	game.combat_world._tick_encounters(90)
	check(game.encounters.record(OGRE).phase == "pending" and not is_instance_valid(body(OGRE)), "pending boss never respawns while waiting for inventory space")
	game.player.inventory.stacks.healing_potion = healing_before
	game.combat_world._retry_pending()
	check(game.quests.status("forest_investigation") == "ready" and game.chapter.phase() == "final_report" and game.player.inventory.count("magic_candy") == candy, "boss defeat awaits report and never grants a debug level")
	game.combat_world._tick_encounters(90)
	check(game.encounters.record(OGRE).phase == "cooldown" and game.encounters.record(OGRE).generation == 1 and not game.chapter.encounter_enabled(OGRE), "completed objective blocks next boss generation without changing legacy record shape")
	var awaiting_report: Dictionary = app.saves.save(0, initial.name, game.player, game)
	check(awaiting_report.ok and app.saves.restore(awaiting_report.snapshot, game.player, game).ok and not is_instance_valid(body(OGRE)), "paid final boss remains absent after saving and restoring before report")
	freeze()
	var warden: Node
	for npc in game.narrative_npcs:
		if npc.definition.id == "village_warden": warden = npc
	game.player.global_position = warden.global_position + Vector3.FORWARD * 1.5
	check(game.begin_dialogue(warden.definition, warden), "real nearby NPC opens imported final-report dialogue through gameplay checks")
	await ticks(8)
	game.dialogue_panel._choose(0)
	await ticks(8)
	check(game.chapter.is_complete() and game.player.loadout.level == 4 and game.player.progression.experience == 50, "actual final report choice completes chapter and reaches Lv4 plus 50 XP")
	game.dialogue_panel._typing.finish()
	game.dialogue_panel._activate()
	await ticks(8)
	check(game.dialogue_panel.body.get_parsed_text().contains(game.chapter.title()) and game.dialogue_panel.dialogue_line.responses.size() == 1, "actual conclusion displays authored chapter title and continue-exploring choice")
	if "--capture" in OS.get_cmdline_user_args():
		game.dialogue_panel._typing.finish()
		await ticks(20)
		await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png(temp.path_join("chapter-conclusion.png"))
		print("CHAPTER_CAPTURE ", temp.path_join("chapter-conclusion.png"))
	game.dialogue_panel._choose(0)
	await ticks(8)
	game.dialogue_panel._typing.finish()
	game.dialogue_panel._activate()
	await ticks(8)
	check(not game.dialogue_open() and not game.paused and not paused, "ending choice closes normally and returns to exploration")
	var inventory: Dictionary = game.player.inventory.export_state()
	var world: Dictionary = game.world_state.export_state()
	check(not bridge.claim_quest("forest_investigation") and inventory == game.player.inventory.export_state() and world == game.world_state.export_state(), "repeating chapter conclusion cannot duplicate any reward")
	var line: Variant = await manager.get_next_dialogue_line(resource, "start", [bridge])
	check(line != null and str(line.text).contains("已经完成"), "rewarded saves can revisit the authored chapter epilogue")
	final_snapshot = app.saves.save(0, initial.name, game.player, game).snapshot
	check(app.saves.restore(initial, game.player, game).ok and not game.chapter.is_complete() and not is_instance_valid(body(OGRE)), "another new adventure cannot inherit chapter completion or boss availability")
	check(app.saves.restore(final_snapshot, game.player, game).ok and game.chapter.is_complete() and not is_instance_valid(body(OGRE)), "restored completed chapter retains ending without replaying the boss")
	freeze()
	# Legacy in-progress save: final enemy killed before guard, old cooldown still
	# exists. Preserve its accepted-event baselines and allow the remaining guard.
	# Begin with actual paid kill records and inventory. Changing the acceptance
	# baseline models a guard killed before accepting this old investigation.
	var legacy: Dictionary = awaiting_report.snapshot.duplicate(true)
	legacy.world_state.objects["quest.forest_investigation"].baselines.break_guard = 1
	legacy.world_state.objects[OGRE] = {"version": 1, "generation": 1, "phase": "cooldown", "remaining": 17.0}
	var legacy_result: Dictionary = app.saves.restore(legacy, game.player, game)
	if not legacy_result.ok: print("LEGACY_FIXTURE_ERROR ", legacy_result.error)
	check(legacy_result.ok and not game.chapter.encounter_enabled(OGRE) and game.chapter.encounter_enabled(HEAVY) and game.encounters.record(OGRE).remaining == 17, "old out-of-order objectives and 45-second boss record remain compatible")
	check(app.saves.restore(final_snapshot, game.player, game).ok, "return to completed test adventure before clean exit")
	await finish()
func finish() -> void:
	app.queue_free()
	await ticks(4)
	print("CHAPTER_RUNTIME %d/%d passed; isolated=%s" % [checks - failures.size(), checks, temp])
	for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)
