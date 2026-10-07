extends SceneTree
## Same-unit form lifecycle, natural attacks, proportions and canonical save view.
const Form = preload("res://combat/unit_form.gd")
const Definitions = preload("res://combat/unit_definition.gd")
var game: Node
var actor: Node
var checks := 0
var failures := 0
var report: PackedStringArray = []
var started: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

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

func ratio(id: String) -> float:
	return actor.resources.current(id) / maxf(.001, actor.resources.max_value(id))

func set_ratio(id: String, value: float) -> void:
	actor.resources.change(id, actor.resources.max_value(id) * value - actor.resources.current(id))

func natural_attack(expected_id: String, enemy: Node) -> void:
	game.aim_override = enemy.global_position
	actor.facing = (enemy.global_position - actor.global_position).normalized()
	var before: float = enemy.resources.current("HP")
	Input.action_press("attack_primary")
	await ticks(2)
	Input.action_release("attack_primary")
	await ticks(2)
	check(expected_id in started, "real primary input selects " + expected_id)
	await ticks(135)
	check(enemy.resources.current("HP") < before, expected_id + " damages a real hostile through shared combat")

func run() -> void:
	root.size = Vector2i(1280, 720)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(15)
	actor = game.player
	if actor == null or actor.combat == null or actor.form == null:
		check(false, "unified unit components initialize")
		finish()
		return
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	check(actor.progression.choose_career("warrior"), "real warrior progression is initialized")
	check(actor.progression.learn_skill("warrior_thrust") and actor.loadout.assign_skill(0, 0, "warrior_thrust"), "original equipped skill is learned and assigned")
	actor.stats.base.STR += 2
	actor.stats.changed.emit()
	var identity := actor.get_instance_id()
	var controller: int = actor.combat.get_instance_id()
	var original_base: Dictionary = actor.stats.base.duplicate(true)
	var original_loadout: Dictionary = actor.loadout.export_state()
	var inventory: Dictionary = actor.inventory.export_state()
	var original_race: String = actor.race_id
	var original_name: String = actor.display_name
	var original_faction: String = actor.faction_id
	var original_control: String = actor.control_mode
	var original_visual: Script = actor.animation.get_script()
	set_ratio("HP", .37)
	set_ratio("Stamina", .67)
	set_ratio("Energy", .25)
	actor.combat.cooldowns["warrior_thrust"] = 7
	actor.combat.runner.action_started.connect(func(action: Dictionary): started.append(str(action.get("id", ""))))
	check(not actor.form.apply_enemy_form("missing_form", 2) and not actor.form.active, "unknown form is rejected without starting a transformation")
	check(not actor.form.apply_enemy_form("ogre", 0) and actor.stats.base == original_base, "invalid duration leaves original attributes untouched")
	check(actor.form.apply_enemy_form("fire_elemental", 20), "human transforms into a fire elemental")
	check(actor.get_instance_id() == identity and actor.combat.get_instance_id() == controller, "transformation retains the same actor and combat controller")
	check(actor.race_id == "elemental" and actor.definition_id == "fire_elemental", "current race and unit definition become elemental")
	check(actor.display_name == original_name and actor.faction_id == original_faction and actor.control_mode == original_control, "name, faction and control ownership survive transformation")
	check(actor.stats.base == Definitions.for_enemy(game.combat_world.database, "fire_elemental").stats and is_equal_approx(actor.move_speed, 2.1), "form supplies actual base abilities and movement")
	check(actor.animation.get_script() == preload("res://combat/animation_controller.gd") and is_equal_approx(actor.get_node("CollisionShape3D").shape.radius, .35), "form replaces visual body and real collision geometry")
	check(is_equal_approx(ratio("HP"), .37) and is_equal_approx(ratio("Stamina"), .67), "transform preserves HP and stamina proportions")
	check(actor.resources.max_value("Energy") == 0 and actor.form.canonical_resources().Energy > 0, "a temporarily absent pool retains its original proportion")
	check(actor.combat.cooldowns.get("warrior_thrust", 0) == 7, "transformation does not reset skill cooldowns")
	check(actor.loadout.export_state() == original_loadout and actor.inventory.export_state() == inventory, "equipment, skills and inventory are not replaced by the form")
	check(actor.form.canonical_race_id() == original_race and actor.form.canonical_attributes() == original_base and actor.form.canonical_definition().id == "hero", "canonical save identity remains the original human")
	check(not actor.progression.can_choose_career("soldier").is_empty(), "temporary form blocks active career replacement")
	var foe: Node = game.combat_world.spawn_enemy("soldier", actor.global_position + Vector3.RIGHT * 2)
	foe.set_physics_process(false)
	foe.resources.configure("HP", 5000)
	await natural_attack("fire_elemental_attack", foe)
	set_ratio("HP", .24)
	check(actor.form.apply_enemy_form("ogre", 20), "a second form replaces the temporary form")
	check(actor.race_id == "giant" and actor.form.canonical_race_id() == original_race, "nested form retains the first canonical identity")
	check(is_equal_approx(ratio("HP"), .24), "form-to-form transition carries damage proportion without healing")
	check(actor.get_node("CollisionShape3D").scale == Vector3.ONE and is_equal_approx(actor.get_node("CollisionShape3D").shape.radius, .525) and is_equal_approx(actor.get_node("CollisionShape3D").shape.height, 1.95), "ogre gets its larger collision body")
	foe.global_position = actor.global_position + Vector3.RIGHT * 2
	await natural_attack("ogre_attack", foe)
	check(actor.form.restore(), "manual restoration succeeds")
	check(not actor.form.active and actor.definition_id == "hero" and actor.race_id == original_race, "restoration returns the original unit and race")
	check(actor.stats.base == original_base and actor.loadout.export_state() == original_loadout, "restoration preserves custom career attributes and original equipment/skills")
	check(actor.animation.get_script() == original_visual and is_equal_approx(actor.get_node("CollisionShape3D").shape.radius, .27) and actor.get_node("CollisionShape3D").scale == Vector3.ONE, "Kirito model and original capsule return")
	check(is_equal_approx(ratio("HP"), .24) and is_equal_approx(ratio("Energy"), .25), "human returns with carried HP and dormant energy proportions")
	check(actor.inventory.export_state() == inventory, "natural monster attacks do not mutate player inventory")
	check(actor.form.apply_enemy_form("fire_elemental", 2), "growth fixture enters temporary form")
	check(actor.progression.level_up(), "experience progression can still advance during a form")
	var canonical_hp: float = actor.form.canonical_max_resources().HP
	check(actor.form.canonical_loadout().level == 2 and canonical_hp > 1070, "canonical save resources use original body with current level")
	set_ratio("HP", .41)
	actor.form.clear_for_load()
	check(not actor.form.active and actor.loadout.level == 2 and actor.stats.base == original_base, "pre-load clearing restores body while retaining earned growth")
	check(is_equal_approx(actor.resources.max_value("HP"), canonical_hp) and is_equal_approx(ratio("HP"), .41), "canonical maximum matches restored maximum without free healing")
	check(actor.form.apply_enemy_form("ogre", .05), "timed form begins")
	await ticks(5)
	check(not actor.form.active and actor.definition_id == "hero", "actual actor tick expires and restores the form")
	check(actor.form.apply_enemy_form("fire_elemental", 10), "death fixture enters temporary form")
	actor.resources.change("HP", -actor.resources.current("HP"))
	check(not actor.form.active and actor.definition_id == "hero" and actor.combat.state == "DEAD" and actor.resources.current("HP") == 0, "death immediately restores original body while keeping zero HP and DEAD")
	check(not actor.form.apply_enemy_form("ogre", 2), "dead units cannot exploit transformation to revive")
	# The same component also supports a non-player unit, without replacing its AI.
	var enemy: Node = game.combat_world.spawn_enemy("soldier", actor.global_position + Vector3.LEFT * 4)
	enemy.set_physics_process(false)
	var enemy_control: String = enemy.control_mode
	var enemy_faction: String = enemy.faction_id
	var enemy_max: float = enemy.resources.max_value("HP")
	enemy.resources.change("HP", -enemy_max * .6)
	check(enemy.form.apply_enemy_form("ogre", 2) and enemy.control_mode == enemy_control and enemy.faction_id == enemy_faction, "AI unit uses the same form component without ownership changes")
	enemy.form.restore()
	check(enemy.definition_id == "soldier" and is_equal_approx(enemy.resources.current("HP"), enemy_max * .4), "AI unit restores its own original body and HP ratio")
	game._release_actions()
	game.queue_free()
	await ticks(3)
	finish()

func finish() -> void:
	var result := "UNIT_FORM_RESULT checks=%d failures=%d" % [checks, failures]
	print(result)
	report.append(result)
	var file := FileAccess.open("res://docs/combat/unit_form_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	file.close()
	quit(0 if failures == 0 else 1)
