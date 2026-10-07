extends SceneTree
## Real frontend book callbacks must manage the character while world input stays
## paused. Preferences/saves are isolated from the player's data.
const Preferences = preload("res://rpg/game_preferences.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Readiness = preload("res://rpg/interaction_readiness.gd")
var app: Node
var actor: Node
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func frames(count: int) -> void:
	for index in range(count): await process_frame

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func settle() -> void:
	await frames(2)
	for index in range(120):
		if not app.ui.is_animating(): break
		await frames(1)
	await frames(2)

func open_book(page: String) -> void:
	app.ui.close_panel(true)
	app.ui.show_panel(page)
	await settle()
	check(paused and app.game.paused and app.ui.panel == page, "real book pauses gameplay: " + page)

func select_item(id: String) -> bool:
	app.ui._sync_rpg()
	for index in range(app.ui.items().size()):
		if app.ui.item_at(index).get("id", "") == id:
			app.ui._select_item(index)
			return true
	check(false, "owned item is listed: " + id)
	return false

func rejects_management(label: String) -> void:
	var before_inventory: Dictionary = actor.inventory.export_state()
	var before_loadout: Dictionary = actor.loadout.export_state()
	var before_growth: Dictionary = actor.progression.export_state()
	check(not Readiness.can_manage(actor), label + " rejects shared readiness")
	check(not actor.progression.choose_career("swordsman") and not actor.progression.learn_skill("warrior_whirlwind")
		and not actor.loadout.equip_weapon(0, "") and not actor.loadout.equip_item("head", "")
		and not actor.loadout.assign_skill(0, 0, "") and not actor.inventory.use_item("healing_potion"),
		label + " rejects career skill equipment and supplies")
	check(actor.inventory.export_state() == before_inventory and actor.loadout.export_state() == before_loadout
		and actor.progression.export_state() == before_growth, label + " leaves durable state unchanged")

func run() -> void:
	create_timer(60, true).timeout.connect(func():
		printerr("Paused RPG actions timed out")
		quit(2))
	var temp := OS.get_temp_dir().path_join("mosslight-paused-rpg-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	Preferences.settings_path = temp + ".cfg"
	root.size = Vector2i(1280, 720)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = Repository.new(temp + "-unused-saves")
	root.add_child(app)
	app.set_process(false)
	await frames(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.game.combat_world.encounters_started = true
	for enemy in app.game.combat_world.enemies: enemy.set_physics_process(false)
	actor = app.game.player
	await settle()
	check(app.ui.panel == "character" and paused and app.game.paused and actor.loadout.level == 0,
		"arrival presents the actual initial career book")
	check(Readiness.can_manage(actor) and not actor.combat.can_start(), "book readiness is separate from combat permission")
	var career_button: Button
	for node in app.ui.modal.get_children():
		if node is Button and node.text == "战士": career_button = node
	check(is_instance_valid(career_button) and not career_button.disabled, "real warrior card is enabled inside the paused book")
	if is_instance_valid(career_button) and not career_button.disabled: career_button.pressed.emit()
	await frames(3)
	check(actor.loadout.level == 1 and actor.loadout.career_ids == ["warrior"], "native career callback chooses warrior while paused")
	check(actor.loadout.equipment.head == "scout_hood" and actor.inventory.count("healing_potion") == 5,
		"career callback grants and equips the real starter kit")
	check(actor.inventory.count("magic_candy") == 0, "normal paused starter does not grant debug candy")
	await open_book("skills")
	var thrust: int = app.ui.skill_index("warrior_thrust")
	app.ui._select_skill(thrust)
	app.ui._learn_skill()
	await frames(3)
	check("warrior_thrust" in actor.loadout.learned_skills, "book callback learns an eligible skill while paused")
	check(app.ui._place_skill(thrust, 0, false, 0) and actor.loadout.sets[0].skills[0] == "warrior_thrust",
		"book callback assigns the learned skill while paused")
	await open_book("bag")
	check(actor.loadout.equip_weapon(0, "") and actor.loadout.equip_item("head", ""), "paused character can unequip weapon and armor")
	if select_item("iron_longsword"): app.ui._inventory_action("weapon", 0)
	if select_item("scout_hood"): app.ui._inventory_action("equipment")
	check(actor.loadout.sets[0].weapon == "iron_longsword" and actor.loadout.equipment.head == "scout_hood",
		"actual bag callbacks equip owned weapon and armor while paused")
	actor.resources.change("HP", -50)
	var before_hp: float = actor.resources.current("HP")
	var potions: int = actor.inventory.count("healing_potion")
	if select_item("healing_potion"): app.ui._inventory_action("use")
	check(actor.resources.current("HP") > before_hp and actor.inventory.count("healing_potion") == potions - 1,
		"bag resource item heals and consumes exactly once while paused")
	check(not actor.inventory.use_item("healing_potion") and actor.inventory.count("healing_potion") == potions - 1,
		"book use still enforces resource fullness and cooldown")
	check(actor.inventory.add_item("magic_candy"), "explicit paused level-item fixture grants one debug candy")
	var candy: int = actor.inventory.count("magic_candy")
	if select_item("magic_candy"): app.ui._inventory_action("use")
	check(actor.loadout.level == 2 and actor.inventory.count("magic_candy") == candy - 1, "bag level item remains usable while paused")
	var bombs: int = actor.inventory.count("fire_bomb")
	var serial: int = actor.combat.serial
	var position: Vector3 = actor.global_position
	if select_item("fire_bomb"): app.ui._inventory_action("use")
	check(not actor.inventory.can_use("fire_bomb").is_empty() and actor.inventory.count("fire_bomb") == bombs
		and actor.combat.serial == serial and not actor.combat.runner.busy(), "action item keeps its combat gate and is not consumed by paused bag")
	actor.combat.command("PRIMARY_TAP")
	Input.action_press("move_right")
	Input.action_press("attack_primary")
	await frames(6)
	Input.action_release("move_right")
	Input.action_release("attack_primary")
	check(paused and app.game.paused and actor.global_position.is_equal_approx(position)
		and actor.combat.serial == serial and not actor.combat.runner.busy() and actor.input_router.held.is_empty(),
		"menu operations never release world movement attack or input capture")
	actor.inventory.cooldowns.clear()
	actor.resources.change("HP", -20)
	for state in ["DEAD", "ACTION", "CHARGING", "HITSTUN", "GUARD", "SWITCH", "GRABBED"]:
		actor.combat.state = state
		rejects_management(state)
	actor.combat.state = "NORMAL"
	actor.combat.runner.current_action = {"id": "readiness_probe"}
	rejects_management("busy runner despite NORMAL state")
	actor.combat.runner.current_action = {}
	actor.combat.switch_time = 0.2
	rejects_management("pending combat-set switch")
	actor.combat.switch_time = 0.0
	actor.set_meta("traversal_locked", true)
	rejects_management("ladder traversal lock")
	actor.remove_meta("traversal_locked")
	var previous_mode: String = actor.control_mode
	actor.control_mode = "none"
	rejects_management("no active controller")
	actor.control_mode = previous_mode
	var hp: float = actor.resources.current("HP")
	actor.resources.pools.HP.current = 0.0
	rejects_management("zero HP before death-state transition")
	actor.resources.pools.HP.current = hp
	# Preserve the pre-existing career-specific form rule without introducing new
	# restrictions on equipment/skills that the form service keeps live.
	actor.form.active = true
	check(actor.progression.can_choose_career("swordsman") == "恢复原形后才能选择职业"
		and not actor.progression.choose_career("swordsman"), "temporary form still forbids a career change")
	actor.form.active = false
	check(Readiness.can_manage(actor) and actor.progression.learn_skill("warrior_whirlwind"), "ready actor resumes valid book operations after restrictions clear")
	app.ui.close_panel(true)
	check(not paused and not app.game.paused and actor.combat.can_start(), "closing book restores normal combat permission")
	check(actor.inventory.use_item("fire_bomb") and actor.inventory.count("fire_bomb") == bombs - 1
		and actor.combat.runner.busy(), "action item works through the real runner after closing the book")
	app.game._release_actions()
	app.queue_free()
	await frames(5)
	if FileAccess.file_exists(Preferences.settings_path): DirAccess.remove_absolute(Preferences.settings_path)
	print("PAUSED_RPG_ACTIONS checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
