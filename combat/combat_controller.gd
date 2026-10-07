extends Node

signal damage_dealt(result: Dictionary)
signal critical_hit(result: Dictionary)
signal perfect_dodge
signal poise_broken
signal combat_set_switched(index: int)
signal skill_used(id: String)
signal died

const Runner = preload("res://combat/action_runner.gd")
const Passives = preload("res://combat/passive_component.gd")
const Statuses = preload("res://combat/status_component.gd")
const Defense = preload("res://combat/defense_component.gd")
const Recovery = preload("res://combat/resource_recovery.gd")
const Impact = preload("res://combat/impact_feedback.gd")
var actor: Node
var runner: Node
var passives: Node
var statuses: Node
var defense: Node
var state := "NORMAL"
var in_combat := false
var combat_timeout := 0.0
var first_damage := true
var first_damage_instance := ""
var cooldowns: Dictionary = {}
var base_poise := 50.0
var current_poise := 50.0
var poise_delay := 0.0
var control_time := 0.0
var switch_time := 0.0
var dodge_time := 0.0
var dodge_is_dash := false
var dodge_in_water := false
var dodge_paid := 0.0
var perfect_refunded := false
var dodge_direction := Vector3.FORWARD
var knockback := Vector3.ZERO
var combo := 0
var combo_timeout := 0.0
var stamina_clock := 0.0
var energy_clock := 0.0
var serial := 0
var last_damage: Dictionary = {}
var last_condition_failed := ""
var action_origin := Vector3.ZERO
var action_direction := Vector3.FORWARD
var action_point := Vector3.ZERO
var action_target: Node
var quick_counts := [5, 5, 5, 5]
var charge_action: Dictionary = {}
var charge_button := ""
var charge_time := 0.0
var charge_ready := false
var queued_command: Dictionary = {}
var input_time := 0.0
var guard_requested := false
var guard_key_held := false
var guard_pointer_held := false
var guard_counter_time := 0.0
var last_block_source: WeakRef
var grab_source: WeakRef
var grab_target: WeakRef
var grab_time := 0.0
var hitstop_remaining := 0.0
var motion_delta := 0.0
var stopped_this_tick := false

func add_hitstop(seconds: float) -> void:
	# Airborne, swimming and climbing bodies retain their physical trajectory.
	if state == "DEAD" or not actor.is_on_floor() or actor.swimming or actor.movement_actions.airborne or actor.animation.climbing_active: return
	hitstop_remaining = maxf(hitstop_remaining, clampf(seconds, 0.0, .14))

func clear_hitstop() -> void:
	hitstop_remaining = 0.0
	stopped_this_tick = false
	if is_instance_valid(actor.animation):
		actor.animation.contact_remaining = 0.0
		if is_instance_valid(actor.animation._contact_spark): actor.animation._contact_spark.hide()

func setup(owner_actor: Node) -> void:
	actor = owner_actor
	runner = Runner.new()
	add_child(runner)
	defense = Defense.new()
	add_child(defense)
	defense.setup(actor)
	passives = Passives.new()
	passives.actor = actor
	add_child(passives)
	statuses = Statuses.new()
	statuses.actor = actor
	add_child(statuses)
	runner.action_finished.connect(_finished)
	actor.health.died.connect(_die)
	actor.resources.resource_spent.connect(_resource_spent)

func tick(delta: float) -> void:
	var stopped := minf(delta, hitstop_remaining)
	hitstop_remaining = maxf(0.0, hitstop_remaining - delta)
	motion_delta = delta - stopped
	stopped_this_tick = stopped > 0.0
	input_time += motion_delta
	if stopped > 0.0 and actor.input_router:
		for entry in actor.input_router.buffer.entries: entry.expires += stopped
	if not queued_command.is_empty() and input_time > float(queued_command.expires):
		queued_command.clear()
	if _control_blocked():
		clear_input_intent()
		clear_hitstop()
		motion_delta = delta
	for id in cooldowns:
		cooldowns[id] = maxf(0.0, float(cooldowns[id]) - delta)
	passives.tick(delta)
	statuses.tick(delta)
	var stat_mods: Dictionary = passives.actor_modifiers("stat_update")
	var attributes: Dictionary = {}
	for stat in CombatStats.CONTEXT_IDS:
		if stat_mods.has(stat):
			attributes[stat] = stat_mods[stat]
	if actor.stats.modifiers.get("passive_runtime", {}) != attributes:
		actor.stats.add_modifier("passive_runtime", attributes)
	if state == "DEAD":
		return
	# Damage-over-time, passive expiry and cooldowns use wall time; the local
	# action, recovery, displacement and visual pose share this motion clock.
	delta = motion_delta
	if delta <= .000001: return
	defense.tick(delta)
	guard_counter_time = maxf(0.0, guard_counter_time - delta)
	if state in ["GRABBED", "GRABBING"]:
		_tick_grab(delta)
	if state == "CHARGING":
		charge_time += delta
		if not charge_ready and charge_progress() >= 1.0:
			charge_ready = true
			actor.arena.sound.play_tone("charge")
	combat_timeout = maxf(0.0, combat_timeout - delta)
	if in_combat and combat_timeout <= 0.0:
		in_combat = false
		first_damage = true
		first_damage_instance = ""
		passives.reset_combat()
	# The follow-up grace period starts after recovery, so a heavy swing cannot
	# consume its own combo timeout before the player gets a chance to follow up.
	if not runner.busy() and state != "CHARGING":
		combo_timeout = maxf(0.0, combo_timeout - delta)
		if combo_timeout <= 0.0:
			combo = 0
	poise_delay = maxf(0.0, poise_delay - delta)
	if poise_delay <= 0.0:
		var maximum := max_poise()
		current_poise = minf(maximum, current_poise + maximum * delta * 1.8)
	_tick_resource_recovery(delta)
	if state == "DODGE":
		dodge_time += delta
		if dodge_time >= 0.42:
			state = "NORMAL"
	elif state in ["HITSTUN", "KNOCKDOWN", "EXPOSED", "GUARD_BROKEN"]:
		control_time -= delta
		if control_time <= 0.0:
			state = "NORMAL"
	elif state == "SWITCH":
		switch_time -= delta
		if switch_time <= 0.0:
			state = "NORMAL"
	elif runner.busy():
		actor.attack_assist.advance_leap(delta)
		if runner.tick(delta):
			_execute_active()
		_tick_dual_followup()
		_defense_cues()
		_drain_queued_command()
		if runner.busy() and _weapon_transition_ready():
			_consume_weapon_buffer()
	_drain_queued_command()
	_try_held_charge()
	if guard_requested and can_start():
		defense.start_guard(false)
	sync_precision_glow()
	knockback = knockback.move_toward(Vector3.ZERO, delta * 16.0)

func _resource_spent(id: String, _amount: float) -> void:
	if id == "Stamina": stamina_clock = 0.0
	elif id == "Energy": energy_clock = 0.0

func _tick_resource_recovery(delta: float) -> void:
	# Only elapsed eligible time counts: actions/guard cannot bank a free pip.
	if state in ["NORMAL", "MOVE"] and not runner.busy():
		var ready := maxf(0.0, delta - maxf(0.0, Recovery.STAMINA_DELAY - stamina_clock))
		stamina_clock = minf(Recovery.STAMINA_DELAY, stamina_clock + delta)
		if ready > 0.0 and actor.resources.current("Stamina") < actor.resources.max_value("Stamina"):
			actor.resources.change("Stamina", Recovery.stamina_rate(actor, in_combat) * ready)
	else:
		stamina_clock = 0.0
	var energy_ready := maxf(0.0, delta - maxf(0.0, Recovery.ENERGY_DELAY - energy_clock))
	energy_clock = minf(Recovery.ENERGY_DELAY, energy_clock + delta)
	if energy_ready > 0.0 and actor.resources.current("Energy") < actor.resources.max_value("Energy"):
		actor.resources.change("Energy", Recovery.energy_rate(actor, in_combat) * energy_ready)

func stamina_recovery_progress() -> float:
	if state not in ["NORMAL", "MOVE"] or runner.busy() or stamina_clock < Recovery.STAMINA_DELAY:
		return -1.0
	var current: float = actor.resources.current("Stamina")
	return current - floorf(current) if current < actor.resources.max_value("Stamina") else -1.0

func _action_weapon(action: Dictionary) -> Dictionary:
	if actor.is_innate_action(action):
		return action.get("innate_weapon", {})
	if action.get("id", "") == "shield_raise":
		return actor.shield_definition()
	if action.get("is_skill", false):
		if actor.loadout.paired_style() != "sword_shield_pair":
			return actor.loadout.weapon_at(int(action.get("skill_set", actor.loadout.current_set)))
		return actor.loadout.combat_weapon()
	if action.get("dual_wield", false):
		return actor.loadout.weapon_at(0)
	return actor.loadout.combat_weapon()

func _dual_sequence_for(action: Dictionary) -> Dictionary:
	if actor.is_innate_action(action):
		return {}
	if not actor.loadout.is_dual_wielding() or action.get("is_reaction", false) or action.get("presentation_type", "") != "WEAPON_ACTION":
		return {}
	if action.get("targeting", "") == "SELF" or _action_weapon(action).get("animation_family", "") != "SINGLE_BLADE":
		return {}
	# The career passive enables shared attack templates; skills only describe
	# which part repeats. Movement and self effects remain on the parent action.
	if "dual_sword_mastery" not in actor.loadout.passive_ids:
		return {}
	var passive: Dictionary = actor.arena.database.passives.get("dual_sword_mastery", {})
	if passive.get("action_rule", "") != "dual_sword_skill_repeat" or not CombatConditions.check_all(passive.get("conditions", []), context(null, action)).is_empty():
		return {}
	var sequence: Dictionary = action.get("dual_sequence", {}).duplicate(true)
	if sequence.is_empty() and not action.get("is_skill", false):
		sequence = {"template": "slash", "origin": "action_origin"}
	if sequence.get("template", "") not in ["slash", "spin", "thrust"]:
		return {}
	return sequence

func context(target: Node = null, action: Dictionary = {}) -> Dictionary:
	var stats: Dictionary = actor.stats.final_values()
	var resource_values: Dictionary = {}
	for id in ["HP", "Stamina", "Energy"]:
		resource_values[id] = actor.resources.current(id)
	var weapon: Dictionary = action.weapon_snapshot if action.has("weapon_snapshot") else _action_weapon(action)
	var valid := is_instance_valid(target)
	var target_statuses: Array = target.combat.statuses.entries.keys() if valid else []
	if valid:
		for status in target.combat.statuses.entries.values():
			if status.get("is_control", false) and status.get("source") != null and status.source.get_ref() == actor:
				target_statuses.append("controlled_by_self")
				break
	return {"stats": stats, "weapon_family": action.get("animation_family", weapon.get("animation_family", "")),
		"race": actor.race_id, "race_id": actor.race_id, "definition_id": actor.definition_id,
		"faction_id": actor.faction_id, "faction": actor.faction_id,
		"target_race": target.race_id if valid else "", "target_faction": target.faction_id if valid else "",
		"target_level": target.loadout.level if valid else -1,
		"weapon_type": weapon.get("weapon_type", ""), "hp_ratio": actor.health.ratio(),
		"target_hp_ratio": target.health.ratio() if valid else 1.0, "has_target": valid,
		"behind": CombatTargeting.is_behind(actor.global_position, target.global_position, target.facing) if valid else false,
		"in_combat": in_combat, "state": state, "statuses": statuses.entries.keys(),
		"target_statuses": target_statuses,
		"careers": actor.loadout.career_ids, "resources": resource_values, "proficiencies": actor.loadout.proficiencies,
		"first_hit": first_damage, "first_damage": first_damage, "level": actor.loadout.level,
		"distance": actor.global_position.distance_to(target.global_position) if valid else 0.0,
		"damage_type": action.get("damage_type", "PHYSICAL"), "presentation_type": action.get("presentation_type", ""),
		"is_skill": action.get("is_skill", false), "area": action.get("targeting", "") in ["CIRCLE", "CONE", "POINT"]}

func _control_blocked() -> bool:
	return actor.control_mode == "none" or actor.control_input_blocked()

func can_start() -> bool:
	return not _control_blocked() and hitstop_remaining <= 0.0 and not stopped_this_tick and state in ["NORMAL", "MOVE"] and not runner.busy() and switch_time <= 0.0

func request_guard() -> bool:
	if _control_blocked():
		return false
	if state in ["DEAD", "HITSTUN", "KNOCKDOWN", "EXPOSED", "GUARD_BROKEN", "GRABBED", "GRABBING", "SWITCH", "DODGE", "JUMP"]:
		return false
	if defense.shield().is_empty():
		return fail("当前武器未装备可用盾牌")
	if not actor.movement_actions.stand_for_action(): return false
	guard_requested = true
	if not _can_cancel_into("skill"):
		return true
	if state != "GUARD":
		_cancel_for_transition()
	var started: bool = defense.start_guard(true)
	sync_precision_glow()
	return started

func request_shield() -> bool:
	if _control_blocked() or defense.shield().is_empty() or state in ["DEAD", "HITSTUN", "KNOCKDOWN", "EXPOSED", "GUARD_BROKEN", "GRABBED", "GRABBING", "SWITCH", "DODGE", "JUMP"]:
		return false
	guard_pointer_held = true
	guard_requested = true
	if not _can_cancel_into("skill"):
		return true
	var definition: Dictionary = actor.arena.database.reactions.get("shield_raise", {}).duplicate(true)
	if definition.is_empty():
		return false
	var window: Dictionary = defense.shield().duplicate(true)
	window["start"] = 0.0
	window["end"] = .22
	window["perfect_window"] = float(window.get("perfect_window", .16)) if defense.guard_cooldown <= 0.0 else 0.0
	definition["guard_window"] = window
	definition["shield_raise"] = true
	_cancel_for_transition()
	actor.face_action_target()
	if not use_action(definition):
		return false
	if float(window.perfect_window) > 0.0:
		defense.guard_cooldown = .45
	sync_precision_glow()
	return true

func sync_precision_glow() -> void:
	if is_instance_valid(actor.animation) and actor.animation.has_method("set_precision_glow"):
		actor.animation.set_precision_glow(state != "DEAD" and defense.precision_window_active())

func _flash(color: Color, duration := .12) -> void:
	if actor.animation.has_method("flash_body"):
		actor.animation.flash_body(color, duration)

func _is_grab(action: Dictionary) -> bool:
	return bool(action.get("grab", false)) or str(action.get("attack_kind", action.get("attack_type", ""))).to_upper() == "GRAB" or action.get("presentation_type", "") == "GRAB"

func _defense_cues() -> void:
	if not runner.busy():
		return
	var action: Dictionary = runner.current_action
	if _is_grab(action) and not action.get("_grab_cue", false) and runner.action_time >= float(action.get("startup", 1)) - .18:
		action["_grab_cue"] = true
		_flash(Color("ff293b"), .25)

func has_hyper_armor() -> bool:
	return defense.has_hyper_armor()

func force_control(control_state: String, duration: float) -> void:
	if state == "DEAD":
		return
	_release_grab(false)
	if actor.input_router:
		actor.input_router.cancel()
	else:
		clear_input_intent()
	runner.cancel_action()
	state = control_state
	control_time = duration
	guard_counter_time = 0.0
	knockback = Vector3.ZERO
	actor.animation.play_hit(control_state)
	sync_precision_glow()

func expose(duration := .9) -> void:
	if state == "DEAD":
		return
	var opening_time := minf(duration, .55) if actor.is_boss else duration
	force_control("EXPOSED", opening_time)
	statuses.add_status("opening", {"duration": opening_time + .35, "is_control": true,
		"effects": [{"type": "modifier", "stat": "vulnerability_ALL", "value": .25}]})
	actor.arena.float_text(actor.global_position + Vector3.UP * 2, "破绽", Color("fff4c9"))

func begin_counter(source: Node, reaction_id: String) -> bool:
	var action: Dictionary = actor.arena.database.reactions.get(reaction_id, {})
	if action.is_empty() or state in ["DEAD", "GRABBED", "GRABBING", "GUARD_BROKEN", "EXPOSED", "HITSTUN", "KNOCKDOWN"]:
		return false
	_cancel_for_transition()
	guard_counter_time = 0.0
	if is_instance_valid(source):
		var offset: Vector3 = source.global_position - actor.global_position
		offset.y = 0
		if offset.length_squared() > .001:
			actor.facing = offset.normalized()
	return use_action(action)

func _start_grab(source: Node, duration: float) -> void:
	if not is_instance_valid(source) or source == actor or source.combat.state == "DEAD":
		force_control("GRABBED", duration)
		grab_time = duration
		return
	force_control("GRABBED", duration)
	source.combat.force_control("GRABBING", duration)
	grab_source = weakref(source)
	source.combat.grab_target = weakref(actor)
	grab_time = duration
	source.combat.grab_time = duration
	var hold_point: Vector3 = source.global_position + source.facing.normalized() * 1.05
	var pull: Vector3 = hold_point - actor.global_position
	pull.y = 0.0
	actor.safe_displace(pull.limit_length(1.5))
	actor.arena.float_text(actor.global_position + Vector3.UP * 2, "被抓取", Color("ff626d"))

func _tick_grab(delta: float) -> void:
	if state == "GRABBING":
		var victim: Node = grab_target.get_ref() if grab_target != null else null
		if not is_instance_valid(victim) or victim.combat.state != "GRABBED":
			_release_grab(false)
		return
	grab_time -= delta
	var source: Node = grab_source.get_ref() if grab_source != null else null
	if grab_time <= 0.0 or not is_instance_valid(source) or source.combat.state != "GRABBING":
		_release_grab(true)

func _release_grab(throw_victim: bool) -> void:
	var source: Node = grab_source.get_ref() if grab_source != null else null
	var victim: Node = grab_target.get_ref() if grab_target != null else null
	grab_source = null
	grab_target = null
	grab_time = 0.0
	if is_instance_valid(source):
		source.combat.grab_target = null
		if source.combat.state == "GRABBING":
			source.combat.state = "NORMAL"
	if is_instance_valid(victim):
		victim.combat.grab_source = null
		if victim.combat.state == "GRABBED":
			victim.combat.state = "KNOCKDOWN"
			victim.combat.control_time = .65
	if state == "GRABBED":
		state = "KNOCKDOWN" if throw_victim else "NORMAL"
		control_time = .65 if throw_victim else 0.0
		if throw_victim and is_instance_valid(source):
			knockback = (actor.global_position - source.global_position).normalized() * 3
	elif state == "GRABBING":
		state = "NORMAL"

func command(kind: String) -> void:
	if _control_blocked() or state == "DEAD":
		return
	if kind not in ["PRIMARY_TAP", "lock_target"]: actor.attack_assist.cancel()
	if kind == "guard_pressed":
		guard_key_held = true
		request_guard()
	elif kind == "guard_released":
		guard_key_held = false
		guard_requested = guard_pointer_held
		if not guard_requested:
			defense.stop_guard()
		sync_precision_glow()
	elif kind == "shield_pressed":
		request_shield()
	elif kind == "shield_released":
		guard_pointer_held = false
		guard_requested = guard_key_held
		if not guard_requested:
			defense.stop_guard()
		sync_precision_glow()
	elif kind in ["PRIMARY_TAP", "PRIMARY_CHARGE", "SECONDARY_TAP", "SECONDARY_CHARGE"]:
		if state == "CHARGING":
			if kind.begins_with(charge_button):
				_release_charge()
			elif actor.input_router != null:
				actor.input_router.buffer.consume(kind, actor.input_router.clock)
			return
		# Holding through an uninterruptible action is not free charge time.
		if kind.ends_with("_CHARGE"):
			if actor.input_router != null:
				actor.input_router.buffer.consume(kind, actor.input_router.clock)
			kind = kind.replace("_CHARGE", "_TAP")
			if actor.input_router != null:
				actor.input_router.buffer.push(kind, actor.input_router.clock)
		if can_start():
			if actor.input_router != null:
				actor.input_router.buffer.consume(kind, actor.input_router.clock)
			if kind == "PRIMARY_TAP" and actor.attack_assist.request_primary(): return
			weapon_action(kind)
		elif state == "ACTION" and runner.busy() and actor.input_router != null:
			# Accept one deliberate follow-up throughout this swing. It can only
			# execute at the weapon's recovery gate, regardless of clicking speed.
			var action: Dictionary = runner.current_action
			var remaining: float = float(action.get("startup", .1)) + float(action.get("active", .1)) + float(action.get("recovery", .2)) - runner.action_time
			actor.input_router.buffer.push(kind, actor.input_router.clock, maxf(_feel("weapon_buffer", .35), remaining + .04))
	elif kind.begins_with("skill_"):
		var slot := ["skill_q", "skill_e", "skill_r"].find(kind)
		request_skill(slot)
	elif kind == "switch_combat_set":
		switch_set()
	elif kind == "dodge_dash":
		request_dodge()
	elif kind == "lock_target" and actor.is_human_controlled():
		actor.arena.toggle_lock()
	elif kind.begins_with("quick_item_"):
		use_quick_item(int(kind.right(1)) - 1)

func weapon_action(semantic: String, overrides: Dictionary = {}) -> bool:
	var action: Dictionary = actor.action_for(semantic, combo).duplicate(true)
	if action.is_empty():
		return fail("当前单位没有此武技")
	var family: String = action.get("animation_family", _action_weapon(action).get("animation_family", ""))
	action["semantic"] = semantic
	action["animation_family"] = family
	action["innate_action"] = actor.is_innate_action(action)
	action.merge(overrides, true)
	action["dual_wield"] = not action.innate_action and actor.loadout.is_dual_wielding() and family == "SINGLE_BLADE" and not action.get("is_skill", false) and not action.get("is_reaction", false)
	if use_action(action):
		if semantic == "PRIMARY_TAP":
			combo += 1
		else:
			combo = 0
		combo_timeout = _feel("combo_reset_delay", .65)
		if actor.input_router != null:
			actor.input_router.buffer.clear()
		return true
	return false

func action_failure(action: Dictionary, ignore_state := false, selecting := false) -> String:
	var spell_reason := Recovery.spell_error(action)
	if not spell_reason.is_empty(): return spell_reason
	if actor.get_meta("traversal_locked", false):
		return "攀爬时无法使用战斗动作"
	if _control_blocked():
		return "当前控制状态不能使用动作"
	if actor.movement_actions.crouching and not actor.movement_actions.can_stand():
		return "上方空间不足，无法站起使用动作"
	if action.is_empty():
		return "没有可用动作"
	var innate: bool = actor.is_innate_action(action)
	if action.get("innate_action", false) and not innate:
		return "当前形态不具备此动作"
	if not innate and not action.get("is_reaction", false) and actor.loadout.level == 0 and action.get("animation_family", "") != "UNARMED" and (action.get("is_skill", false) or action.get("presentation_type", "") in ["WEAPON_ACTION", "CASTER_ACTION"]):
		return "请先选择职业"
	if action.get("id", "") == "shield_raise" and defense.shield().is_empty():
		return "举盾武技需要装备盾牌"
	if not ignore_state and not can_start():
		return "当前动作尚未结束"
	if not innate and action.get("is_skill", false) and action.get("id", "") not in actor.loadout.unlocked_skills:
		return "尚未获得此职业技能"
	var natural_guard: bool = action.get("id", "") == "shield_raise" and actor.loadout.shield().is_empty() and not defense.shield().is_empty()
	if not innate and not natural_guard and action.get("presentation_type", "") in ["WEAPON_ACTION", "CASTER_ACTION"]:
		var weapon_error: String = actor.loadout.can_equip_weapon(str(_action_weapon(action).get("id", "")))
		if not weapon_error.is_empty():
			return weapon_error
		if action.get("dual_wield", false) or not _dual_sequence_for(action).is_empty():
			if not actor.loadout.is_dual_wielding():
				return "需要二刀流职业"
			for index in range(2):
				weapon_error = actor.loadout.can_equip_set_weapon(index, str(actor.loadout.weapon_at(index).get("id", "")))
				if not weapon_error.is_empty():
					return weapon_error
	if float(cooldowns.get(action.get("id", ""), 0.0)) > 0.0:
		return "技能冷却中"
	var target: Node = actor.target_for_action(action)
	if not selecting and action.get("targeting", "") == "TARGET" and not is_instance_valid(target):
		return "需要有效目标（Tab 锁定）"
	if not selecting and action.get("targeting", "") == "TARGET" and is_instance_valid(target):
		if target.combat.state == "DEAD" or target == actor or target.arena != actor.arena:
			return "目标已失效"
		if action.get("target_relation", "hostile") != "any" and not actor.arena.are_hostile(actor, target):
			return "需要敌对目标"
		var reach := _action_reach(action, target)
		var offset: Vector3 = target.global_position - actor.global_position
		offset.y = 0
		if offset.length() > reach or not actor.arena.line_clear(actor.global_position, target.global_position):
			return "目标超出范围或被障碍遮挡"
		if action.get("leap_motion",false):
			var landing: Dictionary = actor.attack_assist.leap_plan(target,action)
			if not str(landing.error).is_empty(): return landing.error
	var conditions: Array = action.get("conditions", [])
	if selecting:
		conditions = conditions.filter(func(condition: Dictionary) -> bool: return str(condition.get("type", "")) not in ["target_hp", "target_status", "target_level_at_most_self", "behind", "behind_target", "distance"])
	var reason := CombatConditions.check_all(conditions, context(target, action))
	if not reason.is_empty():
		return reason
	if not selecting and action.get("targeting", "") == "TARGET":
		for effect in action.get("effects", []):
			if effect.get("type", "") == "possess" and effect.get("target", "target") == "self":
				reason = _possession_failure(actor, target, effect)
				if not reason.is_empty(): return reason
	if not actor.resources.can_pay(costs_for(action)):
		return "资源不足"
	return ""

func _action_reach(action: Dictionary, target: Node = null) -> float:
	var reach := float(action.get("range", 12.0))
	if action.get("presentation_type", "") == "CASTER_ACTION":
		var modifiers: Dictionary = passives.actor_modifiers("stat_update", target, action, _action_weapon(action))
		_merge_modifiers(modifiers, statuses.modifiers())
		reach *= maxf(0.0, 1.0 + float(modifiers.get("spell_range_multiplier", 0.0)))
	return reach

func _feel(key: String, fallback: float) -> float:
	return float(actor.arena.database.combat_feel.get("input", {}).get(key, fallback))

func charge_progress() -> float:
	if state != "CHARGING":
		return 0.0
	return clampf(charge_time / maxf(.01, float(charge_action.get("charge_duration", .6))), 0.0, 1.0)

func begin_charge(button: String) -> bool:
	if button == "SECONDARY" and not defense.shield().is_empty():
		return request_shield()
	if button == "PRIMARY" and guard_counter_time > 0.0 and (can_start() or state == "GUARD"):
		var target: Node = last_block_source.get_ref() if last_block_source != null else null
		if is_instance_valid(target) and target.combat.state != "DEAD":
			return begin_counter(target, "guard_riposte")
	if state == "GUARD":
		defense.stop_guard()
	if _control_blocked() or not can_start() or button not in ["PRIMARY", "SECONDARY"]:
		return false
	var action: Dictionary = actor.action_for(button + "_CHARGE", 0).duplicate(true)
	var innate: bool = actor.is_innate_action(action)
	# Bodies with natural taps do not borrow an unrelated equipped charge.
	if actor.is_innate_action(actor.action_for(button + "_TAP", 0)) and not innate:
		return false
	if action.is_empty() or (not innate and actor.loadout.level == 0):
		return false
	var weapon: Dictionary = _action_weapon(action)
	if not innate and not actor.loadout.can_equip_weapon(str(weapon.get("id", ""))).is_empty():
		return false
	var family: String = action.get("animation_family", weapon.get("animation_family", ""))
	action["animation_family"] = family
	action["innate_action"] = innate
	action["dual_wield"] = not innate and actor.loadout.is_dual_wielding() and family == "SINGLE_BLADE"
	var profile: Dictionary = actor.arena.database.combat_feel.get(family, {})
	for key in ["charge_duration", "charge_move_multiplier", "charge_release_startup"]:
		action[key] = action.get(key, profile.get(key, {"charge_duration": .6, "charge_move_multiplier": 0.0, "charge_release_startup": .08}[key]))
	var mods: Dictionary = passives.actor_modifiers("stat_update", null, action)
	var speed := maxf(.1, 1.0 + float(mods.get("charge_time_multiplier", 0.0)) + float(statuses.modifiers().get("charge_time_multiplier", 0.0)))
	action.charge_duration = maxf(actor.input_router.hold_threshold if actor.input_router else .25, float(action.charge_duration) * speed)
	if not actor.movement_actions.stand_for_action(): return false
	charge_action = action
	charge_button = button
	charge_time = 0.0
	charge_ready = false
	defense.begin_charge()
	state = "CHARGING"
	actor.face_action_target()
	if actor.animation.has_method("play_charge"):
		actor.animation.play_charge(action)
	sync_precision_glow()
	return true

func _release_charge() -> void:
	var action := charge_action.duplicate(true)
	var progress := charge_progress()
	var elapsed := charge_time
	var charged: bool = elapsed + .00001 >= (actor.input_router.hold_threshold if actor.input_router else .25)
	var semantic := charge_button + ("_CHARGE" if charged else "_TAP")
	var release_guard: Dictionary = action.get("charge_release_guard_window", {}).duplicate(true) if not action.get("charge_guard_window", {}).is_empty() and defense.precision_window_active() else {}
	# Consume the physical release and any old combo/held input exactly once.
	var held_guard := guard_requested
	var held_key := guard_key_held
	var held_pointer := guard_pointer_held
	if actor.input_router:
		actor.input_router.cancel()
	else:
		clear_input_intent()
	guard_requested = held_guard
	guard_key_held = held_key
	guard_pointer_held = held_pointer
	var overrides: Dictionary = {}
	if charged:
		var formula: Dictionary = action.get("formula", {}).duplicate(true)
		for stat in formula:
			formula[stat] = float(formula[stat]) * lerpf(.7, 1.0, progress)
		overrides = {"formula": formula, "charge_ratio": progress, "charged_release": true,
			"startup": action.get("charge_release_startup", .08),
			"poise_damage": float(action.get("poise_damage", 0.0)) * lerpf(.75, 1.0, progress)}
		if not release_guard.is_empty():
			overrides["guard_window"] = release_guard
	if semantic == "PRIMARY_TAP" and actor.attack_assist.request_primary(): return
	weapon_action(semantic, overrides)
	sync_precision_glow()

func clear_input_intent() -> void:
	queued_command.clear()
	clear_charge()
	guard_requested = false
	guard_key_held = false
	guard_pointer_held = false
	if defense != null:
		defense.stop_guard()
	sync_precision_glow()

func clear_pointer_intent() -> void:
	clear_charge()
	guard_pointer_held = false
	guard_requested = guard_key_held
	if not guard_requested:
		defense.stop_guard()
	sync_precision_glow()

func clear_charge() -> void:
	charge_action.clear()
	charge_button = ""
	charge_time = 0.0
	charge_ready = false
	if state == "CHARGING":
		state = "NORMAL"

func _try_held_charge() -> void:
	if not actor.is_human_controlled() or actor.input_router == null or not queued_command.is_empty():
		return
	for button in ["PRIMARY", "SECONDARY"]:
		if button == "SECONDARY" and not defense.shield().is_empty():
			continue
		var key := "attack_primary" if button == "PRIMARY" else "attack_secondary"
		if actor.input_router.held.has(key) and Input.is_action_pressed(key):
			var held_time := float(actor.input_router.clock) - float(actor.input_router.held[key])
			if held_time >= actor.input_router.hold_threshold:
				if _weapon_transition_ready() and runner.busy() and not runner.current_action.get("is_skill", false):
					runner.cancel_action()
					state = "NORMAL"
				if can_start():
					begin_charge(button)
			return

func _weapon_transition_ready() -> bool:
	if hitstop_remaining > 0.0 or stopped_this_tick: return false
	if can_start(): return true
	if state != "ACTION" or not runner.busy() or runner.action_phase != "RECOVERY": return false
	var action: Dictionary = runner.current_action
	# Keep at least 65% of recovery even for legacy actions with oversized
	# combo windows. Finishers can require their complete recovery with zero.
	var window := minf(float(action.get("combo_window", .08)), float(action.get("recovery", .2)) * .35)
	var end := float(action.get("startup", .1)) + float(action.get("active", .1)) + float(action.get("recovery", .2))
	return runner.action_time + .00001 >= end - window

func _can_cancel_into(kind: String) -> bool:
	if hitstop_remaining > 0.0 or stopped_this_tick: return false
	if state in ["CHARGING", "GUARD"] or can_start():
		return true
	if state != "ACTION" or not runner.busy():
		return false
	var action: Dictionary = runner.current_action
	if kind == "dodge" and runner.action_phase == "STARTUP":
		return bool(action.get("dodge_cancel_startup", true))
	if runner.action_phase != "RECOVERY":
		return false
	if kind == "dodge":
		return bool(action.get("dodge_cancel_recovery", true))
	if not action.get("is_skill", false):
		return bool(action.get("skill_cancel_recovery", true))
	var end := float(action.get("startup", .1)) + float(action.get("active", .1)) + float(action.get("recovery", .2))
	return end - runner.action_time <= float(action.get("skill_chain_window", _feel("skill_chain_window", .12)))

func skill_input_failure(action: Dictionary, selecting := false) -> String:
	if _control_blocked() or state in ["DEAD", "HITSTUN", "KNOCKDOWN", "SWITCH", "EXPOSED", "GUARD_BROKEN", "GRABBED", "GRABBING", "JUMP"]:
		return "当前状态不能衔接技能"
	return action_failure(action, true, selecting)

func request_skill(slot: int, selected_action: Dictionary = {}) -> bool:
	if slot < 0 or slot > 2:
		return false
	var action: Dictionary = actor.skill_at(slot).duplicate(true) if selected_action.is_empty() else selected_action.duplicate(true)
	if action.is_empty():
		return fail("此槽位尚未备战技能")
	var id: String = action.get("id", "")
	action["skill_set"] = action.get("skill_set", actor.loadout.current_set)
	action["innate_action"] = actor.is_innate_action(action)
	var reason := skill_input_failure(action)
	if not reason.is_empty():
		return fail(reason)
	if queued_command.get("kind", "") == "dodge_dash":
		return false
	if _can_cancel_into("skill"):
		_cancel_for_transition()
		return use_action(action)
	# A single latest intent prevents a key mash from scheduling a long combo.
	if actor.input_router:
		actor.input_router.cancel()
	queued_command = {"kind": ["skill_q", "skill_e", "skill_r"][slot], "action_id": id,
		"skill_set": actor.loadout.current_set, "action": action.duplicate(true),
		"expires": input_time + _feel("skill_buffer", .35)}
	last_condition_failed = ""
	return true

func _cancel_for_transition() -> void:
	var held_guard := guard_requested
	var held_key := guard_key_held
	var held_pointer := guard_pointer_held
	if actor.input_router:
		actor.input_router.cancel()
	else:
		clear_input_intent()
	if runner.busy():
		runner.cancel_action()
	state = "NORMAL"
	guard_requested = held_guard
	guard_key_held = held_key
	guard_pointer_held = held_pointer
	combo = 0
	combo_timeout = 0.0

func _dodge_failure() -> String:
	if not in_combat or actor.resources.unlimited.get("Stamina", false) or actor.resources.max_value("Stamina") <= 0.0:
		return ""
	var cost := costs_for({"id": "dodge", "presentation_type": "DODGE", "costs": {"Stamina": 1}})
	return "" if actor.resources.can_pay(cost) else "体力不足"

func request_dodge() -> bool:
	if _control_blocked() or state in ["DEAD", "HITSTUN", "KNOCKDOWN", "SWITCH", "DODGE", "EXPOSED", "GUARD_BROKEN", "GRABBED", "GRABBING", "JUMP"]:
		return false
	var reason := _dodge_failure()
	if not reason.is_empty():
		return fail(reason)
	if _can_cancel_into("dodge"):
		_cancel_for_transition()
		return start_dodge()
	if state == "ACTION":
		if actor.input_router:
			actor.input_router.cancel()
		queued_command = {"kind": "dodge_dash", "expires": input_time + _feel("dodge_buffer", .20)}
		return true
	return false

func _drain_queued_command() -> void:
	if queued_command.is_empty():
		return
	var dodge: bool = queued_command.kind == "dodge_dash"
	if not _can_cancel_into("dodge" if dodge else "skill"):
		return
	var intent := queued_command.duplicate()
	queued_command.clear()
	var action: Dictionary = intent.get("action", actor.arena.database.skills.get(intent.get("action_id", ""), {})).duplicate(true)
	if not dodge:
		action["skill_set"] = intent.get("skill_set", actor.loadout.current_set)
	var reason := _dodge_failure() if dodge else action_failure(action, true)
	if not reason.is_empty():
		fail(reason)
		return
	_cancel_for_transition()
	if dodge:
		start_dodge()
	else:
		use_action(action)

func costs_for(action: Dictionary) -> Dictionary:
	var costs: Dictionary = action.get("costs", {}).duplicate(true)
	var mods: Dictionary = statuses.modifiers()
	_merge_modifiers(mods, passives.actor_modifiers("stat_update", null, action, _action_weapon(action)))
	for resource in costs.keys():
		var rule: Dictionary = actor.loadout.resource_rules.get(resource, {})
		var key: String = str(resource).to_lower() + "_cost_override"
		if mods.has(key):
			costs[resource] = maxf(0.0, float(mods[key]))
		var overrides: Dictionary = rule.get("cost_overrides", {})
		if overrides.has(action.get("presentation_type", "")):
			costs[resource] = maxf(0.0, float(overrides[action.presentation_type]))
	if mods.has("weapon_energy_cost_override") and action.get("is_skill", false) and action.get("presentation_type", "") == "WEAPON_ACTION":
		costs["Energy"] = maxf(0.0, float(mods.weapon_energy_cost_override))
	return costs

func use_action(definition: Dictionary) -> bool:
	var action := definition.duplicate(true)
	if actor.is_human_controlled() and not action.has("cast_intent"): actor.arena.refresh_aim()
	var dual_sequence := _dual_sequence_for(action)
	action["dual_wield"] = not dual_sequence.is_empty()
	if action.dual_wield:
		action["dual_sequence"] = dual_sequence
	last_condition_failed = action_failure(action)
	if not last_condition_failed.is_empty():
		return fail(last_condition_failed)
	if not actor.movement_actions.stand_for_action(): return false
	var action_weapon: Dictionary = _action_weapon(action)
	if action.get("dual_wield", false):
		action["dual_weapons"] = [actor.loadout.weapon_at(0).duplicate(true), actor.loadout.weapon_at(1).duplicate(true)]
		action["dual_weapon_order"] = actor.arena.database.combat_feel.get("DUAL_SWORD", {}).get("strike_order", [1, 0]).duplicate()
	action["weapon_snapshot"] = action_weapon.duplicate(true)
	if action.get("id", "") == "shield_raise":
		action["shield_raise"] = true
	action["animation_family"] = action_weapon.get("animation_family", action.get("animation_family", "SINGLE_BLADE"))
	var passive_mods: Dictionary = passives.modifiers("damage_before", context(null, action), action_weapon)
	var stat_mods: Dictionary = passives.actor_modifiers("stat_update", null, action, action_weapon)
	_merge_modifiers(stat_mods, statuses.modifiers())
	var action_speed := maxf(.1, 1.0 + float(stat_mods.get("action_speed_multiplier", 0.0)))
	for phase in ["startup", "active", "recovery"]:
		action[phase] = float(action.get(phase, .1)) / action_speed
	for timing in ["combo_window", "skill_chain_window"]:
		if action.has(timing): action[timing] = float(action[timing]) / action_speed
	if action.get("dual_wield", false):
		var profile: Dictionary = actor.arena.database.combat_feel.get("DUAL_SWORD", {})
		var skill_profile: Dictionary = profile.get("skill_templates", {}).get(dual_sequence.template, {}) if action.get("is_skill", false) else {}
		var cycle := (float(action.startup) + float(action.active) + float(action.recovery)) * float(profile.get("cycle_multiplier", 1.0))
		action.startup *= float(profile.get("startup_multiplier", .6))
		var strike_active := maxf(.04 / action_speed, float(action.active) * float(profile.get("strike_active_multiplier", .5)))
		strike_active = maxf(.04 / action_speed, float(skill_profile.get("strike_active", strike_active * action_speed)) / action_speed)
		var gap := maxf(float(skill_profile.get("strike_gap", profile.get("strike_gap", .1))) / action_speed, strike_active + .02 / action_speed)
		action.active = gap + strike_active
		action.recovery = maxf(float(profile.get("minimum_recovery", .08)) / action_speed, cycle - float(action.startup) - float(action.active))
		action["dual_first_active"] = strike_active
		action["dual_strike_gap"] = gap
		action["dual_second_at"] = float(action.startup) + gap
		action["dual_second_fired"] = false
	for window_name in ["guard_window", "counter_stance", "hyper_armor"]:
		for field in ["start", "end", "perfect_window"]:
			if action.get(window_name, {}).has(field):
				action[window_name][field] = float(action[window_name][field]) / action_speed
	if action.get("presentation_type", "") == "CASTER_ACTION":
		action["range"] = _action_reach(action, actor.target_for_action(action))
	var area_scale := 1.0 + float(passive_mods.get("area_multiplier", 0.0))
	for dimension in ["radius", "width", "length", "explosion_radius"]:
		if action.has(dimension):
			action[dimension] *= area_scale
	var paid_costs: Dictionary = {}
	var costs := costs_for(action)
	for resource in costs:
		paid_costs[resource] = actor.resources.current(resource)
	if not actor.resources.pay(costs):
		return fail("资源不足")
	for resource in costs:
		paid_costs[resource] = maxf(0, float(paid_costs[resource]) - actor.resources.current(resource))
	action["paid_costs"] = paid_costs
	for id in action.get("gains", {}):
		actor.resources.change(id, float(action.gains[id]))
	cooldowns[action.get("id", "")] = float(action.get("cooldown", 0.0))
	serial += 1
	action["instance_id"] = str(actor.get_instance_id()) + ":" + str(serial)
	action["sequence_bonus"] = passives.prepare_action(action, action_weapon)
	action["status_modifiers"] = statuses.modifiers()
	action["weapon_snapshot"] = action_weapon.duplicate(true)
	action["stats_snapshot"] = context().stats
	action["first_damage"] = first_damage
	if not action.get("is_reaction", false) and action.get("targeting", "") != "SELF":
		actor.face_action_target(action)
	action_origin = actor.global_position
	action_direction = actor.facing
	action_target = actor.target_for_action(action)
	action_point = actor.aim_world_point(action)
	if is_instance_valid(action_target) and action.get("targeting", "") == "TARGET":
		action_point = action_target.global_position
	var limit := float(action.get("range", 10.0))
	if action.get("targeting", "") != "TARGET": action_point = actor.arena.clamp_aim_point(action_origin, action_point, limit)
	state = "ACTION"
	runner.start_action(action)
	actor.attack_assist.leap = actor.attack_assist.leap_plan(action_target,action) if action.get("leap_motion",false) else {}
	actor.animation.play_action(action)
	if _is_grab(action):
		_flash(Color("ff293b"), .25)
	_defense_cues()
	sync_precision_glow()
	passives.trigger("action_started", context(action_target, action), action_weapon)
	if action.get("is_skill", false):
		skill_used.emit(action.get("id", ""))
	return true

func _execute_active() -> void:
	var action: Dictionary = runner.current_action
	if action.get("leap_motion",false):
		actor.attack_assist.leap.clear()
		action_origin = actor.global_position
		if not is_instance_valid(action_target) or action_target.combat.state == "DEAD" or actor.global_position.distance_to(action_target.global_position)>2.2: return
		action_point = action_target.global_position
	if action.get("shield_raise", false):
		return
	# Targeted possession locks its original victim. A disappearing or newly
	# ineligible target must not turn the already-paid startup into a lost charge.
	if action.get("targeting", "") == "TARGET":
		for effect in action.get("effects", []):
			if effect.get("type", "") != "possess" or effect.get("target", "target") != "self": continue
			if not is_instance_valid(action_target): action_target = null
			var reason := _possession_failure(actor, action_target, effect)
			if reason.is_empty():
				reason = CombatConditions.check_all(action.get("conditions", []), context(action_target, action))
			if reason.is_empty() and ((action.get("target_relation", "hostile") != "any" and not actor.arena.are_hostile(actor, action_target)) or actor.global_position.distance_to(action_target.global_position) > float(action.get("range", 12)) or not actor.arena.line_clear(actor.global_position, action_target.global_position)):
				reason = "附身目标已离开有效范围"
			if not reason.is_empty():
				_refund_failed_possession(action, reason)
				return
	for effect in action.get("effects", []):
		if effect.get("target", "target") == "self" or action.get("targeting", "") == "SELF" or action.get("presentation_type", "") == "VFX_ONLY":
			var once: Dictionary = effect.duplicate(true)
			if action.get("dual_sequence", {}).get("origin", "") == "after_movement" and once.get("type", "") == "dash":
				once["distance"] = _approach_distance(float(once.get("distance", 3.0)), action)
			apply_effect(once, actor, true)
			# A form/control effect may cancel this action. Its old hitboxes and
			# movement must not continue from the replacement body/controller.
			if not runner.busy() or runner.current_action.get("instance_id", "") != action.get("instance_id", ""):
				return
	var dash := float(action.get("dash_distance", action.get("dash", 0.0)))
	if dash > 0.0:
		if action.get("dual_sequence", {}).get("origin", "") == "after_movement":
			dash = _approach_distance(dash, action)
		actor.safe_displace(action_direction * dash)
	if action.get("dual_sequence", {}).get("origin", "") == "after_movement":
		action_origin = actor.global_position
	if action.get("dual_wield", false):
		_execute_dual_strike(0)
	else:
		actor.arena.perform_action(actor, action, action_origin, action_direction, action_point, action_target)
	statuses.consume_for(action)

func _approach_distance(distance: float, action: Dictionary) -> float:
	var travel := maxf(0.0, distance)
	var direction := Vector3(action_direction.x, 0.0, action_direction.z).normalized()
	var corridor := maxf(.7, float(action.get("width", 1.25)) * .5)
	for target in actor.arena.targets_for(actor):
		if not is_instance_valid(target) or target.combat.state == "DEAD":
			continue
		var offset: Vector3 = target.global_position - actor.global_position
		offset.y = 0.0
		var along := offset.dot(direction)
		if along > 0.0 and (offset - direction * along).length() <= corridor:
			travel = minf(travel, maxf(0.0, along - .95))
	return travel

func _tick_dual_followup() -> void:
	if state != "ACTION" or not runner.busy() or runner.action_phase != "ACTIVE":
		return
	var action: Dictionary = runner.current_action
	if action.get("dual_wield", false) and not action.get("dual_second_fired", false) and runner.action_time + .00001 >= float(action.dual_second_at):
		action.dual_second_fired = true
		_execute_dual_strike(1)

func _execute_dual_strike(index: int) -> void:
	if state != "ACTION" or not runner.busy():
		return
	var packet: Dictionary = runner.current_action.duplicate(true)
	packet["dual_strike_index"] = index
	var weapon_index := int(packet.dual_weapon_order[index])
	packet["dual_weapon_index"] = weapon_index
	packet["parent_instance_id"] = packet.instance_id
	packet.instance_id = str(packet.parent_instance_id) + ":blade:" + str(index)
	packet.weapon_snapshot = packet.dual_weapons[weapon_index].duplicate(true)
	packet.active = packet.dual_first_active
	# Parent-only work has already happened. Each child carries only on-hit
	# effects, so neither the follow-up nor a hit handler can repeat movement.
	var hit_effects: Array = []
	for effect in packet.get("effects", []):
		if effect.get("target", "target") != "self" and effect.get("type", "") not in ["dash", "teleport"]:
			hit_effects.append(effect)
	packet.effects = hit_effects
	for field in ["dash", "dash_distance", "costs", "gains"]:
		packet.erase(field)
	actor.animation.play_dual_strike(index)
	actor.arena.perform_action(actor, packet, action_origin, action_direction, action_point, action_target)

func _finished(action: Dictionary) -> void:
	if state == "ACTION":
		state = "NORMAL"
		_drain_queued_command()
		if runner.busy() or state != "NORMAL":
			return
		_consume_weapon_buffer()

func _consume_weapon_buffer() -> void:
	if not actor.is_human_controlled() or actor.input_router == null or not queued_command.is_empty():
		return
	if not _weapon_transition_ready(): return
	var buffer: RefCounted = actor.input_router.buffer
	buffer.prune(actor.input_router.clock)
	for i in range(buffer.entries.size() - 1, -1, -1):
		var kind: String = buffer.entries[i].kind
		if kind in ["PRIMARY_TAP", "SECONDARY_TAP"]:
			buffer.clear()
			if runner.busy():
				runner.cancel_action()
			state = "NORMAL"
			weapon_action(kind)
			return

func switch_set() -> bool:
	if _control_blocked():
		return fail("请先离开梯子")
	if actor.loadout.uses_paired_weapons():
		if state in ["DEAD", "HITSTUN", "KNOCKDOWN", "EXPOSED", "GUARD_BROKEN", "GRABBED", "GRABBING", "SWITCH", "JUMP"]:
			return fail("当前状态不能切换技能组")
		actor.loadout.current_set = 1 - actor.loadout.current_set
		actor.loadout.changed.emit()
		combat_set_switched.emit(actor.loadout.current_set)
		return true
	if not can_start():
		return fail("当前状态不能切换战斗组")
	if not actor.movement_actions.stand_for_action(): return false
	actor.loadout.current_set = 1 - actor.loadout.current_set
	state = "SWITCH"
	switch_time = .35
	combo = 0
	if actor.input_router:
		actor.input_router.cancel()
	actor.loadout.changed.emit()
	combat_set_switched.emit(actor.loadout.current_set)
	return true

func start_dodge() -> bool:
	if not can_start():
		return false
	if not actor.movement_actions.stand_for_action(): return false
	dodge_is_dash = not in_combat
	dodge_in_water = actor.swimming
	dodge_paid = 0.0
	if not dodge_is_dash:
		var free: bool = actor.resources.unlimited.get("Stamina", false) or actor.resources.max_value("Stamina") <= 0.0
		var cost := float(costs_for({"id": "dodge", "presentation_type": "DODGE", "costs": {"Stamina": 1}}).get("Stamina", 1.0))
		if not free and not actor.resources.pay({"Stamina": cost}):
			return fail("体力不足")
		dodge_paid = 0.0 if free else cost
	state = "DODGE"
	dodge_time = 0.0
	perfect_refunded = false
	stamina_clock = 0.0
	dodge_direction = actor.move_direction if actor.move_direction.length_squared() > .01 else actor.facing
	if dodge_in_water: actor.facing = dodge_direction
	if actor.input_router:
		actor.input_router.cancel()
	actor.animation.play_dodge(dodge_is_dash)
	if not dodge_in_water: actor.arena.sound.play_tone("roll")
	return true

func invulnerable() -> bool:
	return state == "DODGE" and not dodge_is_dash and dodge_time < .20 or statuses.has_status("invulnerable")

func engage() -> void:
	in_combat = true
	combat_timeout = 5.0

func source_data(action: Dictionary, target: Node) -> Dictionary:
	var ctx := context(target, action)
	ctx["first_hit"] = first_damage or (not first_damage_instance.is_empty() and first_damage_instance == action.get("instance_id", ""))
	ctx["first_damage"] = ctx.first_hit
	var weapon: Dictionary = action.get("weapon_snapshot", actor.loadout.combat_weapon())
	ctx["weapon_type"] = weapon.get("weapon_type", "")
	var result := {"stats": action.get("stats_snapshot", ctx.stats), "weapon_scaling": float(weapon.get("weapon_scaling", 0.0)), "damage_bonus": float(action.get("sequence_bonus", 0.0)), "crit_chance": .05, "crit_multiplier": 1.5}
	_merge_modifiers(result, passives.modifiers("damage_before", ctx, weapon))
	var outgoing_statuses: Dictionary = action.get("status_modifiers", statuses.modifiers()).duplicate()
	# Status vulnerability belongs to its bearer. Only offensive passives (such
	# as Hex Binding) may add target vulnerability through the source packet.
	for key in outgoing_statuses.keys():
		if str(key).begins_with("vulnerability") or key in ["all_vulnerability", "damage_taken_bonus", "damage_taken"]:
			outgoing_statuses.erase(key)
	_merge_modifiers(result, outgoing_statuses)
	for modifier in action.get("damage_modifiers", []):
		if CombatConditions.check_all(modifier.get("conditions", []), ctx).is_empty():
			result.damage_bonus += float(modifier.get("damage_bonus", 0.0))
	return result

func target_data() -> Dictionary:
	var result := {"armor": actor.stats.get_final_stat("Armor"), "resistance": actor.resistances.duplicate(), "vulnerability": {}, "damage_taken_bonus": 0.0, "invulnerable": invulnerable()}
	var mods: Dictionary = statuses.modifiers()
	for key in mods:
		if str(key).begins_with("vulnerability_"):
			result.vulnerability[str(key).trim_prefix("vulnerability_").to_upper()] = mods[key]
		elif key in ["vulnerability", "all_vulnerability"]:
			result.vulnerability["ALL"] = mods[key]
		elif key == "damage_taken_bonus":
			result.damage_taken_bonus += float(mods[key])
	var passive_mods: Dictionary = passives.actor_modifiers("stat_update")
	result.damage_taken_bonus += float(passive_mods.get("damage_taken_bonus", passive_mods.get("damage_taken", 0.0)))
	return result

func hit_target(target: Node, action: Dictionary, direction: Vector3) -> Dictionary:
	if not is_instance_valid(target) or not actor.arena.are_hostile(actor, target):
		return {"blocked": true, "final": 0.0, "reason": "non_hostile"}
	if not is_instance_valid(target) or target.combat.state == "DEAD":
		return {}
	var packet := action.duplicate(true)
	packet["source_data"] = source_data(action, target)
	var result: Dictionary = target.hurtbox.receive(packet, actor, direction)
	if not result.get("blocked", true):
		engage()
		if float(result.get("final", 0.0)) > 0.0:
			if first_damage:
				first_damage_instance = action.get("instance_id", "")
			first_damage = false
		last_damage = result
		damage_dealt.emit(result)
		if float(result.get("final", 0.0)) > 0.0:
			passives.record_hit(action.get("weapon_snapshot", actor.loadout.combat_weapon()))
		var ctx := context(target, action)
		ctx["crit"] = result.get("crit", false)
		ctx["critical"] = ctx.crit
		passives.trigger("damage_after", ctx, action.get("weapon_snapshot", actor.loadout.combat_weapon()))
		if result.get("crit", false):
			critical_hit.emit(result)
	return result

func receive_damage(action: Dictionary, source: Node, direction: Vector3, dot := false) -> Dictionary:
	# Hurtbox/direct script entry points obey the same relationship as targeting.
	# Environmental damage has no source; resource/self-cost effects are separate.
	if is_instance_valid(source) and not actor.arena.are_hostile(source, actor):
		return {"blocked": true, "final": 0.0, "reason": "non_hostile"}
	if state == "DEAD":
		return {"blocked": true, "final": 0.0}
	if invulnerable():
		if state == "DODGE" and dodge_time <= .10 and not perfect_refunded:
			perfect_refunded = true
			actor.resources.change("Stamina", dodge_paid)
			perfect_dodge.emit()
			passives.trigger("perfect_dodge", context(source, action))
			actor.arena.float_text(actor.global_position + Vector3.UP * 2, "完美闪避", Color("f8de91"))
		return {"blocked": true, "final": 0.0}
	var guarded: Dictionary = defense.resolve(action, source, direction, dot)
	var outcome: String = guarded.outcome
	sync_precision_glow()
	if outcome in ["parry", "counter"]:
		engage()
		actor.arena.sound.play_tone("charge")
		actor.arena.float_text(actor.global_position + Vector3.UP * 2, "负剑·反击" if outcome == "counter" else "精准格挡", Color.WHITE)
		# A deflected projectile does not remotely stagger its caster.
		if is_instance_valid(source):
			source.combat.engage()
			if float(action.get("projectile_speed", 0.0)) <= 0.0 and actor.global_position.distance_to(source.global_position) <= 4.5:
				source.combat.expose()
		if outcome == "counter":
			begin_counter(source, str(guarded.get("counter_action", "fujian_counter")))
		last_damage = {"raw": 0.0, "final": 0.0, "crit": false, "blocked": true, "defense": outcome}
		Impact.deliver(actor, source, action, direction, last_damage, dot)
		return last_damage
	if outcome == "guard_break":
		force_control("GUARD_BROKEN", .85)
		actor.arena.float_text(actor.global_position + Vector3.UP * 2, "防御崩溃", Color("ffbe70"))
	var source_stats: Dictionary = action.get("source_data", {})
	if source_stats.is_empty() and is_instance_valid(source):
		source_stats = source.combat.source_data(action, actor)
	var defenses := target_data()
	for key in source_stats:
		if str(key).begins_with("vulnerability_"):
			var type := str(key).trim_prefix("vulnerability_").to_upper()
			defenses.vulnerability[type] = float(defenses.vulnerability.get(type, 0.0)) + float(source_stats[key])
	var result := CombatDamage.calculate(action, source_stats, defenses)
	if result.get("blocked", false):
		return result
	result["defense"] = outcome
	if outcome == "block":
		var reduction: float = guarded.physical_reduction if action.get("damage_type", "PHYSICAL") == "PHYSICAL" else guarded.elemental_reduction
		result.final = maxf(0.0, float(result.final) * (1.0 - reduction))
		result["guarded"] = true
		result["blocked"] = float(result.final) <= 0.0
		stamina_clock = 0.0
		if defense.guard_held:
			guard_counter_time = .75
			last_block_source = weakref(source) if is_instance_valid(source) else null
	# Death signals fire synchronously inside receive(), so attribution must be
	# visible before the health pool reaches zero. Fully absorbed hits do no HP harm.
	if float(result.final) > actor.health.shield:
		actor.last_damage_source = weakref(source) if is_instance_valid(source) else null
	actor.health.receive(float(result.final))
	Impact.deliver(actor, source, action, direction, result, dot)
	last_damage = result
	engage()
	actor.arena.float_text(actor.global_position + Vector3.UP * 1.8, ("格挡 " if outcome == "block" else ("暴击 " if result.crit else "")) + str(roundi(result.final)), Color("d9f7ff") if outcome == "block" else (Color("ffcb68") if result.crit else Color("f5e9d0")), actor, true)
	if state == "DEAD":
		return result
	if not dot and float(result.final) > 0.0 and actor.brain != null:
		actor.brain.notice_damage(source, action.get("awareness_origin"))
	if outcome == "block":
		return result
	if not dot and _is_grab(action):
		_start_grab(source, float(action.get("grab_duration", 1.0)))
		return result
	if not dot:
		var poise_damage := float(action.get("poise_damage", 0.0))
		poise_damage *= 1.0 + float(source_stats.get("poise_damage_bonus", 0.0))
		current_poise -= poise_damage
		poise_delay = 1.2 if poise_damage > 0 else poise_delay
		if current_poise <= 0.0 and not has_hyper_armor() and state not in ["GUARD_BROKEN", "GRABBED", "GRABBING"]:
			force_control("HITSTUN", .4)
			current_poise = max_poise()
			poise_broken.emit()
			if action.get("knockdown", false) and not actor.immune_to_knockdown:
				state = "KNOCKDOWN"
				control_time = 1.1
			if float(action.get("launch_force", 0.0)) > 0 and not actor.immune_to_launch:
				actor.velocity.y = float(action.launch_force)
				control_time = maxf(control_time, .6)
			knockback = direction * float(action.get("knockback_force", 2.0))
			actor.animation.play_hit(state)
	for effect in action.get("effects", []):
		if effect.get("target", "target") != "self" and effect.get("type", "") not in ["dash", "teleport"] and action.get("presentation_type", "") != "VFX_ONLY":
			apply_effect(effect, source)
	return result

func _possession_failure(caster: Node, target: Node, effect: Dictionary) -> String:
	var control: Node = actor.arena.get("control")
	if not is_instance_valid(control) or caster.arena != actor.arena or control.controlled_actor() != caster:
		return "只有当前受控单位可以发动附身"
	if not is_instance_valid(target) or target == caster or target.arena != actor.arena or target.combat.state == "DEAD":
		return "没有可附身的有效目标"
	if target.get_meta("traversal_locked", false):
		return "目标正在攀爬，无法附身"
	if effect.has("max_level_delta") and target.loadout.level > caster.loadout.level + int(effect.max_level_delta):
		return "目标等级高于附身允许范围"
	return ""

func _refund_failed_possession(action: Dictionary, reason: String) -> void:
	for resource in action.get("paid_costs", {}):
		actor.resources.change(resource, float(action.paid_costs[resource]))
	cooldowns[action.get("id", "")] = 0.0
	runner.cancel_action()
	clear_input_intent()
	state = "NORMAL"
	fail(reason)

func apply_effect(effect: Dictionary, source: Node = null, target_is_locked := false) -> void:
	var effect_context: Dictionary = source.combat.context(actor) if is_instance_valid(source) else context()
	if not CombatConditions.check_all(effect.get("conditions", []), effect_context).is_empty():
		return
	var kind: String = effect.get("type", "")
	match kind:
		"possess":
			var caster: Node = source if is_instance_valid(source) else actor
			var control: Node = actor.arena.get("control")
			# Self casts resolve their selected target; on-hit effects already run
			# on that victim. Only the locally controlled caster may lease input.
			var target: Node = actor if caster != actor else (action_target if target_is_locked and is_instance_valid(action_target) else null)
			if caster == actor and not target_is_locked: target = caster.target_for_action()
			var reason := _possession_failure(caster, target, effect)
			if not reason.is_empty():
				caster.combat.fail(reason)
			elif not control.possess(target, float(effect.get("duration", 6.0)), effect.get("max_level_delta", null)):
				caster.combat.fail("当前无法附身此目标")
		"transform":
			var form: Variant = actor.get("form")
			if not is_instance_valid(form) or not form.apply_enemy_form(str(effect.get("unit_id", "")), float(effect.get("duration", 6.0))):
				fail("当前无法变为此形态")
		"berserk":
			var control: Node = actor.arena.get("control")
			if not is_instance_valid(control) or not control.autopilot(actor, float(effect.get("duration", 6.0))):
				fail("当前无法进入自动战斗")
		"resource":
			actor.resources.change(effect.get("resource", "Energy"), float(effect.get("amount", effect.get("value", 0.0))))
		"hp_percent":
			actor.resources.change("HP", actor.resources.current("HP") * float(effect.get("value", -.08)))
		"status", "control":
			var id: String = effect.get("status", "")
			if kind == "control" and actor.is_boss:
				id = effect.get("boss_status", "binding_slow")
			var definition: Dictionary = actor.arena.database.status_effects.get(id, {}).duplicate(true)
			definition.merge(effect, true)
			if not CombatConditions.check_all(definition.get("conditions", []), effect_context).is_empty():
				return
			if definition.has("formula"):
				var packet := {"formula": definition.formula, "damage_type": definition.get("damage_type", "FIRE"), "can_crit": false, "is_dot": true}
				packet["source_data"] = source.combat.source_data(packet, actor) if is_instance_valid(source) else {}
				definition["tick_damage"] = packet
			statuses.add_status(id, definition, source)
		"shield":
			var formula: Dictionary = effect.get("formula", {"base": effect.get("value", 100)})
			var result := CombatDamage.calculate({"formula": formula, "can_crit": false}, {"stats": context().stats}, {})
			actor.health.shield = float(result.raw)
			statuses.add_status("shield", {"duration": effect.get("duration", 20.0)}, source)
		"teleport":
			var target: Vector3 = action_point if runner.busy() else actor.aim_world_point()
			var offset: Vector3 = target - actor.global_position
			offset.y = 0
			actor.safe_displace(offset.limit_length(float(effect.get("distance", 6.0))))
		"dash":
			actor.safe_displace(action_direction * float(effect.get("distance", 3.0)))
		"heal":
			actor.resources.change("HP", actor.resources.max_value("HP") * float(effect.get("percent", .3)))
		"remove_aggro", "disengage":
			actor.arena.clear_aggro(actor)
		"modifier":
			var definition := {"duration": effect.get("duration", 6.0), "effects": [effect]}
			statuses.add_status(effect.get("stat", "modifier"), definition, source)

func max_poise() -> float:
	var mods: Dictionary = passives.actor_modifiers("stat_update")
	return maxf(1.0, base_poise + float(mods.get("Poise", mods.get("poise", 0.0))))

func movement_multiplier() -> float:
	if statuses.has_status("root"):
		return 0.0
	var mods: Dictionary = statuses.modifiers()
	return maxf(0.0, 1.0 + float(mods.get("move_speed", mods.get("move_speed_multiplier", 0.0))))

func has_permission(weapon_type: String) -> bool:
	for passive in passives.definitions():
		if not CombatConditions.check_all(passive.get("conditions", []), context()).is_empty():
			continue
		for effect in passive.get("effects", []):
			if effect.get("type", "") == "proficiency" and weapon_type in effect.get("value", []) and CombatConditions.check_all(effect.get("conditions", []), context()).is_empty():
				return true
	return false

func _uses_inventory_slot(index: int) -> bool:
	if actor.inventory == null:
		return false
	if not actor.loadout.sandbox_mode:
		return true
	return index >= 0 and index < actor.inventory.quickslots.size() and not str(actor.inventory.quickslots[index]).is_empty()

func quick_item_failure(index: int) -> String:
	if _uses_inventory_slot(index):
		if index < 0 or index >= actor.inventory.quickslots.size():
			return "快捷栏不存在"
		return actor.inventory.can_use(actor.inventory.quickslots[index])
	if not can_start() or index < 0 or index > 3:
		return "当前动作尚未结束"
	var id := "item_" + str(index)
	if quick_counts[index] <= 0 or float(cooldowns.get(id, 0.0)) > 0.0:
		return "道具不足或正在冷却"
	if index == 0 and actor.health.ratio() >= 1.0:
		return "生命已满"
	if index in [1, 2]:
		var resource := "Energy"
		if actor.resources.max_value(resource) <= 0.0 or actor.resources.current(resource) >= actor.resources.max_value(resource):
			return "当前职业不需要补充此资源"
	return ""

func use_quick_item(index: int) -> bool:
	if _control_blocked():
		return fail("请先离开梯子")
	if _uses_inventory_slot(index):
		if not actor.inventory.use_quick_slot(index):
			return fail(actor.inventory.last_error)
		return true
	var reason := quick_item_failure(index)
	if not reason.is_empty():
		return fail(reason)
	var id := "item_" + str(index)
	quick_counts[index] -= 1
	cooldowns[id] = 4.0
	match index:
		0: apply_effect({"type": "heal", "percent": .3})
		1: actor.resources.change("Energy", 40)
		2: actor.resources.change("Energy", 20)
		3:
			var bomb := {"id": "bomb", "formula": {"base": 150}, "targeting": "POINT", "radius": 2.5, "damage_type": "FIRE", "can_crit": false}
			actor.arena.perform_action(actor, bomb, actor.global_position, actor.facing, actor.aim_world_point(), null)
	return true

func restore_resources() -> void:
	actor.resources.restore_all()
	actor.health.shield = 0.0
	current_poise = max_poise()
	quick_counts = [5, 5, 5, 5]
	actor.refresh_collision_layer()
	if state == "DEAD":
		state = "NORMAL"
		actor.animation.visible = true

func reset() -> void:
	clear_hitstop()
	stamina_clock = 0.0
	energy_clock = 0.0
	if actor.movement_actions: actor.movement_actions.reset()
	actor.last_damage_source = null
	if actor.brain != null: actor.brain.reset_awareness()
	_release_grab(false)
	defense.clear()
	guard_requested = false
	guard_counter_time = 0.0
	last_block_source = null
	runner.cancel_action()
	state = "NORMAL"
	cooldowns.clear()
	statuses.clear()
	passives.internal_cooldowns.clear()
	passives.reset_combat()
	in_combat = false
	combat_timeout = 0.0
	first_damage = true
	first_damage_instance = ""
	combo = 0
	combo_timeout = 0.0
	switch_time = 0.0
	knockback = Vector3.ZERO
	actor.velocity = Vector3.ZERO
	if actor.input_router:
		actor.input_router.cancel()
	restore_resources()

func _die() -> void:
	clear_hitstop()
	if actor.brain != null: actor.brain.reset_awareness()
	_release_grab(false)
	defense.stop_guard()
	guard_requested = false
	guard_counter_time = 0.0
	runner.cancel_action()
	state = "DEAD"
	sync_precision_glow()
	actor.collision_layer = 0
	actor.animation.play_hit("DEAD")
	if actor.input_router:
		actor.input_router.cancel()
	died.emit()

func fail(message: String) -> bool:
	last_condition_failed = message
	if actor.is_human_controlled():
		actor.arena.notify(message)
	return false

func _merge_modifiers(target: Dictionary, modifiers: Dictionary) -> void:
	for key in modifiers:
		var name: String = {"damage_multiplier": "damage_bonus", "poise_damage_multiplier": "poise_damage_bonus", "damage_taken": "damage_taken_bonus"}.get(key, key)
		if key == "forced_crit":
			target[name] = modifiers[key]
		else:
			target[name] = float(target.get(name, 0.0)) + float(modifiers[key])
