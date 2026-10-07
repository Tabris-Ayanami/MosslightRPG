extends SceneTree
## Real main-world form/control leases with isolated, checksummed disk saves.
const Repository = preload("res://rpg/save_repository.gd")
const Kirito = preload("res://combat/kirito_combat_visual.gd")
var game: Node
var actor: Node
var checks := 0
var failures := 0
var report: PackedStringArray = []
var workspace := ""
var form_notifications: Array[Dictionary] = []

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

func same_json(a: Dictionary, b: Dictionary) -> bool:
	return JSON.parse_string(JSON.stringify(a)) == JSON.parse_string(JSON.stringify(b))

func set_ratio(id: String, fraction: float) -> void:
	actor.resources.change(id, actor.resources.max_value(id) * fraction - actor.resources.current(id))

func observe_form() -> void:
	form_notifications.append({"active": actor.form.active, "race": actor.race_id,
		"name": actor.display_name, "hp": actor.resources.current("HP"),
		"attributes": actor.stats.base.duplicate(true), "mode": actor.control_mode,
		"world": game.world_state.export_state()})

func run() -> void:
	workspace = OS.get_temp_dir().path_join("mosslight-unit-form-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var repository := Repository.new(workspace)
	var created: Dictionary = repository.create("变身接管存档回归")
	check(created.ok, "isolated adventure slot is created")
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(15)
	actor = game.player
	if actor == null or actor.form == null or game.combat_world.control == null:
		check(false, "unified form and control initialize")
		finish()
		return
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	actor.set_physics_process(false)
	check(actor.progression.choose_career("warrior") and actor.progression.learn_skill("warrior_thrust") and actor.loadout.assign_skill(0, 0, "warrior_thrust"), "fixture prepares owned warrior gear and learned skill")
	game.world_state.set_flag("village.form_save_test", true)
	game.world_state.set_object("chest.form_save_test", {"opened": true})
	var original_attributes: Dictionary = actor.stats.base.duplicate(true)
	var original_inventory: Dictionary = actor.inventory.export_state()
	var original_loadout: Dictionary = actor.loadout.export_state()
	var original_progression: Dictionary = actor.progression.export_state()
	var original_world: Dictionary = game.world_state.export_state()
	var hero_hp_max: float = actor.resources.max_value("HP")
	var hero_qi_max: float = actor.resources.max_value("Energy")
	set_ratio("HP", .43)
	set_ratio("Stamina", .5)
	set_ratio("Energy", .6)
	actor.combat.cooldowns.warrior_thrust = 3.5
	check(actor.form.apply_enemy_form("fire_elemental", 30), "save fixture transforms to elemental")
	# Damage in the temporary body must survive saving, while its smaller maxima do not.
	set_ratio("HP", .31)
	var temporary_hp: float = actor.resources.current("HP")
	var control: Node = game.combat_world.control
	var target: Node = game.combat_world.spawn_enemy("soldier", actor.global_position + Vector3.RIGHT * 6)
	target.set_physics_process(false)
	var target_faction: String = target.faction_id
	check(control.possess(target, 30) and control.controlled_actor() == target and actor.control_mode == "none", "real control lease inhabits another unit while owner remains transformed")
	var saved: Dictionary = repository.save(0, "变身接管存档回归", actor, game)
	check(saved.ok, "transformed and possessed adventure can be saved")
	if not saved.ok:
		print("SAVE_ERROR ", saved.error)
		control.cancel_all()
		game.queue_free()
		await ticks(3)
		finish()
		return
	var loaded: Dictionary = Repository.new(workspace).load_slot(0)
	check(loaded.ok and loaded.snapshot.race_id == "human", "fresh disk read stores original human identity")
	var snapshot: Dictionary = loaded.snapshot
	check(same_json(snapshot.attributes, original_attributes) and same_json(snapshot.loadout, original_loadout), "disk stores original attributes and live prepared equipment/skills")
	check(same_json(snapshot.inventory, original_inventory) and same_json(snapshot.progression, original_progression) and same_json(snapshot.world_state, original_world), "canonical save preserves inventory, growth and world facts")
	check(is_equal_approx(snapshot.resources.HP, hero_hp_max * .31) and not is_equal_approx(snapshot.resources.HP, temporary_hp), "saved HP maps current damage proportion to original maximum")
	check(is_equal_approx(snapshot.resources.Energy, hero_qi_max * .6), "saved dormant energy keeps original proportion instead of becoming zero")
	check(actor.form.active and actor.definition_id == "fire_elemental" and control.controlled_actor() == target and actor.control_mode == "none", "saving is read-only for temporary form and control lease")
	check(not snapshot.has("form") and not snapshot.has("definition_id") and not snapshot.has("control_mode"), "temporary definition and control ownership are absent from save schema")
	actor.form.changed.connect(observe_form)
	var invalid: Dictionary = snapshot.duplicate(true)
	invalid.race_id = "unknown_form_race"
	var rejected: Dictionary = repository.restore(invalid, actor, game)
	check(not rejected.ok and actor.form.active and control.controlled_actor() == target and target.faction_id == actor.faction_id, "invalid snapshot does not clear form or release possession")
	check(form_notifications.is_empty() and actor.resources.current("HP") == temporary_hp and same_json(game.world_state.export_state(), original_world), "invalid restore emits no form update and mutates no resources/world state")
	# Observe the complete transaction, never the intermediate restore-to-original body.
	game.world_state.set_flag("village.form_save_test", false)
	actor.display_name = "临时名字"
	set_ratio("HP", .1)
	var restored: Dictionary = repository.restore(snapshot, actor, game)
	check(restored.ok and not actor.form.active and actor.definition_id == "hero" and actor.race_id == "human", "validated restore returns original human unit")
	check(control.controlled_actor() == actor and actor.control_mode == "human" and target.control_mode == "ai" and target.faction_id == target_faction, "validated restore releases possession and restores target allegiance/control")
	check(actor.animation.get_script() == Kirito and is_equal_approx(actor.get_node("CollisionShape3D").shape.radius, .27), "loaded player returns to Kirito body and original capsule")
	check(same_json(actor.stats.base, original_attributes) and same_json(actor.loadout.export_state(), original_loadout), "restored original attributes, gear and skill preparation match disk")
	check(is_equal_approx(actor.resources.current("HP"), hero_hp_max * .31) and is_equal_approx(actor.resources.current("Energy"), hero_qi_max * .6), "restore applies canonical HP and energy without free healing")
	check(same_json(actor.inventory.export_state(), original_inventory) and same_json(actor.progression.export_state(), original_progression) and same_json(game.world_state.export_state(), original_world), "restore commits inventory/growth/world facts intact")
	check(actor.combat.cooldowns.get("warrior_thrust", 0) == 3.5 and actor.combat.state == "NORMAL", "restore keeps saved skill cooldown while clearing transient combat action")
	check(form_notifications.size() == 1, "form emits exactly one final notification during a successful restore")
	if form_notifications.size() == 1:
		var notice: Dictionary = form_notifications[0]
		check(not notice.active and notice.race == "human" and notice.name == snapshot.name and notice.mode == "human" and is_equal_approx(notice.hp, snapshot.resources.HP) and same_json(notice.attributes, snapshot.attributes) and same_json(notice.world, snapshot.world_state), "form observer only sees the fully committed adventure")
	check(actor.form.apply_enemy_form("ogre", 30) and control.autopilot(actor, 30), "second fixture combines ogre form and temporary AI control")
	check(control.autopilot(target, 30) and control._autopilots.size() == 2, "multiple temporary AI leases are registered")
	var ai_rejected: Dictionary = repository.restore(invalid, actor, game)
	check(not ai_rejected.ok and actor.form.active and actor.control_mode == "ai" and control._autopilots.size() == 2, "invalid restore also preserves AI control leases")
	var ai_restored: Dictionary = repository.restore(snapshot, actor, game)
	check(ai_restored.ok and not actor.form.active and actor.control_mode == "human" and control._autopilots.is_empty(), "valid restore cancels every temporary AI lease and form")
	check(target.control_mode == "ai" and target.faction_id == target_faction and not target.brain.aggressive, "AI lease cleanup restores target's original brain configuration")
	# Existing dead-save behavior remains a safe respawn, never an elemental body.
	check(actor.form.apply_enemy_form("fire_elemental", 30), "death-save fixture enters elemental form")
	actor.resources.change("HP", -actor.resources.current("HP"))
	check(not actor.form.active and actor.combat.state == "DEAD", "death restores original form before persistence")
	var dead_saved: Dictionary = repository.save(0, snapshot.name, actor, game)
	check(dead_saved.ok and dead_saved.snapshot.race_id == "human" and is_equal_approx(dead_saved.snapshot.resources.HP, hero_hp_max), "dead save uses canonical human maximum for existing respawn behavior")
	check(dead_saved.ok and dead_saved.snapshot.world.position == dead_saved.snapshot.world.checkpoint and dead_saved.snapshot.combat.cooldowns.is_empty(), "dead save uses safe checkpoint and clears cooldowns")
	var revived: Dictionary = repository.restore(dead_saved.snapshot, actor, game)
	check(revived.ok and actor.combat.state == "NORMAL" and actor.definition_id == "hero" and actor.animation.get_script() == Kirito and actor.resources.current("HP") == hero_hp_max, "saved death restores a living original body at canonical maximum")
	clean()
	game._release_actions()
	game.queue_free()
	await ticks(3)
	finish()

func clean() -> void:
	var dir := DirAccess.open(workspace)
	if dir == null: return
	for filename in dir.get_files():
		DirAccess.remove_absolute(workspace.path_join(filename))
	DirAccess.remove_absolute(workspace)

func finish() -> void:
	var result := "UNIT_FORM_SAVE_RESULT checks=%d failures=%d" % [checks, failures]
	print(result)
	report.append(result)
	var file := FileAccess.open("res://docs/combat/unit_form_save_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	file.close()
	quit(0 if failures == 0 else 1)
