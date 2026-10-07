extends SceneTree
## Uses the vendored upstream compiler/runtime and real main-world RPG services.
const Bridge = preload("res://rpg/dialogue_bridge.gd")
const Compiler = preload("res://addons/dialogue_manager/compiler/compiler.gd")
const Repository = preload("res://rpg/save_repository.gd")
var game: Node
var manager: Node
var resource: Resource
var bridge: RefCounted
var checks := 0
var failures: Array[String] = []
var workspace := ""

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
	print("PASS " if ok else "FAIL ", message)

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func line_at(key: String = "start") -> Variant:
	return await manager.get_next_dialogue_line(resource, key, [bridge])

func choose(text: String) -> Variant:
	var line: Variant = await line_at()
	for i in range(12):
		if line == null: break
		if not line.responses.is_empty():
			for response in line.responses:
				if response.is_allowed and str(response.text).contains(text):
					return await line_at(response.next_id)
			break
		line = await line_at(line.next_id)
	check(false, "dialogue exposes expected allowed choice: " + text)
	return null

func defeat(id: String) -> void:
	var enemy: Node = game.combat_world.spawn_enemy(id, game.player.global_position + Vector3.RIGHT * 8)
	enemy.set_physics_process(false)
	var kills: int = game.player.progression.enemy_kills.get(id, 0)
	# Legacy files may contain a process ID reused by this fresh spawned life.
	game.player.progression.claimed_rewards[str(enemy.get_instance_id())] = true
	enemy.combat.receive_damage({"formula": {"base": 999999}, "can_crit": false, "damage_type": "PHYSICAL"}, game.player, Vector3.FORWARD)
	check(enemy.combat.state == "DEAD", "actual enemy death: " + id)
	check(game.player.progression.enemy_kills.get(id, 0) == kills + 1, "legacy process ID receipt does not suppress a fresh defeat reward: " + id)
	var state: Dictionary = game.world_state.export_state()
	var inventory: Dictionary = game.player.inventory.export_state()
	game.combat_world._enemy_defeated(enemy)
	check(game.world_state.export_state() == state and game.player.inventory.export_state() == inventory and game.player.progression.enemy_kills.get(id, 0) == kills + 1, "same spawned life cannot count or reward twice: " + id)

func run() -> void:
	create_timer(45, true).timeout.connect(func():
		printerr("Dialogue runtime test timed out")
		quit(1))
	manager = root.get_node("DialogueManager")
	check(manager != null, "pinned Dialogue Manager autoload is available")
	var source := FileAccess.get_file_as_string("res://data/dialogue/village_warden.dialogue")
	var result: Variant = Compiler.compile_string(source, "res://data/dialogue/village_warden.dialogue")
	check(result.errors.is_empty(), "actual Chinese prologue dialogue passes upstream compiler")
	if not result.errors.is_empty():
		print(result.errors)
		quit(1)
		return
	var invalid: Variant = Compiler.compile_string("~ start\n=> missing_title\n", "")
	check(not invalid.errors.is_empty(), "upstream compiler rejects a missing dialogue target")
	resource = manager.create_resource_from_text(source)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(30)
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	bridge = Bridge.new()
	bridge.setup(game)
	var line: Variant = await line_at()
	check(line != null and str(line.text).contains("角色书页"), "civilian gets preparation guidance instead of an unusable reward")
	check(game.player.progression.choose_career("warrior"), "real player chooses career")
	defeat("soldier")
	check(game.world_state.get_event_count("enemy_defeated", "soldier") == 1, "combat death reaches game-owned persistent event stream")
	line = await choose("我去看看")
	check(line != null and bridge.last_operation_ok and game.quests.status("village_patrol") == "active", "dialogue choice accepts actual quest")
	check(game.quests.objective_progress("village_patrol")[0].current == 0, "earlier kills do not complete newly accepted patrol")
	line = await line_at()
	check(line != null and str(line.text).contains("小路"), "in-progress dialogue gives directions")
	defeat("soldier")
	check(game.quests.status("village_patrol") == "ready", "new actual combat death completes patrol objective")
	workspace = OS.get_temp_dir().path_join("mosslight-dialogue-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var repo := Repository.new(workspace)
	var created: Dictionary = repo.create("艾琳的委托")
	check(created.ok, "isolated named adventure is created")
	var saved: Dictionary = repo.save(created.slot, "艾琳的委托", game.player, game)
	check(saved.ok, "ready quest and player save together")
	var potions: int = game.player.inventory.count("healing_potion")
	line = await choose("汇报巡路")
	check(line != null and bridge.last_operation_ok and game.quests.status("village_patrol") == "rewarded", "dialogue submits patrol and grants reward")
	check(game.player.inventory.count("healing_potion") == potions + 2, "dialogue reward reaches actual inventory exactly once")
	potions = game.player.inventory.count("healing_potion")
	check(not bridge.claim_quest("village_patrol") and game.player.inventory.count("healing_potion") == potions, "repeated dialogue mutation cannot duplicate reward")
	line = await choose("清查林中")
	check(line != null and bridge.last_operation_ok and game.quests.status("forest_investigation") == "active", "rewarded prerequisite unlocks follow-up dialogue and quest")
	defeat("heavy_guard")
	check(game.quests.status("forest_investigation") == "active", "one of two follow-up objectives is insufficient")
	defeat("ogre")
	check(game.quests.status("forest_investigation") == "ready", "both real enemy types advance follow-up quest")
	line = await choose("汇报调查")
	check(line != null and bridge.last_operation_ok and game.quests.status("forest_investigation") == "rewarded", "follow-up dialogue reaches completed state")
	line = await line_at()
	check(line != null and str(line.text).contains("重新通了"), "completed story uses its distinct final branch")
	check(await line_at(line.next_id) == null, "upstream runtime terminates dialogue normally")
	var completed: Dictionary = repo.save(created.slot, "艾琳的委托", game.player, game)
	check(completed.ok, "completed quests are accepted by full save validation")
	var another: Dictionary = repo.create("另一位旅人")
	check(repo.restore(another.snapshot, game.player, game).ok and game.quests.status("village_patrol") == "available", "switching adventures clears previous conversation quest state")
	line = await line_at()
	check(line != null and str(line.text).contains("角色书页"), "same bridge now observes new adventure's player state")
	check(repo.restore(completed.snapshot, game.player, game).ok, "returning to completed adventure restores player and quests")
	line = await line_at()
	check(line != null and str(line.text).contains("重新通了"), "dialogue branches correctly after save/restore")
	var corrupt: Dictionary = completed.snapshot.duplicate(true)
	corrupt.world_state.objects["quest.village_patrol"].status = "invented_status"
	var before: Dictionary = game.world_state.export_state()
	check(not repo.restore(corrupt, game.player, game).ok and game.world_state.export_state() == before, "invalid quest semantics rejected before game mutation")
	check(resource.lines.values().all(func(entry: Dictionary): return not entry.has("resource")), "runtime does not insert self-references into compiled dialogue data")
	var released: WeakRef = weakref(resource)
	bridge.game = null
	line = null
	result = null
	invalid = null
	bridge = null
	resource = null
	await ticks(2)
	check(released.get_ref() == null, "completed conversation releases its dialogue resource")
	game.queue_free()
	await ticks(4)
	var safe_root := OS.get_temp_dir().simplify_path().replace("\\", "/").trim_suffix("/") + "/"
	if workspace.simplify_path().replace("\\", "/").begins_with(safe_root) and workspace.get_file().begins_with("mosslight-dialogue-"):
		var directory := DirAccess.open(workspace)
		for file in directory.get_files(): DirAccess.remove_absolute(workspace.path_join(file))
		DirAccess.remove_absolute(workspace)
	print("DIALOGUE_RUNTIME ", checks - failures.size(), "/", checks, " passed")
	quit(0 if failures.is_empty() else 1)
