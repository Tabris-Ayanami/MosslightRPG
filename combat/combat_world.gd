extends Node3D
## One combat execution and targeting service, shared by the world and laboratory.
const Database = preload("res://combat/combat_database.gd")
const Actor = preload("res://combat/combat_actor.gd")
const Attack = preload("res://combat/attack_instance.gd")
const Art = preload("res://scripts/art.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
var database := Database.new()
var host: Node
var actor_parent: Node3D
var player: CharacterBody3D
var control: Node
var _units: Array[Node] = []
var faction_relations: Dictionary = {}
var enemies: Array[Node] = []
var camera: Camera3D
var effects: Node3D
var sound: Node
var locked_target: Node
var manual_lock := false
var aim_point := Vector3(0, 0, -3)
var aim_override: Variant = null
var input_blocked := false:
	get:
		return input_blocked or (is_instance_valid(controlled_actor()) and controlled_actor().get_meta("traversal_locked", false)) or (is_instance_valid(host) and (host.paused or host.camera_dragging or not is_instance_valid(player) or not player.is_physics_processing()))
var pointer_blocked := false:
	get:
		return pointer_blocked or (is_instance_valid(host) and (host.ui_pointer_blocked or (is_instance_valid(host.get("world_ui")) and host.world_ui.blocks_pointer(host.get_viewport().get_mouse_position()))))
var toast := "选择职业，开始战斗测试"
var toast_time := 6.0
var floaters: Array[Dictionary] = []
var _floater_sequence := 0

func register_unit(actor: Node) -> void:
	if actor not in _units: _units.append(actor)
	if not is_instance_valid(control):
		control = preload("res://combat/unit_control.gd").new()
		control.arena = self
		add_child(control)

func units() -> Array[Node]:
	var result: Array[Node] = []
	for i in range(_units.size() - 1, -1, -1):
		if not is_instance_valid(_units[i]):
			_units.remove_at(i)
		elif _units[i].is_inside_tree():
			result.push_front(_units[i])
	return result

func controlled_actor() -> Node:
	return control.controlled_actor() if is_instance_valid(control) else player

func set_faction_relation(a: String, b: String, relation: Variant) -> bool:
	# Existing hostility toggles retain their meaning: peace is neutral, not an
	# alliance. Named relations also permit alliances between distinct factions.
	var resolved: StringName
	if relation is bool: resolved=&"hostile" if relation else &"neutral"
	elif relation is String or relation is StringName: resolved=StringName(relation)
	if a.is_empty() or b.is_empty() or resolved not in [&"ally",&"neutral",&"hostile"]: return false
	faction_relations[a + "|" + b] = resolved
	faction_relations[b + "|" + a] = resolved
	return true

func relation_between(source: Node, other: Node) -> StringName:
	if not is_instance_valid(source) or not is_instance_valid(other) or source.arena != self or other.arena != self: return &"invalid"
	if source == other: return &"self"
	if source.faction_id.is_empty() or other.faction_id.is_empty(): return &"neutral"
	if source.faction_id == other.faction_id: return &"ally"
	var key: String = source.faction_id + "|" + other.faction_id
	if faction_relations.has(key): return faction_relations[key]
	return &"hostile" if source.faction_id in ["heroes", "hostiles"] and other.faction_id in ["heroes", "hostiles"] else &"neutral"

func are_hostile(source: Node, other: Node) -> bool:
	return relation_between(source,other)==&"hostile"

func are_allied(source: Node, other: Node) -> bool:
	return relation_between(source,other)==&"ally"

func nearest_hostile(source: Node, reach: float) -> Node:
	var best: Node
	var distance := reach
	for target in targets_for(source):
		if target.combat.statuses.has_status("stealth") and not source.is_boss: continue
		var d: float = source.global_position.distance_to(target.global_position)
		if d < distance and line_clear(source.global_position, target.global_position):
			best = target
			distance = d
	return best

func camera_right() -> Vector3:
	var value := camera.global_basis.x
	value.y = 0
	return value.normalized()

func camera_forward() -> Vector3:
	var value := -camera.global_basis.z
	value.y = 0
	return value.normalized()

func world_to_screen(point: Vector3) -> Vector2:
	return host.world_to_screen(point) if is_instance_valid(host) else camera.unproject_position(point)

func targets_for(source: Node) -> Array:
	var targets: Array = []
	for unit: Node in _units:
		if is_instance_valid(unit) and unit.is_inside_tree() and unit.combat.state != "DEAD" and are_hostile(source, unit):
			targets.append(unit)
	return targets

func target_for(source: Node, relation := "hostile") -> Node:
	var candidates: Array = units().filter(func(unit: Node) -> bool: return unit != source and unit.combat.state != "DEAD") if relation == "any" else targets_for(source)
	if not source.is_human_controlled():
		if is_instance_valid(source.current_target) and source.current_target.combat.state != "DEAD" and source.current_target in candidates: return source.current_target
		return nearest_hostile(source, source.aggro_range)
	if is_instance_valid(locked_target) and locked_target.combat.state != "DEAD" and locked_target in candidates:
		return locked_target
	var hovered := target_for_selection(source, relation)
	return hovered if is_instance_valid(hovered) and source.global_position.distance_to(hovered.global_position) <= 22 and line_clear(source.global_position, hovered.global_position) else null

func has_aim_override() -> bool:
	return aim_override != null or is_instance_valid(host) and host.get("aim_override") != null

func pointer_ray() -> Dictionary:
	var presenter: Node = host if is_instance_valid(host) else get("renderer")
	if not is_instance_valid(presenter) or not is_instance_valid(camera) or not presenter.has_method("screen_to_viewport"): return {}
	# Units are inside the pixel SubViewport. Read display coordinates from its
	# presenter and apply that presenter's crop/snap conversion exactly once.
	var display_mouse: Vector2 = presenter.get_viewport().get_mouse_position()
	var pixel: Vector2 = presenter.screen_to_viewport(display_mouse)
	var from := camera.project_ray_origin(pixel)
	var direction := camera.project_ray_normal(pixel)
	return {"from": from, "to": from + direction * camera.far, "direction": direction}

func pointer_ground() -> Vector3:
	if aim_override != null: return aim_override
	if is_instance_valid(host) and host.get("aim_override") != null: return host.get("aim_override")
	var ray := pointer_ray()
	var unit: Node = controlled_actor()
	if ray.is_empty() or not is_instance_valid(unit): return aim_point
	var query := PhysicsRayQueryParameters3D.create(ray.from, ray.to, 1)
	var hit: Dictionary = unit.get_world_3d().direct_space_state.intersect_ray(query)
	var point: Variant = hit.get("position")
	# Water is a rendered surface without a blocking physics collider. It is an
	# aim surface only when the ray reaches it before the bank, bridge or roof.
	if is_instance_valid(host) and host.has_method("water_ray_hit"):
		var water: Variant = host.water_ray_hit(ray.from, ray.direction)
		if water is Vector3 and ray.from.distance_squared_to(water) <= camera.far * camera.far and (point == null or ray.from.distance_squared_to(water) < ray.from.distance_squared_to(point)): point = water
	if point is Vector3: return point
	var fallback: Variant = Plane(Vector3.UP, unit.global_position.y).intersects_ray(ray.from, ray.direction)
	return fallback if fallback is Vector3 else aim_point

func clamp_aim_point(origin: Vector3, point: Vector3, reach: float) -> Vector3:
	var offset := Vector3(point.x - origin.x, 0, point.z - origin.z)
	if offset.length_squared() <= reach * reach: return point
	var result := origin + offset.normalized() * maxf(0, reach)
	# Range is horizontal, like the indicator and damage shapes. Resolve the
	# clamped impact onto terrain instead of leaving it suspended on a 3D line.
	var top := Vector3(result.x, maxf(origin.y, point.y) + .5, result.z)
	var query := PhysicsRayQueryParameters3D.create(top, top - Vector3.UP * 24, 1)
	var hit: Dictionary = controlled_actor().get_world_3d().direct_space_state.intersect_ray(query)
	result.y = float(hit.position.y) if not hit.is_empty() else point.y
	if is_instance_valid(host) and host.has_method("water_surface_at"):
		var water: float = host.water_surface_at(result)
		if is_finite(water): result.y = maxf(result.y, water)
	return result

func refresh_aim() -> Vector3:
	aim_point = pointer_ground()
	if is_instance_valid(host) and host.get("aim_position") is Vector3: host.aim_position = aim_point
	return aim_point

func action_aim_point(source: Node, action: Dictionary = {}) -> Vector3:
	var point := refresh_aim()
	if is_instance_valid(locked_target) and locked_target.combat.state != "DEAD" and are_hostile(source,locked_target) and action.get("presentation_type", "WEAPON_ACTION") == "WEAPON_ACTION":
		return locked_target.global_position
	# Direction and ground spells aimed at a visible body use its actual feet.
	# A confirmed ground spell retains that position, without becoming homing.
	var hovered := target_for_selection(source, str(action.get("target_relation", "hostile")), false)
	return hovered.global_position if is_instance_valid(hovered) else point

func target_for_selection(source: Node, relation := "hostile", respect_lock := true) -> Node:
	var candidates: Array = units().filter(func(unit: Node) -> bool: return unit != source and unit.combat.state != "DEAD" and (relation == "any" or are_hostile(source, unit)))
	if respect_lock and is_instance_valid(locked_target) and locked_target in candidates: return locked_target
	var physical_pointer := false
	if not has_aim_override():
		var ray := pointer_ray()
		if not ray.is_empty():
			physical_pointer = true
			# A torso on a higher platform does not project onto its feet on the
			# caster's height plane. Select the real unit capsule under the cursor.
			var query := PhysicsRayQueryParameters3D.create(ray.from, ray.to, 1 | 2 | 4, [source.get_rid()])
			var hit: Dictionary = source.get_world_3d().direct_space_state.intersect_ray(query)
			if not hit.is_empty():
				if hit.collider in candidates: return hit.collider
				if hit.collider is CharacterBody3D: return null
	var best: Node
	var score := INF
	for unit in candidates:
		var offset: Vector3 = unit.global_position - aim_point
		if physical_pointer and absf(offset.y) > .5: continue
		offset.y = 0
		var radius := maxf(.6, float(unit.definition.body.radius) * float(unit.definition.body.scale.x) + .35)
		var distance := offset.length() / radius
		if distance <= 1.0 and distance < score:
			score = distance
			best = unit
	# Keep an out-of-range/obstructed hovered unit selected so confirmation can
	# explain the failure, rather than silently selecting a different nearby unit.
	return best

func hover_at_feet(source: Node, pointer: Vector2) -> Node:
	var selected: Node
	var score := INF
	var factor := clampf(get_tree().root.get_visible_rect().size.y / 720.0,.7,2.0)
	for unit in targets_for(source):
		if camera.is_position_behind(unit.global_position) or source.global_position.distance_to(unit.global_position)>22 or not line_clear(source.global_position,unit.global_position): continue
		var distance: float = world_to_screen(unit.global_position).distance_to(pointer)
		if distance <= (38.0 if unit.is_boss else 28.0)*factor and distance < score:
			selected = unit
			score = distance
	return selected

func update_hover_lock(source: Node) -> void:
	if has_aim_override(): return
	if is_instance_valid(locked_target) and (locked_target.combat.state == "DEAD" or not are_hostile(source,locked_target) or source.global_position.distance_to(locked_target.global_position)>28):
		locked_target = null
		manual_lock = false
	if manual_lock and is_instance_valid(locked_target): return
	if source.attack_assist.approaching() or source.combat.state in ["ACTION","CHARGING"]: return
	locked_target = null if pointer_blocked or input_blocked else hover_at_feet(source,get_tree().root.get_mouse_position())

func toggle_lock() -> void:
	if manual_lock and is_instance_valid(locked_target):
		locked_target = null
		manual_lock = false
		return
	if is_instance_valid(locked_target):
		manual_lock = true
		return
	var best := INF
	var controlled: Node = controlled_actor()
	var pointer := get_tree().root.get_mouse_position()
	for enemy in targets_for(controlled):
		if not is_instance_valid(enemy) or enemy.combat.state == "DEAD" or camera.is_position_behind(enemy.global_position):
			continue
		var distance: float = controlled.global_position.distance_to(enemy.global_position)
		var screen := world_to_screen(enemy.global_position)
		if distance > 22 or not get_tree().root.get_visible_rect().has_point(screen) or not line_clear(controlled.global_position, enemy.global_position):
			continue
		var score := screen.distance_to(pointer) + distance * 2
		if score < best:
			best = score
			locked_target = enemy
	manual_lock = is_instance_valid(locked_target)

func line_clear(from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from + Vector3.UP * .8, to + Vector3.UP * .8, 1)
	return player.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func spawn_unit(template: Dictionary, at: Vector3, mode := "ai", sandbox := false) -> Node:
	if template.is_empty() or mode not in ["human", "ai", "none"]: return null
	if mode == "human" and not is_instance_valid(player): return null
	var unit := Actor.new()
	unit.arena = self
	unit.definition = template.duplicate(true)
	unit.enemy_id = str(template.get("id", ""))
	unit.sandbox_mode = sandbox
	var parent: Node3D = actor_parent if actor_parent else self
	unit.position = parent.to_local(at)
	parent.add_child(unit)
	if mode == "human":
		unit.set_control_mode("none")
		if not control.possess(unit):
			unit.queue_free()
			return null
	else:
		unit.set_control_mode(mode)
	return unit

func spawn_enemy(id: String, at: Vector3 = Vector3(0, .05, -5)) -> Node:
	var enemy: Node = spawn_unit(Actor.UnitDefinition.for_enemy(database, id), at)
	if not is_instance_valid(enemy): return null
	enemy.enemy_id = id
	enemies.append(enemy)
	return enemy

func clear_aggro(source: Node) -> void:
	for unit in targets_for(source):
		if unit.is_boss: continue
		unit.current_target = null
		unit.combat.combat_timeout = 0
		unit.combat.runner.cancel_action()
		if unit.combat.state == "ACTION": unit.combat.state = "NORMAL"
		unit.ai_cooldown = 2.5

func perform_action(source: Node, action: Dictionary, origin: Vector3, direction: Vector3, point: Vector3, target: Node) -> void:
	var tone := "skill" if action.get("presentation_type", "") in ["CASTER_ACTION", "VFX_ONLY"] else ("bow" if float(action.get("projectile_speed", 0.0)) > 0 else "sword")
	if int(action.get("combo_index", 0)) == 2 and action.get("animation_family", "") in ["SINGLE_BLADE", "HEAVY_2H"]: tone = "heavy"
	if preload("res://combat/impact_feedback.gd").sound_enabled: sound.play_tone(tone)
	if action.get("targeting", "") == "SELF" or action.get("presentation_type", "") == "VFX_ONLY":
		effect_ring(source.global_position, 1.6, element_color(action.get("damage_type", "WIND")), .5)
		return
	if int(action.get("chain_targets", 0)) > 0:
		_chain(source, action, target)
		return
	var count := int(action.get("projectiles", 1))
	for i in range(count):
		var attack := Attack.new()
		attack.arena = self
		attack.source = source
		attack.action = action.duplicate(true)
		attack.origin = origin
		attack.direction = direction.rotated(Vector3.UP, (float(i) - float(count - 1) / 2) * .18)
		attack.aim_point = point
		attack.target = target
		if action.get("shape", "") == "LINE" and action.get("targeting", "") == "POINT":
			attack.action["targeting"] = "LINE"
			attack.action["range"] = action.get("length", 7)
			attack.action["center_on_point"] = true
		effects.add_child(attack)

func _chain(source: Node, action: Dictionary, target: Node) -> void:
	if not is_instance_valid(target) or not are_hostile(source, target):
		return
	var visited: Array = []
	var previous: Vector3 = source.global_position
	var packet := action.duplicate(true)
	for i in range(int(action.get("chain_targets", 4))):
		if not is_instance_valid(target):
			break
		visited.append(target)
		source.combat.hit_target(target, packet, (target.global_position - previous).normalized())
		var beam := Art.line(effects, previous + Vector3.UP, target.global_position + Vector3.UP, .09, Color("abdcfa"))
		var tween := beam.create_tween()
		tween.tween_interval(.2)
		tween.tween_callback(beam.queue_free)
		previous = target.global_position
		for key in packet.formula:
			packet.formula[key] *= float(action.get("chain_multiplier", .8))
		target = null
		var nearest := float(action.get("chain_range", 6))
		for candidate in targets_for(source):
			if candidate in visited or candidate.combat.state == "DEAD":
				continue
			var distance: float = previous.distance_to(candidate.global_position)
			if distance < nearest and line_clear(previous, candidate.global_position):
				nearest = distance
				target = candidate

func element_color(type: String) -> Color:
	return {"PHYSICAL": Color("e9d797"), "FIRE": Color("ff9b67"), "ICE": Color("91e4f0"), "LIGHTNING": Color("c3b8ff"), "EARTH": Color("c3b17e"), "WIND": Color("a6e2bd")}.get(type, Color.WHITE)

func effect_ring(at: Vector3, radius: float, color: Color, duration: float) -> void:
	var ring := Art.ring(effects, at + Vector3.UP * .055, maxf(.3, radius), .07, color)
	var tween := ring.create_tween()
	tween.tween_property(ring, "scale", Vector3.ONE * 1.06, maxf(.08, duration))
	tween.tween_callback(ring.queue_free)

func float_text(at: Vector3, message: String, color: Color, target: Node = null, is_damage := false) -> void:
	if is_damage and not Preferences.get_damage_numbers(): return
	_floater_sequence += 1
	var anchor: Vector3 = target.global_position + Vector3.UP * (2.8 if target.is_boss else 2.05) if is_damage and is_instance_valid(target) else at
	floaters.append({"position": anchor, "text": message, "color": color, "life": 1.0 if is_damage else .85,
		"time": 0.0, "is_damage": is_damage, "target": weakref(target) if is_instance_valid(target) else null, "lane": ((_floater_sequence - 1) % 3) - 1})

func tick_floaters(delta: float) -> void:
	var show_damage: bool = Preferences.get_damage_numbers()
	for i in range(floaters.size() - 1, -1, -1):
		floaters[i].life -= delta
		floaters[i]["time"] = float(floaters[i].get("time", 0.0)) + delta
		if floaters[i].life <= 0 or (bool(floaters[i].get("is_damage", false)) and not show_damage):
			floaters.remove_at(i)

func notify(message: String) -> void:
	toast = message
	toast_time = 3.5
	if is_instance_valid(host):
		host.notify(message)

func clear_attacks() -> void:
	for node in effects.get_children():
		if node.get_script() == Attack:
			node.set_physics_process(false)
			node.queue_free()
