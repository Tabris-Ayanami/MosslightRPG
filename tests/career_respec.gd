extends SceneTree
## Real paused book controls plus disk round trips, isolated from player saves.
const Preferences = preload("res://rpg/game_preferences.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
var app: Node
var actor: Node
var repository: RefCounted
var checks := 0
var failures: Array[String] = []
var evidence := ""

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func frames(count: int) -> void:
	for _index in range(count): await process_frame

func settle() -> void:
	await frames(3)
	for _index in range(180):
		if not app.ui.is_animating(): break
		await frames(1)
	await frames(3)

func click(name: String) -> void:
	var button: Button = app.ui.modal.get_node_or_null(name)
	check(is_instance_valid(button) and not button.disabled, "enabled book control: " + name)
	if is_instance_valid(button) and not button.disabled: button.pressed.emit()
	await settle()

func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	# Book turns and the pencil-path erasure have independent clocks.
	for _index in range(180):
		if app.ui.career_age >= 1.4: break
		await process_frame
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(evidence.path_join(label + ".png")) == OK, "saved book screenshot: " + label)

func state() -> Dictionary:
	return {"loadout": actor.loadout.export_state(), "growth": actor.progression.export_state(),
		"inventory": actor.inventory.export_state(), "world": app.game.world_state.export_state()}

func rejects(label: String) -> void:
	var before := state()
	check(not actor.progression.forget_career() and not actor.progression.last_error.is_empty(), "rejects reset: " + label)
	check(state() == before, "rejected reset is unchanged: " + label)

func run() -> void:
	create_timer(75, true).timeout.connect(func(): printerr("Career respec timed out"); quit(2))
	evidence = OS.get_temp_dir().path_join("mosslight-career-respec-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(evidence)
	Preferences.settings_path = evidence.path_join("preferences.cfg")
	repository = Repository.new(evidence.path_join("adventures"))
	check(repository.create("转职旅人", 0).ok, "creates isolated civilian save")
	root.size = Vector2i(1280, 720)
	app = load("res://scenes/frontend/app.tscn").instantiate()
	app.saves = repository
	root.add_child(app)
	app.set_process(false)
	await frames(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate.a = 1.0
	app.game.combat_world.encounters_started = true
	for enemy in app.game.combat_world.enemies: enemy.set_physics_process(false)
	actor = app.game.player
	await settle()
	check(paused and actor.loadout.level == 0, "real arrival book pauses a new civilian")
	rejects("already civilian")
	check(actor.progression.choose_career("warrior"), "initial career still works while paused")
	check(actor.inventory.count("healing_potion") == 5 and actor.resources.current("HP") == actor.resources.max_value("HP"), "initial career still grants starter kit and full health")
	check(actor.progression.level_up() and actor.progression.choose_career("soldier"), "fixture earns Lv2 paired career and reward")
	check(actor.progression.add_experience(37) and actor.progression.learn_skill("warrior_thrust") and actor.loadout.assign_skill(0, 0, "warrior_thrust"), "fixture has retained XP and prepared learned skill")
	actor.inventory.add_item("hunter_ring")
	actor.loadout.equip_item("ring1", "hunter_ring")
	actor.inventory.add_item("apprentice_staff")
	check(actor.progression.grant_trait("last_stand", "转职测试祝福", "祝福"), "fixture grants a real catalog blessing")
	actor.combat.cooldowns["warrior_thrust"] = 2.0
	actor.resources.change("HP", -50)
	await settle()
	for blocked_state in ["ACTION", "CHARGING", "HITSTUN", "DEAD", "SWITCH", "JUMP"]:
		actor.combat.state = blocked_state
		rejects(blocked_state)
	actor.combat.state = "NORMAL"
	actor.form.active = true
	rejects("temporary form")
	actor.form.active = false
	actor.set_meta("traversal_locked", true)
	rejects("traversal")
	actor.remove_meta("traversal_locked")
	actor.control_mode = "none"
	rejects("no controller")
	actor.control_mode = "human"
	Guard.acquire(app.game.world_state, "fixture")
	rejects("another adventure transaction")
	Guard.release(app.game.world_state, "fixture")
	var before := state()
	check(repository.save(0, "转职旅人", actor, app.game).ok, "original advanced build saves")
	await click("CareerForget")
	await capture("01-confirm")
	check(app.ui.career_forget_confirm and state() == before, "opening confirmation has no gameplay mutation")
	app.ui.request_escape()
	await settle()
	check(not app.ui.career_forget_confirm and app.ui.panel == "character" and state() == before, "Escape cancels reset and keeps career book")
	await click("CareerForget")
	await click("CareerForgetConfirm")
	await capture("02-civilian")
	check(paused and actor.loadout.level == 2 and actor.progression.experience == 37, "reset retains level and XP without unpausing")
	check(actor.loadout.career_ids.is_empty() and actor.loadout.learned_skills.is_empty() and actor.loadout.available_skills.is_empty(), "reset clears career and learned/available skills")
	check(actor.loadout.sets.all(func(group: Dictionary): return group.weapon.is_empty() and group.skills == ["", "", ""]), "both weapon and skill groups are cleared")
	check(actor.stats.base.is_empty() and actor.loadout.proficiencies.is_empty() and not actor.loadout.uses_paired_weapons(), "civilian loses profession stats and paired proficiency")
	check(actor.inventory.export_state() == before.inventory and actor.loadout.equipment == before.loadout.equipment, "inventory quickslots and equipped armor survive unchanged")
	check(actor.progression.export_state() == before.growth and app.game.world_state.export_state() == before.world, "all growth receipts blessings and world progress survive")
	check(actor.combat.cooldowns.get("warrior_thrust") == 2.0 and actor.resources.current("HP") > 0 and actor.resources.current("HP") <= 100, "reset preserves cooldowns and clamps civilian resources")
	check(actor.combat.passives.definitions().any(func(data: Dictionary): return data.id == "last_stand"), "acquired blessing still applies as civilian")
	check(not actor.progression.learn_skill("warrior_thrust") and not actor.loadout.assign_skill(0, 0, "warrior_thrust"), "old skills cannot be learned or equipped as civilian")
	var saved: Dictionary = repository.save(0, "转职旅人", actor, app.game)
	check(saved.ok, "Lv2 civilian with old career receipts saves to disk: " + str(saved.get("error", "")))
	if saved.ok:
		var reopened := Repository.new(repository.directory)
		var loaded: Dictionary = reopened.load_slot(0)
		check(loaded.ok and reopened.restore(loaded.snapshot, actor, app.game).ok, "new repository instance restores civilian disk save")
		check(actor.loadout.level == 2 and actor.progression.experience == 37 and actor.loadout.career_ids.is_empty(), "civilian level and XP survive restore")
		var bad: Dictionary = loaded.snapshot.duplicate(true)
		bad.progression.career_rewards.append("not_a_career")
		check(not reopened.restore(bad, actor, app.game).ok, "unknown historical career receipt remains invalid")
		bad = loaded.snapshot.duplicate(true)
		bad.progression.starter_granted = false
		check(not reopened.restore(bad, actor, app.game).ok, "positive civilian level requires prior starter receipt")
	check(actor.progression.choose_career("mage"), "returning civilian may choose another base career")
	check(actor.loadout.level == 2 and actor.progression.experience == 37 and actor.stats.base == actor.arena.database.careers.mage.stats, "new career recalculates its own stats without resetting advancement")
	check(actor.inventory.export_state() == before.inventory and actor.loadout.equipment == before.loadout.equipment, "new career grants no duplicate starter and keeps chosen armor")
	check(actor.loadout.sets[0].weapon == "apprentice_staff" and actor.loadout.learned_skills.is_empty(), "new default uses only an owned weapon and teaches no skills automatically")
	check(actor.resources.current("HP") < actor.resources.max_value("HP"), "re-employment does not refill health")
	check(repository.save(0, "转职旅人", actor, app.game).ok, "new career saves with historical soldier receipt")
	check(actor.progression.forget_career() and actor.progression.choose_career("warrior") and actor.progression.choose_career("soldier"), "can return to previous advanced path at retained level")
	check(actor.inventory.export_state() == before.inventory and actor.progression.career_rewards.count("soldier") == 1, "repeated path gives no extra shield or duplicate receipt")
	check(actor.progression.forget_career() and actor.progression.add_experience(120) and actor.loadout.level == 3 and actor.progression.experience == 7, "returning civilian keeps normal XP progression")
	check(app.game.quests.accept("village_patrol"), "returning civilian may accept a real chapter quest")
	app.game.world_state.record_event("enemy_defeated", "soldier", 1, "career-respec-patrol")
	check(app.game.quests.claim("village_patrol") and actor.progression.experience == 67, "returning civilian receives quest XP without requiring a profession")
	check(not app.game.quests.claim("village_patrol") and actor.progression.experience == 67, "civilian quest reward remains exactly once")
	check(repository.save(0, "转职旅人", actor, app.game).ok, "leveled returning civilian also saves")
	check(actor.progression.choose_career("rogue"), "Lv3 civilian re-employs again")
	await settle()
	await capture("03-reemployed")
	app.game._release_actions()
	app.queue_free()
	await frames(6)
	print("CAREER_RESPEC checks=%d failures=%d evidence=%s" % [checks, failures.size(), evidence])
	quit(0 if failures.is_empty() else 1)
