extends "res://tests/combat_feel.gd"
const Recovery = preload("res://combat/resource_recovery.gd")

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(3)
	player = arena.player
	player.set_physics_process(false)
	for enemy in arena.enemies: enemy.set_physics_process(false)
	for career in ["warrior", "rogue", "barbarian", "mage"]:
		player.loadout.select_career(career)
		var stamina: Array = {"warrior":[3,4,5,10], "rogue":[3,4,5,10], "barbarian":[4,5,6,11], "mage":[2,2,3,5]}[career]
		var energy: Array = {"warrior":[60,80,100,180], "rogue":[60,80,100,180], "barbarian":[80,100,120,200], "mage":[60,80,120,290]}[career]
		for index in range(4):
			var level: int = [1,3,5,10][index]
			player.loadout.set_level(level)
			near(player.resources.max_value("Stamina"), stamina[index], "%s Lv%d stamina" % [career, level])
			near(player.resources.max_value("Energy"), energy[index], "%s Lv%d energy" % [career, level])
		var before: float = player.resources.max_value("Stamina")
		player.stats.add_modifier("test_con", {"CON":5 if career == "mage" else 4})
		player.loadout.refresh_resources(false)
		near(player.resources.max_value("Stamina"), before + 1, career + " reaching the next constitution threshold grants stamina")
		player.stats.remove_modifier("test_con")
		player.loadout.refresh_resources(true)
		player.combat.reset()
		player.combat.in_combat = true
		player.combat.combat_timeout = 1000
		player.resources.change("Stamina", -10000)
		player.resources.change("Energy", -10000)
		player.combat.tick(.5)
		near(player.resources.current("Stamina"), 0, career + " stamina waits after spending")
		near(player.resources.current("Energy"), 0, career + " mana waits after spending")
		player.combat.tick(.15)
		near(player.resources.current("Stamina"), 0, career + " recovery boundary gives no early pip")
		player.combat.tick(1)
		near(player.resources.current("Stamina"), Recovery.stamina_rate(player,true), career + " one eligible second recovers continuously")
		near(player.resources.current("Energy"), 0, career + " mana still waits two seconds")
		player.combat.tick(.35)
		player.combat.tick(1)
		near(player.resources.current("Energy"), Recovery.energy_rate(player,true), career + " combat mana rate is distinct from stamina")
		player.combat.state = "HITSTUN"
		player.combat.control_time = 100
		var guarded: float = player.resources.current("Stamina")
		player.combat.tick(2)
		near(player.resources.current("Stamina"), guarded, career + " control lock cannot regenerate stamina")
		player.combat.state = "NORMAL"
		player.combat.tick(.5)
		near(player.resources.current("Stamina"), guarded, career + " control lock does not bank recovery time")
		player.combat.in_combat = false
		player.combat.tick(.15)
		player.resources.change("Energy", -10000)
		player.combat.energy_clock = 2
		player.combat.tick(1)
		near(player.resources.current("Energy"), Recovery.energy_rate(player,false), career + " out of combat mana recovers faster")
		player.combat.state = "DEAD"
		var dead_energy: float = player.resources.current("Energy")
		player.combat.tick(10)
		near(player.resources.current("Energy"), dead_energy, career + " dead characters do not regenerate")
	player.loadout.select_career("mage")
	player.combat.energy_clock = 1.5
	verify(not player.resources.pay({"Energy":99999}) and player.combat.energy_clock == 1.5, "failed payment leaves recovery delay untouched")
	verify(player.resources.pay({"Energy":10}) and player.combat.energy_clock == 0, "successful paid spell restarts mana delay")
	player.combat.energy_clock = 1.5
	verify(player.resources.pay({"Energy":0}) and player.combat.energy_clock == 1.5, "cantrip does not interrupt mana recovery")
	var invalid: Dictionary = arena.database.skills.mage_fireball.duplicate(true)
	invalid.costs.Energy = 11
	verify(not player.combat.action_failure(invalid).is_empty(), "runtime rejects rank/cost mismatch before action payment")
	for action in arena.database.skills.values():
		verify(Recovery.spell_error(action).is_empty(), "valid spell contract " + action.id)
	player.loadout.select_career("warrior")
	player.loadout.set_level(10)
	verify(player.loadout.select_career("swordsman") and player.loadout.select_career("dual_swordsman"), "advanced careers inherit root resource growth")
	near(player.resources.max_value("Stamina"), 10, "dual swords keep warrior stamina")
	player.combat.reset()
	player.combat.in_combat = true
	player.combat.combat_timeout = 1000
	player.resources.change("Stamina", 1 - player.resources.current("Stamina"))
	verify(player.form.apply_enemy_form("soldier", 30), "small temporary body is available for recovery regression")
	player.combat.tick(.65)
	player.combat.tick(1)
	player.form.restore()
	near(player.resources.current("Stamina"), 2.08076923, "three-point body cannot amplify ten-point hero recovery")
	player.loadout.select_career("mage")
	player.loadout.set_level(10)
	player.resources.change("Energy", -145)
	player.combat.energy_clock = 1.25
	# Fixture-only native pool exercises the below-four-per-second floor case.
	arena.database.enemies.soldier["Energy"] = 10
	verify(player.form.apply_enemy_form("soldier", 30), "small mana pool projects canonical recovery")
	near(player.combat.energy_clock, 1.25, "body rescaling preserves mana recovery waiting time")
	player.combat.tick(.75)
	player.combat.tick(1)
	player.form.restore()
	near(player.resources.current("Energy"), 162.4, "temporary tiny mana pool cannot amplify out-of-combat recovery")
	for index in range(10):
		player.form.apply_enemy_form("soldier", 30)
		player.form.restore()
	near(player.resources.current("Energy"), 162.4, "repeated zero-time body changes cannot refill mana")
	var gear_changed := true
	for index in range(10):
		gear_changed = player.loadout.equip_item("neck", "scholar_pendant") and gear_changed
		gear_changed = player.loadout.equip_item("neck", "") and gear_changed
	verify(gear_changed, "resource regression actually equips and removes the stat item")
	near(player.resources.current("Energy"), 162.4, "repeated stat gear changes cannot refill mana")
	# A synthetic sixty-second cost budget, with a spend attempt every four
	# seconds. This tests sustained recovery/payment, not encounter difficulty.
	for career in ["warrior", "mage"]:
		for level in [1,5,10]:
			player.loadout.select_career(career)
			player.loadout.set_level(level)
			player.combat.reset()
			player.combat.in_combat = true
			player.combat.combat_timeout = 1000
			var cost := 10.0 if career == "mage" else 20.0
			var initial: float = player.resources.current("Energy")
			var paid := 0
			var restored := 0.0
			for second in range(60):
				if second % 4 == 0 and player.resources.pay({"Energy":cost}): paid += 1
				var before_tick: float = player.resources.current("Energy")
				player.combat.tick(1)
				restored += player.resources.current("Energy") - before_tick
			near(player.resources.current("Energy"), initial - paid * cost + restored, "%s Lv%d sustained budget conserves every paid/restored unit" % [career,level])
			verify(player.resources.current("Energy") >= 0 and paid > 0, "%s Lv%d never borrows negative mana" % [career,level])
			print("RESOURCE_BUDGET ", JSON.stringify({"career":career,"level":level,"seconds":60,"attempts":15,"cost":cost,"paid_casts":paid,"restored":restored,"remaining":player.resources.current("Energy")}))
	player.combat.reset()
	player.combat.in_combat = true
	player.combat.combat_timeout = 1000
	var high_rank_casts := 0
	for second in range(60):
		if second % 4 == 0 and player.resources.pay({"Energy":35}): high_rank_casts += 1
		player.combat.tick(1)
	verify(high_rank_casts == 9, "Lv10 mage's three-rank burst exhausts its budget before fifteen attempts")
	player.loadout.set_level(0)
	near(player.resources.max_value("Stamina"), 3, "civilian stamina remains valid")
	near(player.resources.max_value("Energy"), 0, "civilian cannot gain a mana pool through regeneration")
	print("RESOURCE_BALANCE: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures: printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)
