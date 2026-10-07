extends SceneTree
## Real scene actors, faction-filtered damage and physical InputMap control leases.
var arena: Node
var player: Node
var checks := 0
var failures: Array[String] = []
var starts: Dictionary = {}
var dealt: Array[Dictionary] = []

func _initialize() -> void:
	preload("res://rpg/game_preferences.gd").settings_path = OS.get_environment("TEMP").path_join("mosslight_unit_control_%d.cfg" % OS.get_process_id())
	call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)
func mouse(down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = down
	event.position = Vector2(640, 300)
	event.global_position = event.position
	Input.parse_input_event(event)
func observe(actor: Node) -> void:
	var id := actor.get_instance_id()
	starts[id] = []
	actor.combat.runner.action_started.connect(func(action: Dictionary): starts[id].append(action.get("id", "")))
func spawn(id: String, at: Vector3) -> Node:
	var actor: Node = arena.spawn_enemy(id, at)
	actor.ai_enabled = false
	observe(actor)
	return actor
func release_inputs() -> void:
	key(KEY_W, false)
	key(KEY_A, false)
	mouse(false)
	for action in InputMap.get_actions(): Input.action_release(action)
func park_others() -> void:
	for actor in arena.units():
		if actor != player and actor.combat.state != "DEAD":
			actor.ai_enabled = false
			actor.global_position = Vector3(18, .05, -20)
			actor.velocity = Vector3.ZERO

func run() -> void:
	root.size = Vector2i(1280, 720)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	arena.player_visual_script = preload("res://combat/animation_controller.gd")
	root.add_child(arena)
	current_scene = arena
	await ticks(4)
	player = arena.player
	arena.sound.muted = true
	arena.ui.toggle_menu(false)
	arena.input_blocked = false
	arena.pointer_blocked = false
	park_others()
	observe(player)
	player.loadout.select_career("warrior")
	player.combat.reset()
	player.global_position = Vector3(0, .05, 8)
	var soldier := spawn("soldier", Vector3(0, .05, 5))
	var victim := spawn("soldier", Vector3(0, .05, 3))
	var ally := spawn("heavy_guard", Vector3(8, .05, 8))
	ally.faction_id = "heroes"
	ally.refresh_collision_layer()
	var neutral := spawn("fire_elemental", Vector3(-8, .05, 8))
	neutral.faction_id = "villagers"
	neutral.refresh_collision_layer()
	for actor in [player, soldier, ally, neutral]:
		var complete := true
		for field in ["stats", "resources", "health", "loadout", "inventory", "progression", "combat", "input_router", "hurtbox", "brain", "form"]:
			complete = complete and actor.get(field) != null
		check(complete, actor.definition_id + ": player and monster instantiate all common components")
	check(player.brain.get_script() == soldier.brain.get_script() and player.combat.get_script() == soldier.combat.get_script() and player.loadout.get_script() == soldier.loadout.get_script(), "protagonist and monsters use identical brain/controller/loadout implementations")
	check(soldier.resources.max_value("HP") == 1200 and soldier.resources.max_value("Qi") == 0 and ally.resources.max_value("HP") == 1800 and neutral.race_id == "elemental", "shared component creation preserves each unit's native resources and identity")
	check(arena.targets_for(player).has(soldier) and not arena.targets_for(player).has(ally) and not arena.targets_for(player).has(neutral) and not arena.targets_for(player).has(player), "target lists exclude self, allies and neutral factions")
	check(not arena.targets_for(soldier).has(victim) and arena.targets_for(soldier).has(player), "monster targeting follows factions rather than enemy-array membership")
	arena.set_faction_relation("heroes", "villagers", true)
	check(arena.targets_for(player).has(neutral) and arena.targets_for(neutral).has(player), "explicit faction hostility is symmetric")
	arena.set_faction_relation("heroes", "villagers", false)
	var ally_hp: float = ally.resources.current("HP")
	var neutral_hp: float = neutral.resources.current("HP")
	var packet: Dictionary = player.action_for("PRIMARY_TAP")
	var friendly_result: Dictionary = player.combat.hit_target(ally, packet, Vector3.RIGHT)
	var neutral_result: Dictionary = player.combat.hit_target(neutral, packet, Vector3.LEFT)
	check(friendly_result.get("blocked", false) and neutral_result.get("blocked", false) and ally.resources.current("HP") == ally_hp and neutral.resources.current("HP") == neutral_hp, "real hurtbox rejects friendly and neutral damage without HP loss")
	var direct_result: Dictionary = ally.hurtbox.receive(packet, player, Vector3.RIGHT)
	check(direct_result.get("blocked", false) and ally.resources.current("HP") == ally_hp, "direct hurtbox entry also rejects same-faction damage")
	await ticks(6) # Settle fresh capsules before comparing physical movement.
	player.resources.change("HP", -200)
	soldier.resources.change("HP", -137)
	var owner_hp: float = player.resources.current("HP")
	var owned_hp: float = soldier.resources.current("HP")
	var original_faction: String = soldier.faction_id
	check(arena.control.possess(soldier, 0), "shared service possesses a live hostile unit")
	check(player.is_player and not soldier.is_player and player.control_mode == "none" and soldier.control_mode == "human" and arena.controlled_actor() == soldier, "possession changes controller independently from protagonist identity")
	check(not player.input_router.is_physics_processing() and soldier.input_router.is_physics_processing() and soldier.faction_id == player.faction_id, "exactly the possessed body's input router is active and it joins owner faction")
	var owner_position: Vector3 = player.global_position
	var controlled_position: Vector3 = soldier.global_position
	key(KEY_W, true)
	await ticks(12)
	key(KEY_W, false)
	await ticks(2)
	print("CONTROL_MOVE_TRACE ", JSON.stringify({"target_delta": soldier.global_position - controlled_position, "owner_delta": player.global_position - owner_position}))
	check(soldier.global_position.distance_to(controlled_position) > .25 and player.global_position.distance_to(owner_position) < .04, "physical W moves possessed body while parked owner stays still")
	soldier.global_position = Vector3(0, .05, 5)
	soldier.velocity = Vector3.ZERO
	arena.locked_target = victim
	arena.aim_override = victim.global_position
	arena.aim_point = victim.global_position
	var victim_hp: float = victim.resources.current("HP")
	var owner_starts: int = starts[player.get_instance_id()].size()
	mouse(true)
	await ticks(2)
	mouse(false)
	await ticks(100)
	check(starts[soldier.get_instance_id()] == ["soldier_attack"] and starts[player.get_instance_id()].size() == owner_starts, "physical mouse dispatches exactly one natural attack on the possessed body only")
	check(victim.resources.current("HP") < victim_hp and player.resources.current("HP") == owner_hp and soldier.resources.current("HP") == owned_hp, "possessed natural attack actually damages its new enemy and never heals either body")
	arena.control.release()
	check(arena.controlled_actor() == player and player.is_human_controlled() and soldier.control_mode == "ai" and soldier.faction_id == original_faction and player.input_router.is_physics_processing() and not soldier.input_router.is_physics_processing(), "manual release restores both original controllers, faction and input ownership")
	check(player.resources.current("HP") == owner_hp and soldier.resources.current("HP") == owned_hp, "manual release preserves wounded HP exactly")
	check(arena.control.possess(soldier, .15), "timed possession starts through the same service")
	soldier.resources.change("HP", -7)
	owned_hp -= 7
	await ticks(13)
	check(arena.controlled_actor() == player and soldier.control_mode == "ai" and soldier.faction_id == original_faction and soldier.resources.current("HP") == owned_hp, "timed expiry restores controllers/faction without health reset")
	check(arena.control.possess(soldier, 30), "possession can be established for target-death lifecycle")
	soldier.health.receive(100000)
	await ticks(3)
	check(arena.controlled_actor() == player and player.is_human_controlled() and soldier.combat.state == "DEAD" and soldier.resources.current("HP") == 0 and soldier.collision_layer == 0, "possessed target death returns input and preserves actual death state")
	var removed := spawn("fire_elemental", Vector3(7, .05, 6))
	check(arena.control.possess(removed, 30), "possession starts before target is removed from scene")
	removed.queue_free()
	await ticks(4)
	check(arena.controlled_actor() == player and player.is_human_controlled() and player.resources.current("HP") == owner_hp, "deleted possessed node returns input without invalid access or healing")
	var survivor := spawn("soldier", Vector3(7, .05, 6))
	survivor.resources.change("HP", -99)
	check(arena.control.possess(survivor, 30), "possession starts before original-body death")
	player.health.receive(100000)
	await ticks(3)
	check(arena.controlled_actor() == player and player.combat.state == "DEAD" and player.resources.current("HP") == 0 and survivor.control_mode == "ai" and survivor.faction_id == "hostiles" and survivor.resources.current("HP") == 1101, "owner death releases remote body and does not resurrect or refill either unit")
	check(not arena.control.possess(survivor, 1) and not arena.control.autopilot(player, 1), "dead original body cannot begin another possession or autopilot")
	# Fresh live encounter for actual protagonist AI, using the same UnitBrain.
	player.combat.reset()
	player.ai_enabled = true
	player.global_position = Vector3(0, .05, 6)
	player.velocity = Vector3.ZERO
	park_others()
	victim = spawn("soldier", Vector3(0, .05, 4.5))
	player.ai_cooldown = 0
	player.resources.change("HP", -175)
	owner_hp = player.resources.current("HP")
	victim_hp = victim.resources.current("HP")
	player.combat.damage_dealt.connect(func(result: Dictionary): dealt.append(result))
	check(arena.control.autopilot(player, 1.8), "berserk lease delegates protagonist to the shared UnitBrain")
	check(player.control_mode == "ai" and not player.input_router.is_physics_processing() and player.brain.aggressive, "berserk switches intent source to AI and disables human input router")
	await ticks(65)
	check(not dealt.is_empty() and victim.resources.current("HP") < victim_hp and player.is_player, "same AI brain starts a real protagonist attack that hits a hostile unit")
	await ticks(48)
	check(player.is_human_controlled() and not player.brain.aggressive and player.input_router.is_physics_processing() and player.resources.current("HP") == owner_hp, "berserk expiry restores human input and original aggression without healing")
	check(arena.control.autopilot(player, 20), "long berserk lease can start for manual cancellation")
	arena.control.stop_autopilot(player)
	check(player.is_human_controlled() and not player.brain.aggressive and player.resources.current("HP") == owner_hp, "manual berserk release restores original controller without health reset")
	arena.control.autopilot(player, 20)
	player.health.receive(100000)
	await ticks(3)
	check(player.control_mode == "human" and player.combat.state == "DEAD" and player.resources.current("HP") == 0 and not player.brain.aggressive, "berserk death cancels AI lease while keeping the original body dead")
	release_inputs()
	print("UNIT_CONTROL_RESULT checks=", checks, " failures=", failures.size())
	arena.queue_free()
	await ticks(2)
	quit(1 if not failures.is_empty() else 0)
