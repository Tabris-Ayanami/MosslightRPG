extends CharacterBody3D

const Stats = preload("res://combat/stats_component.gd")
const Resources = preload("res://combat/resource_component.gd")
const Health = preload("res://combat/health_component.gd")
const Loadout = preload("res://combat/loadout_component.gd")
const Controller = preload("res://combat/combat_controller.gd")
const Router = preload("res://combat/input_router.gd")
const Visual = preload("res://combat/animation_controller.gd")
const KiritoVisual = preload("res://combat/kirito_combat_visual.gd")
const Inventory = preload("res://rpg/inventory_component.gd")
const Progression = preload("res://rpg/progression_component.gd")
const Hurtbox = preload("res://combat/hurtbox_component.gd")
const RaceCatalog = preload("res://rpg/race_catalog.gd")
const UnitDefinition = preload("res://combat/unit_definition.gd")
const UnitBrain = preload("res://combat/unit_brain.gd")

var visual_script: Script
var sandbox_mode := true
var inventory: Node
var progression: Node
var arena: Node
var is_player := false
var enemy_id := "soldier"
var display_name := "旅人"
var race_id: String = RaceCatalog.DEFAULT_ID
var definition: Dictionary = {}
var definition_id := ""
var faction_id := "hostiles"
var control_mode := "ai"
var resource_profile: Dictionary = {}
var innate_actions: Dictionary = {}
var innate_skills: Array[Dictionary] = []
var current_target: Node
var last_damage_source: WeakRef
var swimming := false
var wading := false
var surface_traversal = preload("res://rpg/surface_traversal.gd").new()
var ladder = preload("res://rpg/ladder_traversal.gd").new()
var dead: bool:
	get: return combat != null and combat.state == "DEAD"
var brain: RefCounted
var form: RefCounted
var stats: Node
var resources: Node
var health: Node
var loadout: Node
var combat: Node
var animation: Node3D
var hurtbox: Node
var input_router: Node
var skill_casting: Node
var movement_actions: Node
var attack_assist: Node
var facing := Vector3.FORWARD
var move_direction := Vector3.ZERO
var resistances: Dictionary = {}
var immune_to_launch := false
var immune_to_knockdown := false
var is_boss := false
var ai_enabled := true
var ai_cooldown := 1.0
var spawn_point := Vector3.ZERO
var move_speed := 5.2
var attack_damage := 65.0
var attack_poise := 35.0
var attack_reach := 2.1
var aggro_range := 9.0
var attack_hit := false
var enemy_action: Dictionary = {}
var enemy_attack_cooldown := 2.5
var enemy_shield: Dictionary = {}
var grab_action: Dictionary = {}
var grab_every := 0
var attacks_made := 0
var warning: MeshInstance3D
var _visual_loadout: Dictionary = {}

func _ready() -> void:
	spawn_point = global_position
	collision_mask = 1
	floor_snap_length = .35
	if not get_node_or_null("CollisionShape3D"):
		var collision := CollisionShape3D.new()
		collision.name = "CollisionShape3D"
		var shape := CapsuleShape3D.new()
		shape.radius = .27 if is_player else .35
		shape.height = 1.3 if is_player else 1.5
		collision.shape = shape
		collision.position.y = shape.height * .5
		add_child(collision)
	stats = Stats.new()
	add_child(stats)
	resources = Resources.new()
	add_child(resources)
	health = Health.new()
	add_child(health)
	health.setup(resources)
	loadout = Loadout.new()
	add_child(loadout)
	loadout.setup(self, arena.database)
	combat = Controller.new()
	add_child(combat)
	combat.setup(self)
	hurtbox = Hurtbox.new()
	hurtbox.actor = self
	add_child(hurtbox)
	inventory = Inventory.new()
	add_child(inventory)
	inventory.setup(self, arena.database)
	progression = Progression.new()
	add_child(progression)
	progression.setup(self, arena.database, inventory)
	if not sandbox_mode: loadout.configure_progression(inventory, progression)
	control_mode = "human" if is_player else "ai"
	input_router = Router.new()
	input_router.is_blocked = func() -> bool: return not is_human_controlled() or control_input_blocked()
	input_router.is_pointer_blocked = func() -> bool: return arena.pointer_blocked
	input_router.is_secondary_guard = func() -> bool: return not shield_definition().is_empty()
	add_child(input_router)
	input_router.command.connect(combat.command)
	input_router.hold_started.connect(combat.begin_charge)
	input_router.input_cancelled.connect(combat.clear_input_intent)
	input_router.pointer_cancelled.connect(combat.clear_pointer_intent)
	skill_casting = preload("res://combat/skill_casting.gd").new()
	add_child(skill_casting)
	skill_casting.setup(self)
	input_router.skill_casting = skill_casting
	input_router.input_cancelled.connect(skill_casting.cancel)
	input_router.pointer_cancelled.connect(skill_casting.cancel)
	movement_actions = preload("res://combat/movement_actions.gd").new()
	add_child(movement_actions)
	movement_actions.setup(self)
	input_router.movement_actions = movement_actions
	input_router.input_cancelled.connect(movement_actions.cancel)
	input_router.pointer_cancelled.connect(movement_actions.cancel)
	input_router.set_physics_process(is_human_controlled())
	attack_assist = preload("res://combat/attack_assist.gd").new()
	add_child(attack_assist)
	attack_assist.setup(self)
	input_router.input_cancelled.connect(attack_assist.cancel)
	input_router.pointer_cancelled.connect(attack_assist.cancel)
	brain = UnitBrain.new()
	brain.setup(self)
	if definition.is_empty(): definition = UnitDefinition.for_player() if is_player else UnitDefinition.for_enemy(arena.database, enemy_id)
	loadout.level = maxi(0, int(definition.get("level", 0)))
	apply_definition(definition, true)
	loadout._rebuild(true)
	stats.changed.connect(loadout.refresh_resources)
	loadout.changed.connect(_refresh_visual)
	form = preload("res://combat/unit_form.gd").new()
	form.setup(self)
	ladder.setup(self, arena.host)
	arena.register_unit(self)
	_refresh_visual()

func apply_definition(data: Dictionary, fill_resources := false, keep_identity := false) -> void:
	if data.is_empty(): return
	if combat: combat.clear_hitstop()
	if is_instance_valid(movement_actions): movement_actions.reset()
	definition = data.duplicate(true)
	definition_id = str(definition.id)
	race_id = str(definition.race_id)
	if not keep_identity:
		display_name = str(definition.name)
		faction_id = str(definition.faction_id)
	resource_profile = definition.resource_profile.duplicate(true)
	innate_actions = definition.innate_actions.duplicate(true)
	innate_skills.assign(definition.innate_skills.duplicate(true))
	var rules: Dictionary = definition.combat
	resistances = rules.resistances.duplicate(true)
	immune_to_launch = rules.immune_to_launch
	immune_to_knockdown = rules.immune_to_knockdown
	is_boss = rules.is_boss
	move_speed = float(definition.movement.speed)
	attack_damage = float(rules.damage)
	attack_poise = float(rules.poise_damage)
	attack_reach = float(rules.range)
	aggro_range = float(definition.ai.aggro_range)
	enemy_attack_cooldown = float(definition.ai.attack_cooldown)
	grab_every = int(definition.ai.grab_every)
	enemy_action = action_for("PRIMARY_TAP") if not innate_actions.is_empty() else {}
	grab_action = {}
	for skill in innate_skills:
		if skill.get("attack_kind", "") == "GRAB" or skill.get("grab", false):
			grab_action = skill.duplicate(true)
			break
	enemy_shield = arena.database.shields.get(rules.shield_id, {}).duplicate(true)
	stats.set_base(definition.stats)
	loadout.refresh_resources(fill_resources)
	var collider := get_node("CollisionShape3D") as CollisionShape3D
	var capsule := CapsuleShape3D.new()
	# Godot capsules do not reliably collide under nonuniform node scale.
	# Bake the unit's intended dimensions into its shape instead (Ogre .525/1.95).
	var body_scale: Vector3 = definition.body.scale
	var body_radius := float(definition.body.radius) * maxf(body_scale.x, body_scale.z)
	var body_height := maxf(float(definition.body.height) * body_scale.y, body_radius * 2.0)
	capsule.height = body_height
	capsule.radius = body_radius
	collider.shape = capsule
	collider.scale = Vector3.ONE
	collider.position.y = capsule.height * .5
	refresh_collision_layer()
	if is_instance_valid(animation):
		remove_child(animation)
		animation.queue_free()
	var kirito: bool = definition.visual.kind == "kirito"
	animation = (visual_script if visual_script else (KiritoVisual if kirito else Visual)).new()
	add_child(animation)
	animation.setup(kirito, Color(definition.visual.color), float(definition.visual.scale))
	_visual_loadout.clear()
	_refresh_visual()

func refresh_collision_layer() -> void:
	collision_layer = 0 if combat.state == "DEAD" else (2 if faction_id == "heroes" else 4)

func is_human_controlled() -> bool:
	return control_mode == "human"

func set_control_mode(mode: String) -> bool:
	if mode not in ["human", "ai", "none"]: return false
	if movement_actions: movement_actions.reset()
	ladder.cleanup()
	surface_traversal.clear()
	if input_router: input_router.cancel()
	combat.clear_input_intent()
	combat.defense.stop_guard()
	combat.runner.cancel_action()
	if combat.state in ["ACTION", "CHARGING", "GUARD", "SWITCH"]: combat.state = "NORMAL"
	control_mode = mode
	current_target = null
	if brain != null: brain.reset_awareness()
	move_direction = Vector3.ZERO
	velocity = Vector3.ZERO
	if input_router: input_router.set_physics_process(mode == "human")
	return true

func control_input_blocked() -> bool:
	if control_mode == "none" or combat.state == "DEAD" or get_meta("traversal_locked", false): return true
	if is_instance_valid(arena.host) and (arena.host.paused or not is_instance_valid(arena.player) or not arena.player.is_physics_processing()): return true
	return arena.input_blocked if is_human_controlled() else false

func target_for_action(action: Dictionary = {}) -> Node:
	if action.has("cast_intent"):
		var reference: Variant = action.cast_intent.get("target")
		return reference.get_ref() if reference is WeakRef else null
	return arena.target_for(self, str(action.get("target_relation", "hostile")))

func aim_world_point(action: Dictionary = {}) -> Vector3:
	if action.has("cast_intent"): return action.cast_intent.point
	if is_human_controlled(): return arena.action_aim_point(self, action)
	var target := target_for_action()
	return target.global_position if is_instance_valid(target) else global_position + facing * attack_reach

func action_for(semantic: String, combo := 0) -> Dictionary:
	if innate_actions.has(semantic):
		var sequence: Variant = innate_actions[semantic]
		if sequence is Array:
			if sequence.is_empty(): return {}
			var action: Dictionary = sequence[posmod(combo, sequence.size())].duplicate(true)
			if semantic == "PRIMARY_TAP": action["combo_count"] = sequence.size()
			return action
		return sequence.duplicate(true)
	if not innate_actions.is_empty(): return {}
	return arena.database.get_action(loadout.combat_weapon().get("animation_family", "UNARMED"), semantic, combo)

func skill_at(index: int) -> Dictionary:
	if index < 0 or index > 2: return {}
	if index < innate_skills.size(): return innate_skills[index].duplicate(true)
	var id: String = loadout.sets[loadout.current_set].skills[index]
	var skill: Dictionary = arena.database.skills.get(id, {}).duplicate(true)
	if not skill.is_empty(): skill["skill_set"] = loadout.current_set
	return skill

func is_innate_action(action: Dictionary) -> bool:
	var id: String = str(action.get("id", ""))
	if id.is_empty(): return false
	for sequence in innate_actions.values():
		var entries: Array = sequence if sequence is Array else [sequence]
		for entry in entries:
			if str(entry.get("id", "")) == id: return true
	for entry in innate_skills:
		if str(entry.get("id", "")) == id: return true
	return false

func shield_definition() -> Dictionary:
	var shield: Dictionary = loadout.shield()
	return enemy_shield if shield.is_empty() else shield

func _refresh_visual() -> void:
	if not is_instance_valid(animation): return
	if not innate_actions.is_empty():
		var primary: Dictionary = action_for("PRIMARY_TAP")
		animation.switch_weapon_family(primary.get("animation_family", "UNARMED"), {})
		animation.equip_shield(shield_definition())
		return
	var weapon: Dictionary = loadout.weapon_at(0) if loadout.uses_paired_weapons() else loadout.weapon()
	var shield: Dictionary = loadout.shield()
	var second_sword: Dictionary = loadout.weapon_at(1) if loadout.is_dual_wielding() else {}
	if not _visual_loadout.has("weapon") or _visual_loadout.get("weapon", {}) != weapon:
		animation.switch_weapon_family(weapon.get("animation_family", "SINGLE_BLADE"), weapon)
	if animation.has_method("set_weapon_visible"):
		animation.set_weapon_visible(not weapon.is_empty() and not weapon.get("unarmed", false))
	if _visual_loadout.get("shield", {}) != shield:
		animation.equip_shield(shield)
	if _visual_loadout.get("second_sword", {}) != second_sword:
		animation.equip_dual_swords(second_sword)
	for slot in loadout.SLOTS:
		var item: Dictionary = arena.database.equipment.get(loadout.equipment.get(slot, ""), {})
		if _visual_loadout.get(slot, {}) != item:
			animation.equip(slot, item)
		_visual_loadout[slot] = item.duplicate(true)
	_visual_loadout["weapon"] = weapon.duplicate(true)
	_visual_loadout["shield"] = shield.duplicate(true)
	_visual_loadout["second_sword"] = second_sword.duplicate(true)

func face_action_target(action: Dictionary = {}) -> void:
	var aim: Vector3 = action.cast_intent.direction if action.has("cast_intent") else aim_world_point() - global_position
	var target := target_for_action(action)
	if is_instance_valid(target): aim = target.global_position - global_position
	aim.y = 0.0
	if aim.length_squared() > .05:
		facing = aim.normalized()

func _tick_unit(delta: float) -> void:
	combat.tick(delta)
	if inventory:
		inventory.tick(delta)
	delta = combat.motion_delta
	if delta <= .000001:
		return
	movement_actions.tick_pose(delta)
	if movement_actions.advance_jump(delta): return
	if not attack_assist.leap.is_empty() and combat.state == "ACTION" and combat.runner.action_phase == "STARTUP":
		animation.update_pose(delta,facing,"ACTION","STARTUP",combat.runner.action_time / maxf(.01,float(combat.runner.current_action.startup)))
		return
	move_direction = Vector3.ZERO
	if combat.state == "DEAD":
		velocity = Vector3.ZERO
		animation.update_pose(delta, facing, combat.state, "NONE", 0)
		return
	if is_human_controlled():
		var speed_mods: Dictionary = combat.passives.actor_modifiers("stat_update")
		var charge_modifier := float(speed_mods.get("charge_time_multiplier", 0.0)) + float(combat.statuses.modifiers().get("charge_time_multiplier", 0.0))
		input_router.hold_threshold = float(arena.database.combat_feel.input.get("tap_threshold", .25)) * maxf(.1, 1.0 + charge_modifier)
		if not control_input_blocked():
			var input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
			move_direction = (arena.camera_right() * input.x - arena.camera_forward() * input.y).normalized()
			move_direction = attack_assist.direction(delta,move_direction)
			var can_turn: bool = combat.state in ["NORMAL", "MOVE", "GUARD"] or combat.state == "CHARGING" and float(combat.charge_action.get("charge_move_multiplier", 0.0)) > 0.0
			if can_turn and move_direction.length_squared() > .01:
				facing = move_direction
	elif control_mode == "ai":
		_tick_ai(delta)
	var desired := Vector3.ZERO
	if combat.state in ["NORMAL", "MOVE"]:
		desired = move_direction * move_speed * combat.movement_multiplier() * movement_actions.speed_multiplier()
		combat.state = "MOVE" if desired.length_squared() > .01 else "NORMAL"
	elif combat.state == "CHARGING":
		desired = move_direction * move_speed * combat.movement_multiplier() * float(combat.charge_action.get("charge_move_multiplier", 0.0))
	elif combat.state == "GUARD":
		var shield: Dictionary = shield_definition()
		desired = move_direction * move_speed * combat.movement_multiplier() * float(shield.get("move_multiplier", .35))
	elif combat.state == "DODGE":
		desired = combat.dodge_direction * (7.2 if swimming else (12.0 if combat.dodge_is_dash else 10.5))
	desired += combat.knockback
	velocity.x = desired.x
	velocity.z = desired.z
	if not is_on_floor():
		velocity.y -= 22 * delta
	_move_character(delta, desired)
	if global_position.y < -6:
		global_position = spawn_point
		velocity = Vector3.ZERO
	animation.play_locomotion(desired.length_squared() > .05)
	var progress := 0.0
	if combat.runner.busy():
		var a: Dictionary = combat.runner.current_action
		var start := float(a.get("startup", .1))
		var active := float(a.get("active", .1))
		var recovery := float(a.get("recovery", .2))
		match combat.runner.action_phase:
			"STARTUP": progress = combat.runner.action_time / maxf(.001, start)
			"ACTIVE": progress = (combat.runner.action_time - start) / maxf(.001, active)
			"RECOVERY": progress = (combat.runner.action_time - start - active) / maxf(.001, recovery)
	elif combat.state == "DODGE":
		progress = combat.dodge_time / .42
	elif combat.state == "CHARGING":
		progress = combat.charge_progress()
	animation.update_pose(delta, facing, combat.state, combat.runner.action_phase, clampf(progress, 0, 1))
	combat.sync_precision_glow()

func _physics_process(delta: float) -> void:
	if is_instance_valid(arena.host) and (arena.host.paused or (is_instance_valid(arena.player) and not arena.player.is_physics_processing())):
		combat.clear_hitstop()
		return
	if form != null: form.tick(delta)
	if ladder.tick(delta):
		surface_traversal.clear()
		return
	var water_y: float=_water_surface()
	wading=not dead and is_finite(water_y) and global_position.y<water_y-.08
	swimming=not dead and is_finite(water_y) and global_position.y<water_y-.44
	var land_speed := move_speed
	if wading: move_speed*=.5 if swimming else .78
	if swimming and not movement_actions.airborne:
		global_position.y=maxf(global_position.y,water_y-.70)
		velocity.y=maxf(0.0,velocity.y)
	_tick_unit(delta)
	if dead:
		surface_traversal.clear()
	move_speed=land_speed
	# Buoyancy is movement, not a death/respawn event: preserve HP and resources.
	water_y=_water_surface()
	if not dead and not movement_actions.airborne and is_finite(water_y) and global_position.y<water_y-.70:
		global_position.y=water_y-.70
		velocity.y=maxf(0.0,velocity.y)
		swimming=true
	else:
		wading=not dead and is_finite(water_y) and global_position.y<water_y-.08
		swimming=not dead and is_finite(water_y) and global_position.y<water_y-.44

func _move_character(delta: float, desired: Vector3) -> void:
	# Traversal belongs inside the physics movement pass, before skeletal poses
	# and the camera read the result. Dodge uses its committed movement vector.
	floor_max_angle = deg_to_rad(surface_traversal.DODGE_SLOPE if combat.state == "DODGE" else surface_traversal.WALK_SLOPE)
	floor_constant_speed = true
	if surface_traversal.advance(self, desired, delta):
		return
	var previous := global_position
	var snap := floor_snap_length
	if surface_traversal.consume_gravity_release():
		# move_and_collide does not refresh CharacterBody3D's floor flag. After
		# releasing a lifted step, fall normally instead of snapping down .35m.
		floor_snap_length = 0
		if velocity.y <= 0:
			velocity.y = minf(velocity.y, -22.0 * delta)
	move_and_slide()
	floor_snap_length = snap
	surface_traversal.try_step(self, previous, desired, delta, swimming or wading)


func _water_surface() -> float:
	return arena.host.water_surface_at(global_position) if is_instance_valid(arena.host) and arena.host.has_method("water_surface_at") else -INF


func _tick_ai(delta: float) -> void:
	brain.tick(delta)

func safe_displace(offset: Vector3) -> void:
	var hit := KinematicCollision3D.new()
	if test_move(global_transform, offset, hit):
		offset = hit.get_travel() * .95
	global_position += offset
