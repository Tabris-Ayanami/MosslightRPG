extends SceneTree
const Preferences = preload("res://rpg/game_preferences.gd")
## End-to-end main-world RPG flow through actual actors, input, hits and rewards.
var game: Node
var player: Node
var checks := 0
var failures: Array[String] = []
var hits: Array[Dictionary] = []
var skills: Array[String] = []

func _initialize() -> void:
	call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func press(action: String, frames := 2) -> void:
	Input.action_press(action)
	await ticks(frames)
	Input.action_release(action)
	await ticks(2)
func settle() -> void:
	await ticks(90)
	player.combat.reset()
func dummy(at: Vector3, hp := 2000.0) -> Node:
	var enemy: Node = game.combat_world.spawn_enemy("soldier", at)
	enemy.resources.configure("HP", hp)
	enemy.ai_enabled = false
	enemy.set_physics_process(false)
	return enemy
func run() -> void:
	Preferences.settings_path = OS.get_temp_dir().path_join("mosslight-rpg-world-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()])
	root.size = Vector2i(1280, 720)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(20)
	player = game.player
	game.sound.muted = true
	check(game.rpg == player and not player.loadout.sandbox_mode, "main facade binds real normal-mode actor")
	check(player.combat.get_script() == preload("res://combat/combat_controller.gd"), "main uses shared combat controller")
	check(player.animation.get_script() == preload("res://combat/kirito_combat_visual.gd"), "main uses original Kirito combat adapter")
	check(player.find_children("*", "CollisionShape3D", false, false).size() == 1 and is_equal_approx(player.get_node("CollisionShape3D").shape.radius, .27), "main has one original-sized collision capsule and live components")
	check(player.loadout.level == 0 and player.inventory.item_ids().is_empty(), "new game starts before career choice without fake inventory")
	check(player.progression.choose_career("warrior"), "choose warrior through normal progression")
	check(player.loadout.level == 1 and player.resources.current("HP") == player.resources.max_value("HP"), "first career sets level and real full HP")
	check(player.inventory.count("magic_candy") == 0, "formal starter bag has no debug level candy")
	check(player.inventory.add_item("magic_candy", 9) and player.inventory.assign_quick_slot(3, "magic_candy"), "keyboard level-item fixture explicitly grants nine candies and assigns key four")
	check(player.loadout.sets[0].skills == ["", "", ""], "starter recommendations do not silently teach skills")
	check(not player.loadout.assign_skill(0, 0, "warrior_thrust"), "unlearned skill cannot be equipped")
	check(player.progression.learn_skill("warrior_thrust"), "learn eligible sword skill for free")
	check(player.loadout.assign_skill(0, 0, "warrior_thrust"), "learned skill equips into A Q")
	check(not player.progression.choose_career("rogue"), "cannot reset base career for repeat starter rewards")
	await ticks(3)
	for enemy in game.combat_world.enemies:
		enemy.set_physics_process(false)
	game.combat_world.encounters_started = true
	check(game.combat_world.enemies.size() == 1 and game.combat_world.enemies[0].enemy_id == "soldier", "chapter opening exposes only the starter soldier encounter")
	player.combat.damage_dealt.connect(func(result: Dictionary): hits.append(result))
	player.combat.skill_used.connect(func(id: String): skills.append(id))
	var start: Vector3 = player.global_position
	var enemy := dummy(start + Vector3.RIGHT * 1.5, 1.0)
	game.aim_override = enemy.global_position
	var xp: int = player.progression.experience
	var potions: int = player.inventory.count("healing_potion")
	await press("attack_primary")
	await ticks(35)
	check(enemy.combat.state == "DEAD" and not hits.is_empty(), "real left-click weapon hit kills actual enemy")
	check(player.progression.experience == xp + 40, "actual death grants configured experience")
	check(player.inventory.count("healing_potion") == potions + 1, "actual death grants owned potion loot")
	var after: Dictionary = player.inventory.stacks.duplicate(true)
	game.combat_world._enemy_defeated(enemy)
	check(player.progression.experience == xp + 40 and player.inventory.stacks == after, "same corpse death callback cannot grant rewards twice")
	await settle()
	var hp: float = player.resources.current("HP")
	potions = player.inventory.count("healing_potion")
	check(not player.combat.use_quick_item(0) and player.inventory.count("healing_potion") == potions, "full-health quick potion fails without consumption")
	player.health.receive(500)
	await press("quick_item_1")
	check(player.resources.current("HP") > hp - 500 and player.inventory.count("healing_potion") == potions - 1, "keyboard 1 heals and consumes exactly one real potion")
	check(not player.combat.use_quick_item(0) and player.inventory.count("healing_potion") == potions - 1, "item cooldown rejects repeat consumption")
	await settle()
	var bomb_target := dummy(player.global_position + Vector3.LEFT * 4)
	game.aim_override = bomb_target.global_position
	await ticks(2)
	var bombs: int = player.inventory.count("fire_bomb")
	check(player.inventory.use_item("fire_bomb"), "owned bomb enters the actual shared action runner")
	await ticks(40)
	check(bomb_target.resources.current("HP") < 2000 and player.inventory.count("fire_bomb") == bombs - 1, "bomb creates real area damage and consumes exactly one item")
	game.combat_world.enemies.erase(bomb_target)
	bomb_target.queue_free()
	game.weather.set_time(game.weather.TimeOfDay.DUSK)
	var physical := InputEventKey.new()
	physical.physical_keycode = KEY_4
	physical.pressed = true
	var level_before: int = player.loadout.level
	game.weather.set_weather(game.weather.Weather.LIGHT_RAIN)
	Input.parse_input_event(physical)
	await ticks(2)
	physical.pressed = false
	Input.parse_input_event(physical)
	await ticks(2)
	check(player.loadout.level == level_before + 1 and game.weather.weather_type == game.weather.Weather.LIGHT_RAIN, "physical number 4 uses candy without changing weather")
	physical.physical_keycode = KEY_1
	physical.alt_pressed = true
	physical.pressed = true
	potions = player.inventory.count("healing_potion")
	Input.parse_input_event(physical)
	await ticks(2)
	physical.pressed = false
	Input.parse_input_event(physical)
	await ticks(2)
	check(game.weather.time_of_day == game.weather.TimeOfDay.DAY and player.inventory.count("healing_potion") == potions, "Alt-number changes preview without using an inventory item")
	game.weather.set_weather(game.weather.Weather.CLEAR)
	var candies: int = player.inventory.count("magic_candy")
	await press("quick_item_4")
	check(player.loadout.level == 3 and player.inventory.count("magic_candy") == candies - 1, "keyboard 4 consumes candy and raises level exactly once")
	check(player.progression.experience == xp + 40, "candy preserves accumulated non-cap experience")
	check(player.progression.choose_career("swordsman"), "level two unlocks legal swordsman advancement")
	check(not player.progression.choose_career("dual_swordsman"), "dual career rejects advancement below level ten")
	while player.loadout.level < 10:
		check(player.inventory.use_item("magic_candy"), "owned candy progresses toward level ten")
	player.inventory.add_item("magic_candy")
	candies = player.inventory.count("magic_candy")
	check(not player.inventory.use_item("magic_candy") and player.inventory.count("magic_candy") == candies, "max-level candy is not consumed")
	check(player.progression.choose_career("dual_swordsman"), "level ten advances to dual swordsman")
	check(player.loadout.is_dual_wielding() and player.inventory.count(player.loadout.sets[1].weapon) > 0, "dual swords are both owned and held")
	check(player.loadout.sets[0].skills[0] == "warrior_thrust", "advancement preserves previously learned and equipped Q")
	check(player.progression.learn_skill("warrior_whirlwind") and player.loadout.assign_skill(1, 0, "warrior_whirlwind"), "learn and assign distinct B-group skill")
	player.restore(game.checkpoint)
	var left: Vector3 = player.global_position + Vector3.RIGHT * 2.4
	enemy = dummy(left)
	game.aim_override = enemy.global_position
	game.combat_world.locked_target = enemy
	hits.clear()
	skills.clear()
	await press("skill_q")
	await ticks(45)
	check(skills == ["warrior_thrust"], "real A Q dispatches one parent learned skill")
	check(hits.size() == 2, "main thrust produces two actual blade hits")
	check(player.global_position.distance_to(game.checkpoint) < 2.5, "dual thrust displacement is not repeated")
	await settle()
	await press("switch_combat_set")
	check(player.loadout.current_set == 1 and player.loadout.is_dual_wielding(), "Shift changes skill group while retaining both swords")
	enemy.global_position = player.global_position + Vector3.RIGHT * 1.3
	hits.clear()
	skills.clear()
	await press("skill_q")
	await ticks(60)
	check(skills == ["warrior_whirlwind"] and hits.size() == 2, "real B Q executes two spin hits with one parent cast")
	await settle()
	var serial: int = player.combat.serial
	game.ui_pointer_blocked = true
	await press("attack_primary")
	check(player.combat.serial == serial and player.combat.charge_button.is_empty(), "HUD pointer block prevents world attacks")
	game.ui_pointer_blocked = false
	game._focus_lost()
	check(player.input_router.held.is_empty(), "focus loss clears real input state")
	var owned: Dictionary = player.inventory.stacks.duplicate(true)
	var learned: Array = player.loadout.learned_skills.duplicate()
	player.health.receive(player.resources.max_value("HP") * 2)
	check(player.dead, "main shared health can kill the player")
	await ticks(160)
	check(not player.dead and player.resources.current("HP") > 0, "main death timer restores player through shared reset")
	check(player.inventory.stacks == owned and player.loadout.learned_skills == learned and player.loadout.level == 10, "respawn preserves owned items, learned skills and level")
	var projectile := preload("res://combat/attack_instance.gd").new()
	projectile.arena = game.combat_world
	projectile.source = enemy
	projectile.action = {"id":"old_life_projectile", "targeting":"DIRECTION", "projectile_speed":1, "range":100, "formula":{"base":10}, "damage_type":"PHYSICAL"}
	projectile.origin = player.global_position + Vector3.UP * 5
	projectile.direction = Vector3.RIGHT
	game.fx.add_child(projectile)
	game.respawn()
	check(projectile.is_queued_for_deletion() and not projectile.is_physics_processing(), "respawn retires previous-life attack volumes before restoring the player")
	check(not game.hud.visible and game.post_material.shader.resource_path == "res://shaders/reference_outline.gdshader", "main frontend/debug visibility and original outline pipeline remain intact")
	game._release_actions()
	game.queue_free()
	await ticks(3)
	print("RPG_WORLD: %d checks; %d failures" % [checks, failures.size()])
	for label in failures: printerr("FAIL: ", label)
	quit(0 if failures.is_empty() else 1)

