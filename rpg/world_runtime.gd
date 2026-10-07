extends "res://combat/combat_world.gd"
## Shared combat with adventure-owned encounter lives and complete death commits.
const State = preload("res://rpg/world_state.gd")
const Guard = preload("res://rpg/mutation_guard.gd")
const Arrival = preload("res://rpg/encounter_arrival.gd")
var encounters_started := false
# Transient enemies spawned by the wave bridge also wait for short rest.
# Authored world encounters are saved through EncounterService instead.
var respawns: Array[Dictionary] = []
var _encounter_nodes: Dictionary = {}
var _arrival_waiting: Dictionary = {}
var _pending_deaths: Array[WeakRef] = []
var _pending_errors: Dictionary = {}
var _encounter_clock := 0.0
var _adventure_epoch := 0

func _physics_process(delta: float) -> void:
	if not is_instance_valid(player) or not is_instance_valid(camera):
		return
	aim_point = host.aim_position
	toast_time = maxf(0, toast_time - delta)
	if is_instance_valid(locked_target) and (locked_target.combat.state == "DEAD" or controlled_actor().global_position.distance_to(locked_target.global_position) > 25):
		locked_target = null
	tick_floaters(delta)
	var active: bool = player.is_physics_processing() and not host.paused and not get_tree().paused
	if not encounters_started and active:
		encounters_started = true
		_spawn_saved_lives()
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.ai_enabled = active
			if enemy.has_meta("encounter_arriving") and (enemy.combat.in_combat or enemy.global_position.distance_to(enemy.spawn_point) < 2.0):
				enemy.remove_meta("encounter_arriving")
	if not active or Guard.busy(host.world_state):
		return
	_encounter_clock += delta
	if _encounter_clock >= 1.0:
		var elapsed := _encounter_clock
		_encounter_clock = 0.0
		_tick_encounters(elapsed)
		_retry_pending()

func _encounter_position(definition: Dictionary) -> Vector3:
	var point: Array = definition.position
	return host.reference_map.to_global(Vector3(point[0], point[1], point[2]))

func _safe_position(at: Vector3, distance: float) -> bool:
	for body in [player, controlled_actor()]:
		if is_instance_valid(body) and body.global_position.distance_to(at) <= distance:
			return false
	return true

func _spawn_saved_lives() -> void:
	_arrival_waiting.clear()
	for entry in host.encounters.entries():
		if entry.record.phase == "alive" and _chapter_allows(entry.id):
			_spawn_encounter(entry.id)

func _chapter_allows(id: String) -> bool:
	return host.chapter != null and host.chapter.encounter_enabled(id)

func _spawn_encounter(id: String) -> void:
	var existing: Variant = _encounter_nodes.get(id)
	if is_instance_valid(existing) and existing.is_inside_tree() and not existing.is_queued_for_deletion():
		return
	var definition: Dictionary = host.encounters.definition(id)
	var record: Dictionary = host.encounters.record(id)
	if definition.is_empty() or record.get("phase", "") != "alive" or not _chapter_allows(id):
		return
	var at := _encounter_position(definition)
	var home := at
	var arriving := false
	# A new/unloaded living encounter may walk in from an authored safe entry.
	# Refreshed lives use the same safety and arrival rules.
	if not _safe_position(at, float(definition.safe_distance)):
		var arrival: Dictionary = Arrival.choose(self, definition, home)
		if arrival.is_empty():
			_arrival_waiting[id] = definition.enemy_id
			return
		at = arrival.position
		home = arrival.home
		arriving = true
	var profile: Dictionary = host.chapter.encounter_profile(id)
	var enemy: Node
	if profile.is_empty():
		enemy = spawn_enemy(definition.enemy_id, at)
	else:
		var template: Dictionary = Actor.UnitDefinition.for_enemy(database, definition.enemy_id)
		if template.is_empty(): return
		if profile.has("level"): template.level = int(profile.level)
		enemy = spawn_unit(template, at)
		if is_instance_valid(enemy):
			enemy.enemy_id = definition.enemy_id
			enemies.append(enemy)
			_bind_enemy_lifecycle(enemy)
	if not is_instance_valid(enemy):
		return
	enemy.set_meta("encounter_id", id)
	enemy.set_meta("encounter_generation", int(record.generation))
	enemy.spawn_point = home
	if arriving: enemy.set_meta("encounter_arriving", true)
	enemy.ai_enabled = player.is_physics_processing() and not host.paused
	_encounter_nodes[id] = enemy
	_arrival_waiting.erase(id)

## Read-only HUD context. It never changes quest selection or encounter facts.
func encounter_hint(enemy_id: String) -> String:
	for id in _arrival_waiting:
		if _arrival_waiting[id] != enemy_id or not _chapter_allows(id): continue
		var name: String = str(database.enemies.get(enemy_id, {}).get("name", "目标"))
		if controlled_actor() != player:
			return "%s尚未现身 · 解除附身并让出空地" % name
		return "%s尚未现身 · 退到林路外侧再观察" % name
	for id in _encounter_nodes:
		var enemy: Variant = _encounter_nodes[id]
		if not is_instance_valid(enemy) or enemy.enemy_id != enemy_id or enemy.combat.state == "DEAD": continue
		if enemy.has_meta("encounter_arriving") and not enemy.combat.in_combat and enemy.global_position.distance_to(enemy.spawn_point) >= 2.0:
			return "%s正沿林路赶来" % enemy.display_name
	return ""

func _tick_encounters(_delta: float) -> void:
	# Only reconcile original lives newly enabled by a quest. Defeated lives
	# remain absent until the short-rest transaction advances their generation.
	_spawn_saved_lives()

func refresh_after_short_rest() -> void:
	_spawn_saved_lives()
	var waiting: Array[Dictionary] = []
	for entry in respawns:
		if _safe_position(entry.position,12.0): spawn_enemy(entry.id,entry.position)
		else: waiting.append(entry)
	respawns.assign(waiting)

func spawn_enemy(id: String, at: Vector3 = Vector3(0, .05, -5)) -> Node:
	var enemy := super.spawn_enemy(id, at)
	if not is_instance_valid(enemy):
		return null
	_bind_enemy_lifecycle(enemy)
	return enemy

func _bind_enemy_lifecycle(enemy: Node) -> void:
	enemy.add_to_group("enemies")
	enemy.set_meta("adventure_epoch", _adventure_epoch)
	enemy.combat.died.connect(_enemy_defeated.bind(enemy), CONNECT_ONE_SHOT)

func _enemy_defeated(enemy: Node) -> void:
	if not is_instance_valid(enemy) or not enemy.is_inside_tree() or enemy.combat.state != "DEAD" or enemy.get_meta("adventure_epoch", -1) != _adventure_epoch or enemy.get_meta("rpg_defeat_resolved", false):
		return
	# Capture attribution once, before possession release can restore a faction.
	if not enemy.has_meta("rpg_defeat_credited"):
		var source: Node = enemy.last_damage_source.get_ref() if enemy.last_damage_source else null
		enemy.set_meta("rpg_defeat_credited", enemy.faction_id != player.faction_id and is_instance_valid(source) and source.faction_id == player.faction_id)
	var credited := bool(enemy.get_meta("rpg_defeat_credited"))
	var id := str(enemy.get_meta("encounter_id", ""))
	var generation := int(enemy.get_meta("encounter_generation", 0))
	if Guard.busy(host.world_state):
		_queue_pending_death(enemy)
		return
	var result := _resolve_death(enemy.enemy_id, id, generation, credited, enemy)
	if result == "retry":
		_queue_pending_death(enemy)
	elif result in ["settled", "pending"]:
		_finish_corpse(enemy, id)

## A managed defeated life remains durable as pending when inventory/counter
## capacity prevents settlement. It cannot respawn or award again after reload.
func _resolve_death(enemy_id: String, id: String, generation: int, credited: bool, enemy: Node = null) -> String:
	var candidate: Dictionary = host.world_state.export_state()
	if not id.is_empty():
		var current_life: Dictionary = host.encounters.record(id, candidate)
		if current_life.is_empty():
			_notify_pending(id, host.encounters.last_error)
			return "retry"
		if int(current_life.generation) != generation or current_life.phase not in ["alive", "pending"]:
			return "stale"
	var plan: Dictionary = {"ok": true}
	var reason := ""
	if credited:
		plan = player.progression.plan_enemy_reward(enemy_id)
		if not plan.ok:
			reason = str(plan.error)
		else:
			var events := State.new()
			events.import_state(candidate)
			if not events.record_event("enemy_defeated", enemy_id):
				reason = events.last_error
			else:
				candidate = events.export_state()
	if not reason.is_empty():
		_notify_pending(id if not id.is_empty() else "transient." + str(enemy.get_instance_id()), reason)
		if id.is_empty():
			return "retry"
		var current: Dictionary = host.encounters.record(id)
		if current.phase == "pending" and int(current.generation) == generation:
			return "pending"
		var waiting: Dictionary = host.encounters.plan_pending(id, generation, host.world_state.export_state())
		if not waiting.ok or not Guard.acquire(host.world_state, "encounters.pending"):
			return "retry"
		var stored: bool = host.world_state.import_state(waiting.world)
		if stored:
			host.world_state.object_changed.emit(id)
		Guard.release(host.world_state, "encounters.pending")
		return "pending" if stored else "retry"
	if not id.is_empty():
		var defeated: Dictionary = host.encounters.plan_defeat(id, generation, candidate)
		if not defeated.ok:
			_notify_pending(id, defeated.error)
			return "retry"
		candidate = defeated.world
	if not Guard.acquire(host.world_state, "encounters.death"):
		return "retry"
	if not host.world_state.import_state(candidate):
		Guard.release(host.world_state, "encounters.death")
		return "retry"
	var old_level: int = player.loadout.level
	if credited:
		player.progression.commit_enemy_reward(plan, false)
	if is_instance_valid(enemy):
		enemy.set_meta("rpg_defeat_resolved", true)
	# All serialized fields are final before _rebuild or any observer runs.
	if credited:
		player.progression.publish_enemy_reward(plan, old_level)
		host.world_state.event_recorded.emit({"type": "enemy_defeated", "subject": enemy_id, "amount": 1, "source_id": "", "total": host.world_state.get_event_count("enemy_defeated"), "subject_total": host.world_state.get_event_count("enemy_defeated", enemy_id)})
	if not id.is_empty():
		host.world_state.object_changed.emit(id)
	_pending_errors.erase(id)
	Guard.release(host.world_state, "encounters.death")
	if credited:
		var reward: Dictionary = plan.reward
		var loot: Array[String] = []
		for item in reward.get("drops", {}):
			loot.append("%s ×%d" % [player.inventory.definition(item).get("name", item), reward.drops[item]])
		notify("击败 %s · %s%s" % [database.enemies[enemy_id].get("name", enemy_id), "等级已满" if old_level >= player.progression.max_level() else "经验 +%d" % reward.get("experience", 0), " · " + " / ".join(loot) if not loot.is_empty() else ""])
		if is_instance_valid(enemy):
			host.enemy_defeated(enemy)
	return "settled"

func _notify_pending(id: String, reason: String) -> void:
	if _pending_errors.get(id, "") != reason:
		_pending_errors[id] = reason
		notify("战利品待领取 · " + reason)

func _queue_pending_death(enemy: Node) -> void:
	for reference in _pending_deaths:
		if reference.get_ref() == enemy:
			return
	_pending_deaths.append(weakref(enemy))

func _retry_pending() -> void:
	# Fixed catalog order gives deterministic equipment rotation when several
	# full-inventory encounters are settled in the same update.
	for entry in host.encounters.entries():
		if entry.record.phase == "pending":
			_resolve_death(entry.enemy_id, entry.id, int(entry.record.generation), true)
	var waiting := _pending_deaths.duplicate()
	_pending_deaths.clear()
	for reference: WeakRef in waiting:
		var enemy: Node = reference.get_ref()
		if is_instance_valid(enemy):
			_enemy_defeated(enemy)

func _finish_corpse(enemy: Node, id: String) -> void:
	if not is_instance_valid(enemy) or not enemy.is_inside_tree() or enemy.get_meta("adventure_epoch", -1) != _adventure_epoch:
		return
	if enemy.get_meta("rpg_corpse_scheduled", false):
		return
	enemy.set_meta("rpg_defeat_resolved", true)
	enemy.set_meta("rpg_corpse_scheduled", true)
	if not id.is_empty():
		_encounter_nodes.erase(id)
	elif not enemy.has_meta("wave"):
		respawns.append({"id": enemy.enemy_id, "position": enemy.spawn_point, "time": 45.0})
	var corpse: WeakRef = weakref(enemy)
	var epoch := _adventure_epoch
	get_tree().create_timer(4.0, false).timeout.connect(func():
		var node: Node = corpse.get_ref()
		if epoch == _adventure_epoch and is_instance_valid(node):
			enemies.erase(node)
			if locked_target == node:
				locked_target = null
			node.queue_free())

func save_error() -> String:
	# Inspect actual lives, not the retry queue: that queue is temporarily being
	# drained while a prior reward's synchronous observers may request a save.
	for enemy in enemies:
		if not is_instance_valid(enemy) or not enemy.is_inside_tree() or enemy.get_meta("adventure_epoch", -1) != _adventure_epoch or enemy.get_meta("rpg_defeat_resolved", false):
			continue
		if enemy.combat.state != "DEAD" and enemy.resources.current("HP") > 0:
			continue
		var id := str(enemy.get_meta("encounter_id", ""))
		var stored: Dictionary = host.world_state.get_object(id) if not id.is_empty() else {}
		if stored.get("phase", "") in ["pending", "cooldown", "cleared"] and int(stored.get("generation", 0)) == int(enemy.get_meta("encounter_generation", -1)):
			continue
		return "仍有未能记录的战利品，请解决容量或奖励错误后再保存"
	return ""

## Called only after the repository validates and imports the complete snapshot.
## Old death callbacks and corpse timers cannot touch a new adventure epoch.
func restore_encounters() -> void:
	_adventure_epoch += 1
	locked_target = null
	floaters.clear()
	host.floaters.clear()
	player.current_target = null
	respawns.clear()
	_pending_deaths.clear()
	_pending_errors.clear()
	_encounter_nodes.clear()
	_arrival_waiting.clear()
	_encounter_clock = 0.0
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.set_physics_process(false)
			enemy.collision_layer = 0
			if enemy.get_parent() != null:
				enemy.get_parent().remove_child(enemy)
			enemy.queue_free()
	enemies.clear()
	host.wave_active = false
	encounters_started = true
	_spawn_saved_lives()

func reset_living_enemies() -> void:
	locked_target = null
	for enemy in enemies:
		if is_instance_valid(enemy) and enemy.combat.state != "DEAD":
			enemy.global_position = enemy.spawn_point
			enemy.combat.reset()
			enemy.ai_cooldown = 2.0

