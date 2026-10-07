extends RefCounted
## One decision source for native enemies, allied units and temporary autopilot.
## It selects intents; CombatController still validates and executes every action.
var actor: Node
var aggressive := false
var home_override: Variant = null
var _last_seen := Vector3.ZERO
var _sight_memory := 0.0
var _damage_notice := false
var _pending_skills: Array[Dictionary] = []
var _skill_ids: Array[String] = []
var _scheduled_attack_count := -1
var _special_since_string := false

func setup(owner_actor: Node) -> void:
	actor = owner_actor

func notice_damage(source: Node, origin: Variant = null) -> void:
	# A landed attack supplies a finite location clue, not continuous sight.
	# Human/disabled bodies never acquire an autonomous intent this way.
	if not actor.ai_enabled or actor.control_mode != "ai" or actor.combat.state == "DEAD": return
	if not is_instance_valid(source) or not source.is_inside_tree() or source.combat.state == "DEAD" or not actor.arena.are_hostile(actor, source): return
	var point: Vector3 = origin if origin is Vector3 and origin.is_finite() else source.global_position
	if not point.is_finite(): return
	actor.current_target = source
	_last_seen = point
	_sight_memory = 3.0
	_damage_notice = true

func reset_awareness() -> void:
	if is_instance_valid(actor): actor.current_target = null
	_last_seen = Vector3.ZERO
	_sight_memory = 0.0
	_damage_notice = false

func tick(delta: float) -> void:
	if not actor.ai_enabled or actor.control_input_blocked(): return
	actor.ai_cooldown = maxf(0, actor.ai_cooldown - delta)
	var target: Node = actor.arena.nearest_hostile(actor, actor.aggro_range * (2 if aggressive else 1))
	var visible := is_instance_valid(target)
	if visible:
		_last_seen = target.global_position
		_sight_memory = 3.0
		_damage_notice = false
	elif (_navigation() != null or _damage_notice) and _sight_memory > 0 and is_instance_valid(actor.current_target):
		var remembered: Node = actor.current_target
		_sight_memory = maxf(0, _sight_memory - delta)
		# Damage may originate beyond sight range or precede a stealth escape.
		# In both cases investigate only the recorded point, never the live body.
		var valid_clue: bool = _damage_notice or (not remembered.combat.statuses.has_status("stealth") and actor.global_position.distance_to(_last_seen) < actor.aggro_range * (3 if aggressive else 2))
		if _sight_memory > 0 and remembered.combat.state != "DEAD" and actor.arena.are_hostile(actor, remembered) and valid_clue:
			target = remembered
	actor.current_target = target
	if not is_instance_valid(target):
		reset_awareness()
		var home: Vector3 = actor.spawn_point if home_override == null else home_override
		if actor.global_position.distance_to(home) > .5:
			actor.move_direction = _direction(home)
			if actor.move_direction.length_squared() > .01: actor.facing = actor.move_direction
		return
	if not visible:
		# Investigate the last sensed position, without attacking through walls or
		# tracking an unseen player's current position forever.
		if actor.combat.state == "GUARD": actor.combat.defense.stop_guard()
		if actor.combat.can_start():
			actor.move_direction = _direction(_last_seen)
			if actor.move_direction.length_squared() > .01: actor.facing = actor.move_direction
		return
	var offset: Vector3 = target.global_position - actor.global_position
	offset.y = 0
	var distance := offset.length()
	actor.combat.engage()
	target.combat.engage()
	if actor.combat.state == "GUARD" and (actor.ai_cooldown <= .6 or distance > actor.attack_reach * 1.3):
		actor.combat.defense.stop_guard()
	if not actor.combat.can_start(): return
	actor.facing = offset.normalized()
	var chosen: Dictionary = actor.action_for("PRIMARY_TAP", actor.combat.combo)
	var primary := chosen
	var sequence: Variant = actor.innate_actions.get("PRIMARY_TAP", {})
	var count: int = sequence.size() if sequence is Array else 1
	if actor.innate_actions.is_empty():
		count = actor.arena.database.get_combo_count(str(chosen.get("animation_family", "UNARMED")))
	var in_string: bool = count > 1 and actor.combat.combo % count != 0
	_schedule_skills()
	var skill_slot := -1
	# A due special waits for the whole primary string, rather than replacing
	# its final swing. One special between strings also keeps every=1 skills
	# from starving ordinary attacks. Skill-only units need no such alternation.
	if not in_string and (not _special_since_string or chosen.is_empty()):
		for pending in _pending_skills:
			var skill: Dictionary = actor.skill_at(pending.slot)
			if _skill_ready(skill, distance):
				chosen = skill
				skill_slot = pending.slot
				break
	if chosen.is_empty(): return
	# An explicitly ranged-response projectile need not wait for a melee string that
	# cannot reach the target. Close strings and an in-range special keep priority;
	# this only selects a slot, preserving controller payment and committed aim.
	if not in_string and not primary.is_empty() and distance > _reach(primary):
		if skill_slot < 0 or distance > _reach(chosen) * .8:
			for index in range(mini(3, actor.innate_skills.size())):
				var ranged: Dictionary = actor.skill_at(index)
				if not ranged.get("ai_use_at_range", false): continue
				if float(ranged.get("projectile_speed", 0.0)) <= 0.0 or _reach(ranged) <= _reach(primary) or distance > _reach(ranged) * .8: continue
				if _skill_period(ranged) > 0 and _skill_ready(ranged, distance):
					chosen = ranged
					skill_slot = index
					break
	var reach := maxf(.5, float(chosen.get("range", chosen.get("radius", actor.attack_reach))))
	if not actor.shield_definition().is_empty() and distance < reach * 1.3 and actor.ai_cooldown > .6:
		actor.combat.defense.start_guard(false)
	elif distance > reach * .8:
		actor.move_direction = _direction(target.global_position)
	elif actor.ai_cooldown <= 0:
		var started: bool = actor.combat.request_skill(skill_slot) if skill_slot >= 0 else actor.combat.weapon_action("PRIMARY_TAP")
		if started:
			actor.attacks_made += 1
			# The controller owns the action timing and advances the same combo as
			# player input. AI pauses between complete strings, not between swings.
			var continues: bool = skill_slot < 0 and count > 1 and actor.combat.combo % count != 0
			if skill_slot >= 0:
				_pending_skills = _pending_skills.filter(func(pending: Dictionary) -> bool: return int(pending.slot) != skill_slot)
				_special_since_string = true
			elif not continues:
				_special_since_string = false
			actor.ai_cooldown = 0.0 if continues else actor.enemy_attack_cooldown
	for other in actor.arena.units():
		if other == actor or other.combat.state == "DEAD": continue
		var apart: Vector3 = actor.global_position - other.global_position
		apart.y = 0
		if apart.length_squared() < 1.4:
			# Exactly overlapping bodies have no normalized separation direction.
			# Separate across the approach lane, not along it: pushing coincident
			# units forwards/backwards lets the rear unit immediately stack again.
			if apart.length_squared() <= .01:
				var lateral: Vector3 = actor.facing.cross(Vector3.UP).normalized()
				if lateral.length_squared() < .01: lateral = Vector3.RIGHT
				apart = lateral if actor.get_instance_id() < other.get_instance_id() else -lateral
			actor.move_direction += apart.normalized() * .5
	actor.move_direction = actor.move_direction.limit_length()

func _reach(action: Dictionary) -> float:
	return maxf(.5, float(action.get("range", action.get("radius", actor.attack_reach))))

func _skill_ready(skill: Dictionary, distance: float) -> bool:
	return distance >= float(skill.get("ai_min_distance", 0.0)) and actor.combat.action_failure(skill).is_empty()

func _schedule_skills() -> void:
	# Transient intent only: never retain a former body's skill or accumulate
	# repeated requests for one slot while resources/range delay its execution.
	if actor.attacks_made < _scheduled_attack_count:
		_pending_skills.clear()
		_special_since_string = false
	var current_ids: Array[String] = []
	for index in range(3): current_ids.append(str(actor.skill_at(index).get("id", "")))
	if current_ids != _skill_ids:
		_skill_ids = current_ids
		_scheduled_attack_count = -1
		_special_since_string = false
	_pending_skills = _pending_skills.filter(func(pending: Dictionary) -> bool:
		var skill: Dictionary = actor.skill_at(pending.slot)
		return skill.get("id", "") == pending.id and _skill_period(skill) > 0)
	if actor.attacks_made == _scheduled_attack_count: return
	_scheduled_attack_count = actor.attacks_made
	for index in range(3):
		var skill: Dictionary = actor.skill_at(index)
		if skill.is_empty(): continue
		var every := _skill_period(skill)
		if every <= 0 or (actor.attacks_made + 1) % every != 0: continue
		var exists := false
		for pending in _pending_skills:
			if int(pending.slot) == index: exists = true
		if not exists: _pending_skills.append({"slot": index, "id": str(skill.get("id", ""))})

func _skill_period(skill: Dictionary) -> int:
	if actor.grab_every > 0 and (skill.get("attack_kind", "") == "GRAB" or skill.get("grab", false)):
		return actor.grab_every
	return int(skill.get("ai_attack_every", 1))

func _navigation() -> Node:
	var host: Node = actor.arena.host
	return host.get("world_navigation") if is_instance_valid(host) else null

func _direction(destination: Vector3) -> Vector3:
	var navigation := _navigation()
	if is_instance_valid(navigation): return navigation.direction_for(actor, destination)
	# The combat laboratory deliberately has no world navigation region.
	var offset: Vector3 = destination - actor.global_position
	offset.y = 0
	return offset.normalized()
