extends "res://tests/combat_defense.gd"
## Dedicated precision-window regression through real input, live actor ticks,
## and enemy AttackInstance collisions. Inherits only test fixture utilities.

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(3)
	if not is_instance_valid(arena.get("player")) or not is_instance_valid(arena.get("ui")):
		printerr("COMBAT_PARRY_WINDOWS: arena initialization failed")
		quit(1)
		return
	player = arena.player
	player.combat.runner.action_started.connect(func(action: Dictionary): started.append(action.duplicate(true)))
	await check_charge_glow_timeline()
	await check_charge_hit_consumption()
	await check_charge_release_inheritance()
	await check_shield_and_counter_light()
	await check_fixed_soldier_hands()
	await check_exact_precision_boundaries()
	for action in InputMap.get_actions():
		Input.action_release(action)
	print("COMBAT_PARRY_WINDOWS: %d checks; %d failures" % [checks, failures.size()])
	for failure in failures:
		printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)

func hold_to_ratio(ratio: float) -> void:
	for i in range(150):
		if player.combat.state == "CHARGING" and player.combat.charge_progress() >= ratio:
			return
		await ticks(1)

func heavy_charge(ratio: float) -> void:
	await prepare("barbarian")
	mouse(MOUSE_BUTTON_LEFT, true)
	await hold_to_ratio(ratio)

func light_on() -> bool:
	return bool(player.animation.precision_glow_active)

func check_charge_glow_timeline() -> void:
	await prepare("barbarian")
	mouse(MOUSE_BUTTON_LEFT, true)
	var mismatch := 0
	var lit_frames := 0
	var early_frames := 0
	var late_frames := 0
	var duration := 0.0
	var transitions: Array[Dictionary] = []
	var previous := false
	for i in range(76):
		await ticks(1)
		duration = float(player.combat.charge_action.get("charge_duration", .9))
		var elapsed: float = player.combat.charge_time
		var expected := elapsed >= duration * .65 and elapsed < duration * .85
		if player.combat.defense.precision_window_active() != expected or light_on() != expected:
			mismatch += 1
		if expected:
			lit_frames += 1
		elif elapsed < duration * .65:
			early_frames += 1
		else:
			late_frames += 1
		if light_on() != previous:
			transitions.append({"frame": Engine.get_physics_frames(), "elapsed": elapsed, "active": light_on()})
		previous = light_on()
	verify(mismatch == 0, "every held-charge frame shows white exactly inside the live precision interval")
	verify(early_frames > 20 and lit_frames > 5 and late_frames > 20, "charge timeline traverses preparation, precision, and expired phases")
	verify(player.combat.charge_ready and not light_on(), "fully held charge remains ready after the precision light has ended")
	verify(player.animation.body_flash_remaining <= 0.0, "reaching full charge emits no one-shot white body flash")
	verify(not arena.ui.charge_indicator_visible, "precision feedback adds no charge progress overlay")
	print("PARRY_WINDOW_TRACE ", JSON.stringify({"duration": duration, "transitions": transitions, "mismatches": mismatch}))

func check_charge_hit_consumption() -> void:
	await heavy_charge(.72)
	verify(light_on() and player.combat.defense.precision_window_active(), "late heavy preparation enters an available precise-defense window")
	verify(player.animation._precision_meshes.size() > 0, "precision light is applied to the actual body meshes")
	var hp: float = player.resources.current("HP")
	var stamina: float = player.resources.current("Stamina")
	impact({"poise_damage": 0})
	verify(player.combat.defense.last_outcome == "parry", "frontal attack in charge interval triggers precise defense")
	near(player.resources.current("HP"), hp, "charge precision negates the real enemy attack instance")
	near(player.resources.current("Stamina"), stamina, "charge precision pays no stamina")
	verify(not player.combat.defense.precision_window_active() and not light_on(), "consumed charge precision extinguishes the light in the same hit call")
	verify(player.animation.body_flash_remaining <= 0.0, "successful precise defense adds no lingering white flash")
	impact()
	verify(player.combat.defense.last_outcome == "block", "same charge interval cannot precisely defend a second attack")
	near(player.resources.current("Stamina"), stamina - 1, "second charge-window hit uses ordinary guard stamina cost")
	verify(not light_on(), "ordinary charge-window block never recreates the consumed precision light")
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(2)
	verify(started.size() == 1 and not started[0].has("guard_window"), "already-consumed held precision cannot be inherited by release")
	await heavy_charge(.72)
	hp = player.resources.current("HP")
	impact({"poise_damage": 0}, Vector3(0, 0, 1.8))
	near(player.resources.current("HP"), hp - 100, "rear strike bypasses the charge guard angle")
	verify(player.combat.defense.precision_window_active() and light_on(), "rear miss does not consume the angle-independent precision indicator")
	impact({"poise_damage": 0})
	verify(player.combat.defense.last_outcome == "parry", "available interval can still precisely defend a later frontal strike")
	await heavy_charge(.72)
	player.combat.receive_damage(packet({"poise_damage": 0}), foe, Vector3.BACK, true)
	verify(player.combat.defense.precision_window_active() and light_on(), "DOT bypasses defense without consuming the available interval")
	impact({"poise_damage": 0})
	verify(player.combat.defense.last_outcome == "parry", "a new physical hit still consumes the opportunity after DOT")
	await heavy_charge(.72)
	await tap(KEY_X)
	verify(not player.combat.defense.precision_window_active() and not light_on(), "opening a menu clears the held precision window and light")

func check_charge_release_inheritance() -> void:
	for ratio in [.45, .72, .92, 1.0]:
		await heavy_charge(ratio)
		var should_inherit: bool = ratio > .65 and ratio < .85
		mouse(MOUSE_BUTTON_LEFT, false)
		await ticks(1)
		verify(started.size() == 1 and bool(started[0].get("charged_release", false)), "physical release starts one heavy charged attack at ratio %.2f" % ratio)
		verify(started.size() == 1 and started[0].has("guard_window") == should_inherit, "release inherits precision only from an available live interval at ratio %.2f" % ratio)
		verify(player.combat.defense.precision_window_active() == should_inherit and light_on() == should_inherit, "release light agrees with inherited precision at ratio %.2f" % ratio)
		var hp: float = player.resources.current("HP")
		impact({"poise_damage": 0})
		if should_inherit:
			verify(player.combat.defense.last_outcome == "parry", "in-window release precisely defends a real incoming hit")
			near(player.resources.current("HP"), hp, "inherited release guard prevents the triggering HP loss")
			verify(not light_on(), "inherited release light turns off immediately after its one precise hit")
		else:
			verify(player.combat.defense.last_outcome == "none", "out-of-window release grants no hidden precise defense")
			near(player.resources.current("HP"), hp - 100, "out-of-window release takes the real incoming attack")
	await heavy_charge(.72)
	mouse(MOUSE_BUTTON_LEFT, false)
	await ticks(1)
	await wait_action_time(.21)
	verify(not player.combat.defense.precision_window_active() and not light_on(), "unused inherited release precision expires after .20 seconds")
	impact({"poise_damage": 0})
	verify(player.combat.defense.last_outcome == "none", "expired release window no longer blocks incoming attacks")

func check_shield_and_counter_light() -> void:
	await prepare()
	await click(MOUSE_BUTTON_RIGHT)
	verify(started.size() == 1 and bool(started[0].get("shield_raise", false)), "actual right click with a shield starts its shield-raise action")
	verify(player.combat.defense.precision_window_active() and light_on(), "shield raise lights the body only during its initial precise window")
	impact()
	verify(player.combat.defense.last_outcome == "parry" and not light_on(), "shield-raise precise hit consumes its light immediately")
	verify(player.animation.body_flash_remaining <= 0.0, "shield precision adds no separate success white flash")
	await prepare()
	await click(MOUSE_BUTTON_RIGHT)
	await wait_action_time(.18)
	verify(not player.combat.defense.precision_window_active() and not light_on(), "shield raise stops glowing when only its ordinary guard remains")
	impact()
	verify(player.combat.defense.last_outcome == "block" and not light_on(), "ordinary shield-raise block remains unlit")
	await prepare()
	await raise_guard()
	verify(player.combat.defense.precision_window_active() and light_on(), "fresh held Ctrl guard exposes its genuine precise window")
	await ticks(12)
	verify(not player.combat.defense.precision_window_active() and not light_on(), "sustained Ctrl guard is unlit after fresh precision expires")
	impact()
	verify(player.combat.defense.last_outcome == "block" and not light_on(), "held ordinary shield block produces no white light")
	await prepare_fujian()
	await tap(KEY_R)
	await wait_action_time(.4)
	verify(not player.combat.defense.precision_window_active() and not light_on(), "active counter stance is not mislabeled as a precise-parry window")
	impact()
	verify(player.combat.defense.last_outcome == "counter" and not light_on(), "automatic counter reaction produces no precise-parry light")
	verify(player.animation.body_flash_remaining <= 0.0, "counter success produces no extra white flash")

func check_fixed_soldier_hands() -> void:
	await prepare("warrior")
	player.loadout.set_level(2)
	player.loadout.select_career("soldier")
	verify(player.loadout.uses_paired_weapons(), "soldier selects the paired sword-and-shield loadout rule")
	var sword: String = player.loadout.weapon_at(0).id
	var shield: String = player.loadout.weapon_at(1).id
	var old_skills: Array = player.loadout.sets[player.loadout.current_set].skills.duplicate()
	await tap(KEY_SHIFT)
	await ticks(24)
	verify(player.loadout.current_set == 1 and player.loadout.sets[1].skills != old_skills, "Shift changes the soldier QER skill set")
	verify(player.loadout.weapon_at(0).id == sword and player.loadout.weapon_at(1).id == shield, "Shift preserves both simultaneously equipped soldier weapons")
	await click()
	verify(started.size() == 1 and started[0].get("animation_family", "") == "SINGLE_BLADE", "soldier left click remains the sword action while QER set B is selected")
	await ticks(50)
	await click(MOUSE_BUTTON_RIGHT)
	verify(started.size() == 2 and bool(started[1].get("shield_raise", false)), "soldier right click remains shield raise after selecting QER set B")
	verify(light_on() == player.combat.defense.precision_window_active(), "paired-shield action uses the same live precision light contract")

func check_exact_precision_boundaries() -> void:
	await heavy_charge(.1)
	var duration: float = player.combat.charge_action.charge_duration
	player.combat.charge_time = duration * .65 - .000001
	verify(not player.combat.defense.precision_window_active(), "charge precision excludes the instant before its start")
	player.combat.charge_time = duration * .65
	verify(player.combat.defense.precision_window_active(), "charge precision includes its exact ratio start")
	player.combat.charge_time = duration * .85 - .000001
	verify(player.combat.defense.precision_window_active(), "charge precision includes the final instant before its end")
	player.combat.charge_time = duration * .85
	verify(not player.combat.defense.precision_window_active(), "charge precision excludes its exact ratio endpoint")
	player.combat.charge_time = duration * 1.5
	verify(not player.combat.defense.precision_window_active(), "overheld full charge cannot reopen its elapsed precision window")
	await prepare()
	await click(MOUSE_BUTTON_RIGHT)
	player.combat.runner.action_time = .16
	verify(not player.combat.defense.precision_window_active(), "shield action precision excludes its exact .16-second endpoint")
