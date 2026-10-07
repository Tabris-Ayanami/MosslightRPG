extends SceneTree
## Real CombatTestArena actors/controllers; deterministic brain ticks after real hits.
## This is a focused AI-awareness fixture, not a natural-play or world completion run.
const Preferences = preload("res://rpg/game_preferences.gd")
const DAMAGE := {"formula": {"base": 220.0}, "can_crit": false, "damage_type": "PHYSICAL", "poise_damage": 0.0}
const LETHAL := {"formula": {"base": 1000000.0}, "can_crit": false, "damage_type": "PHYSICAL", "poise_damage": 0.0}
var arena: Node
var source: Node
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	Preferences.settings_path = OS.get_environment("TEMP").path_join("mosslight_damage_awareness_%d.cfg" % OS.get_process_id())
	call_deferred("run")

func ticks(count: int) -> void:
	for _i in range(count):
		await physics_frame
		await process_frame

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func make_victim(at: Vector3 = Vector3.ZERO) -> Node:
	var victim: Node = arena.spawn_enemy("soldier", at)
	victim.ai_enabled = true
	victim.set_physics_process(false)
	victim.combat.set_physics_process(false)
	victim.ai_cooldown = 100000.0
	victim.global_position = at
	victim.spawn_point = at
	victim.move_direction = Vector3.ZERO
	victim.current_target = null
	victim.resources.configure("HP", 5000.0, true)
	return victim

func prepare_source(at: Vector3) -> void:
	if not is_instance_valid(source): return
	if source.combat.state == "DEAD": source.combat.reset()
	source.faction_id = "heroes"
	source.global_position = at
	source.velocity = Vector3.ZERO
	source.ai_enabled = false
	source.set_physics_process(false)
	source.combat.set_physics_process(false)
	source.combat.reset()
	source.set_control_mode("none")

func hit(victim: Node, attacker: Node, dot := false, packet: Dictionary = DAMAGE) -> Dictionary:
	return victim.combat.receive_damage(packet, attacker, Vector3.LEFT, dot)

func awake(victim: Node, attacker: Node, label: String) -> Vector3:
	var impact_position: Vector3 = attacker.global_position
	var result := hit(victim, attacker)
	verify(float(result.get("final", 0.0)) > 0.0, label + ": receive_damage applied positive damage")
	victim.brain.tick(0.1)
	verify(victim.brain._sight_memory > 2.8 and victim.brain._sight_memory <= 3.0, label + ": direct hit starts bounded awareness")
	return impact_position

func dispose(victim: Node) -> void:
	if is_instance_valid(victim): victim.queue_free()
	await process_frame

func run() -> void:
	arena = preload("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	await ticks(3)
	arena.sound.muted = true
	source = arena.player
	for unit in arena.units():
		if unit != source:
			unit.ai_enabled = false
			unit.set_physics_process(false)
			unit.combat.set_physics_process(false)
			unit.global_position = Vector3(70.0 + float(unit.get_instance_id() % 7), 0.05, 70.0)
	prepare_source(Vector3(24.0, 0.05, 0.0))

	# A real non-lethal direct hit from beyond aggro range starts a point-only
	# investigation. Moving a now-hidden source must not move the remembered point.
	var victim := make_victim(Vector3.ZERO)
	var remembered := awake(victim, source, "ranged hostile hit")
	verify(victim.global_position.distance_to(remembered) > victim.aggro_range, "attacker is outside ordinary sight/aggro range")
	source.combat.statuses.add_status("stealth", {"duration": 8.0}, source)
	source.global_position = Vector3(30.0, 0.05, 5.0)
	var attacks_before: int = victim.attacks_made
	victim.brain.tick(0.5)
	verify(victim.brain._last_seen.distance_to(remembered) < 0.01, "investigation keeps the impact-time position snapshot")
	verify(victim.move_direction.dot((remembered - victim.global_position).normalized()) > 0.85, "AI moves toward the remembered point while attacker is unseen")
	verify(victim.attacks_made == attacks_before and not victim.combat.runner.busy(), "unseen damage source is investigated without starting an attack")
	# Explicit displacement tests the return intent; staying at spawn would make
	# a return-home assertion vacuously pass without consulting the brain.
	victim.global_position = Vector3(2.0, 0.0, 0.0)
	victim.brain.tick(2.6)
	var home_direction: Vector3 = victim.spawn_point - victim.global_position
	verify(victim.brain._sight_memory <= 0.001 and victim.current_target == null, "damage awareness expires after at most three seconds")
	verify(home_direction.length_squared() > 1.0 and victim.move_direction.dot(home_direction.normalized()) > 0.85, "expired investigation resumes movement toward spawn point")
	await dispose(victim)

	# Projectile/area callers can carry the emitter's origin snapshot. Damage is
	# applied at the real controller API; moving the source before the brain tick
	# must still investigate the supplied origin rather than its later position.
	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	var emitted_origin: Vector3 = source.global_position
	var snapshot_packet: Dictionary = DAMAGE.duplicate(true)
	snapshot_packet["awareness_origin"] = emitted_origin
	# Move before impact so using the attacker's live point cannot pass.
	source.global_position = Vector3(34.0, 0.05, 8.0)
	var snapshot_result := hit(victim, source, false, snapshot_packet)
	victim.brain.tick(0.1)
	verify(float(snapshot_result.get("final", 0.0)) > 0.0 and victim.brain._last_seen.distance_to(emitted_origin) < 0.01, "real receive_damage honors an explicit awareness-origin snapshot")
	verify(victim.move_direction.dot((emitted_origin - victim.global_position).normalized()) > 0.85, "delayed investigation uses the emission point after source moves")
	await dispose(victim)

	# The normal visual-acquisition path remains authoritative for a nearby target.
	prepare_source(Vector3(0.0, 0.05, 4.0))
	victim = make_victim(Vector3.ZERO)
	awake(victim, source, "visible hostile hit")
	verify(victim.current_target == source and is_equal_approx(victim.brain._sight_memory, 3.0), "visible hostile remains acquired by ordinary perception")
	await dispose(victim)

	# A damage-over-time status created through the real effect path and ticked by
	# StatusComponent must hurt the victim without refreshing awareness duration.
	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	remembered = awake(victim, source, "burn fixture direct hit")
	victim.brain.tick(0.4)
	var memory_before_dot: float = victim.brain._sight_memory
	source.global_position = Vector3(32.0, 0.05, 6.0)
	victim.combat.apply_effect({"type": "status", "status": "burn", "duration": 3.0, "formula": {"base": 10.0}}, source)
	var hp_before_dot: float = victim.resources.current("HP")
	victim.combat.statuses.tick(1.0)
	victim.brain.tick(0.2)
	verify(victim.resources.current("HP") < hp_before_dot, "real burn status tick applies damage through receive_damage(dot=true)")
	verify(victim.brain._last_seen.distance_to(remembered) < 0.01 and victim.brain._sight_memory < memory_before_dot, "burn DOT does not refresh or relocate direct-hit awareness")
	await dispose(victim)

	# A fully shield-absorbed positive direct hit still communicates the attack.
	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	victim.health.shield = 100000.0
	var shield_hp: float = victim.resources.current("HP")
	var shield_before: float = victim.health.shield
	var shield_result := hit(victim, source)
	victim.brain.tick(0.1)
	verify(float(shield_result.get("final", 0.0)) > 0.0 and victim.health.shield < shield_before and victim.resources.current("HP") == shield_hp, "direct hit absorbed entirely by shield still informs awareness")
	verify(victim.brain._sight_memory > 2.8, "shield-absorbed direct hit starts bounded awareness")
	await dispose(victim)

	# Environmental, friendly, zero, invulnerable and dead-source hits cannot wake AI.
	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	var env_result := hit(victim, null)
	victim.brain.tick(0.1)
	verify(float(env_result.get("final", 0.0)) > 0.0 and victim.brain._sight_memory <= 0.001, "unattributed environmental damage does not awaken AI")
	await dispose(victim)

	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	var friendly: Node = arena.spawn_enemy("soldier", Vector3(25.0, 0.05, 0.0))
	friendly.set_physics_process(false)
	friendly.combat.set_physics_process(false)
	var friendly_result := hit(victim, friendly)
	victim.brain.tick(0.1)
	verify(friendly_result.get("blocked", false) and victim.brain._sight_memory <= 0.001, "same-faction damage is rejected and does not awaken AI")
	await dispose(victim)
	await dispose(friendly)

	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	var zero_packet := DAMAGE.duplicate(true)
	zero_packet.formula.base = 0.0
	var zero_result := hit(victim, source, false, zero_packet)
	victim.brain.tick(0.1)
	verify(float(zero_result.get("final", 0.0)) <= 0.0 and victim.brain._sight_memory <= 0.001, "zero-damage hit does not awaken AI")
	await dispose(victim)

	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	victim.combat.statuses.add_status("invulnerable", {"duration": 5.0})
	var invulnerable_result := hit(victim, source)
	victim.brain.tick(0.1)
	verify(invulnerable_result.get("blocked", false) and victim.brain._sight_memory <= 0.001, "invulnerable hit does not awaken AI")
	await dispose(victim)

	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	source.health.receive(source.resources.current("HP") + 1.0)
	var dead_result := hit(victim, source)
	victim.brain.tick(0.1)
	verify(source.combat.state == "DEAD" and float(dead_result.get("final", 0.0)) > 0.0 and victim.brain._sight_memory <= 0.001, "dead hostile source damage does not awaken AI")
	await dispose(victim)
	source.combat.reset()
	source.faction_id = "heroes"
	source.set_control_mode("none")

	# Existing damage awareness is discarded if its source ceases to be a valid
	# hostile, is removed/dies, or if the victim resets, dies or changes control.
	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	awake(victim, source, "relationship-change fixture")
	victim.faction_id = "heroes"
	victim.brain.tick(0.1)
	verify(victim.brain._sight_memory <= 0.001 and victim.current_target == null, "hostile becoming friendly clears remembered threat")
	await dispose(victim)

	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	var removable_source: Node = arena.spawn_enemy("soldier", Vector3(24.0, 0.05, 0.0))
	removable_source.faction_id = "heroes"
	removable_source.refresh_collision_layer()
	removable_source.ai_enabled = false
	removable_source.set_physics_process(false)
	removable_source.combat.set_physics_process(false)
	removable_source.set_control_mode("none")
	awake(victim, removable_source, "source-removal fixture")
	removable_source.queue_free()
	await process_frame
	victim.brain.tick(0.1)
	verify(victim.brain._sight_memory <= 0.001 and victim.current_target == null, "deleted damage source clears remembered threat")
	await dispose(victim)

	victim = make_victim(Vector3.ZERO)
	awake(victim, source, "source-death fixture")
	source.health.receive(source.resources.current("HP") + 1.0)
	victim.brain.tick(0.1)
	verify(source.combat.state == "DEAD" and victim.brain._sight_memory <= 0.001 and victim.current_target == null, "dead source clears remembered threat")
	source.combat.reset()
	source.faction_id = "heroes"
	source.set_control_mode("none")
	await dispose(victim)

	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	awake(victim, source, "combat-reset fixture")
	victim.combat.reset()
	verify(victim.brain._sight_memory <= 0.001 and victim.current_target == null, "combat reset clears damage awareness")
	await dispose(victim)

	prepare_source(Vector3(24.0, 0.05, 0.0))
	victim = make_victim(Vector3.ZERO)
	awake(victim, source, "death-reset fixture")
	victim.health.receive(victim.resources.current("HP") + 1.0)
	verify(victim.combat.state == "DEAD" and victim.brain._sight_memory <= 0.001 and victim.current_target == null, "death clears damage awareness")
	await dispose(victim)

	for mode in ["human", "none"]:
		prepare_source(Vector3(24.0, 0.05, 0.0))
		victim = make_victim(Vector3.ZERO)
		awake(victim, source, "control-%s fixture" % mode)
		victim.set_control_mode(mode)
		verify(victim.brain._sight_memory <= 0.001 and victim.current_target == null, "switching control to %s clears damage awareness" % mode)
		hit(victim, source)
		verify(victim.brain._sight_memory <= 0.001 and victim.current_target == null, "new damage does not impose an AI intent on %s control" % mode)
		await dispose(victim)

	print("DAMAGE_AWARENESS_RESULT %d/%d passed" % [checks - failures.size(), checks])
	for failure in failures: printerr("FAIL: ", failure)
	arena.queue_free()
	await ticks(2)
	quit(0 if failures.is_empty() else 1)
