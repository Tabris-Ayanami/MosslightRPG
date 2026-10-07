extends Node
## The local player's identity stays on arena.player; input can inhabit any unit.
## Temporary AI control leases all use the same UnitBrain as native monsters.
var arena: Node
var possessed: Node
var remaining := 0.0
var _previous: Dictionary = {}
var _autopilots: Dictionary = {}

func controlled_actor() -> Node:
	return possessed if is_instance_valid(possessed) else (arena.player if is_instance_valid(arena.player) else null)

func possess(target: Node, duration := 0.0, max_level_delta: Variant = null) -> bool:
	var owner: Node = arena.player if is_instance_valid(arena.player) else null
	if not is_finite(duration) or duration < 0: return false
	if not is_instance_valid(owner) or not is_instance_valid(target) or target == owner or target.arena != arena or target.combat.state == "DEAD" or owner.combat.state == "DEAD": return false
	if max_level_delta != null and target.loadout.level > controlled_actor().loadout.level + int(max_level_delta): return false
	if target.get_meta("traversal_locked", false) or owner.get_meta("traversal_locked", false): return false
	release()
	stop_autopilot(owner)
	stop_autopilot(target)
	_previous = {"owner_mode": owner.control_mode, "target_mode": target.control_mode, "target_faction": target.faction_id}
	owner.set_control_mode("none")
	possessed = target
	remaining = maxf(0, duration)
	target.faction_id = owner.faction_id
	target.refresh_collision_layer()
	target.set_control_mode("human")
	arena.locked_target = null
	arena.notify("正在操控 %s%s" % [target.display_name, " · %.0f 秒后返回本体" % duration if duration > 0 else ""])
	return true

func release() -> void:
	if _previous.is_empty():
		possessed = null
		return
	if is_instance_valid(possessed):
		stop_autopilot(possessed)
		possessed.faction_id = _previous.target_faction
		possessed.refresh_collision_layer()
		possessed.set_control_mode(_previous.target_mode)
	possessed = null
	if is_instance_valid(arena.player): arena.player.set_control_mode(_previous.owner_mode)
	_previous.clear()
	remaining = 0
	arena.locked_target = null
	arena.notify("已返回本体")

func autopilot(actor: Node, duration := 5.0) -> bool:
	if not is_finite(duration) or duration <= 0: return false
	if not is_instance_valid(actor) or actor.arena != arena or actor.combat.state == "DEAD" or actor.get_meta("traversal_locked", false): return false
	var id := actor.get_instance_id()
	if not _autopilots.has(id):
		_autopilots[id] = {"actor": weakref(actor), "mode": actor.control_mode, "aggressive": actor.brain.aggressive, "home": actor.brain.home_override, "time": maxf(.01, duration)}
	else:
		_autopilots[id].time = maxf(.01, duration)
	actor.brain.home_override = actor.global_position
	actor.brain.aggressive = true
	actor.set_control_mode("ai")
	return true

func stop_autopilot(actor: Node) -> void:
	if not is_instance_valid(actor) or not _autopilots.has(actor.get_instance_id()): return
	var entry: Dictionary = _autopilots[actor.get_instance_id()]
	_autopilots.erase(actor.get_instance_id())
	actor.brain.aggressive = entry.aggressive
	actor.brain.home_override = entry.home
	actor.set_control_mode(entry.mode)

func cancel_all() -> void:
	release()
	for entry in _autopilots.values():
		var actor: Node = entry.actor.get_ref()
		if is_instance_valid(actor): stop_autopilot(actor)
	_autopilots.clear()

func _physics_process(delta: float) -> void:
	if not is_instance_valid(arena.player):
		cancel_all()
		return
	if is_instance_valid(arena.host) and (arena.host.paused or not arena.player.is_physics_processing()): return
	if not _previous.is_empty():
		if not is_instance_valid(possessed) or possessed.combat.state == "DEAD" or not is_instance_valid(arena.player) or arena.player.combat.state == "DEAD":
			release()
		elif remaining > 0:
			remaining = maxf(0, remaining - delta)
			if remaining <= 0: release()
	for id in _autopilots.keys():
		var entry: Dictionary = _autopilots[id]
		var actor: Node = entry.actor.get_ref()
		if not is_instance_valid(actor):
			_autopilots.erase(id)
			continue
		entry.time -= delta
		if entry.time <= 0 or actor.combat.state == "DEAD": stop_autopilot(actor)
