extends Node
## One click is one approach and one attack. Manual input cancels that intent.
var actor: CharacterBody3D
var destination: WeakRef
var approach_time := 0.0
var indicator: Node3D
var leap: Dictionary = {}

func setup(owner_actor: CharacterBody3D) -> void:
	actor = owner_actor
	indicator = preload("res://combat/cast_indicator.gd").new()
	indicator.actor = actor
	actor.add_child(indicator)
	indicator.hide()

func cancel() -> void:
	destination = null
	approach_time = 0.0

func approaching() -> bool:
	return destination != null and is_instance_valid(destination.get_ref())

func _physics_process(_delta: float) -> void:
	indicator.hide()
	if not actor.is_human_controlled() or actor.control_input_blocked():
		cancel()
		return
	actor.arena.update_hover_lock(actor)
	var combat: Node = actor.combat
	if combat.state != "CHARGING" or combat.charge_time < actor.input_router.hold_threshold or actor.arena.pointer_blocked: return
	var action: Dictionary = combat.charge_action.duplicate(true)
	var origin := actor.global_position
	var point: Vector3 = actor.aim_world_point(action)
	var direction := Vector3(point.x-origin.x,0,point.z-origin.z).normalized()
	if direction.is_zero_approx(): direction = actor.facing
	action.range = combat._action_reach(action)
	var modifiers: Dictionary = combat.passives.modifiers("damage_before", combat.context(null,action), combat._action_weapon(action))
	for key in ["radius", "width", "length", "explosion_radius"]:
		if action.has(key): action[key] *= 1.0 + float(modifiers.get("area_multiplier",0.0))
	indicator.show_preview({"action":action, "origin":origin, "intent":{"point":actor.arena.clamp_aim_point(origin,point,action.range), "direction":direction}, "valid":true})

func request_primary() -> bool:
	if not actor.is_human_controlled() or not actor.combat.can_start() or actor.control_input_blocked() or actor.arena.pointer_blocked: return false
	var target: Node = actor.arena.target_for(actor)
	if not is_instance_valid(target):
		# Mild assistance only in the aimed direction; never attack behind the player.
		var aim: Vector3 = actor.aim_world_point() - actor.global_position
		aim.y = 0
		var best := 4.5
		for unit in actor.arena.targets_for(actor):
			var offset: Vector3 = unit.global_position - actor.global_position
			offset.y = 0
			if offset.length() < best and aim.normalized().dot(offset.normalized()) > .82 and actor.arena.line_clear(actor.global_position,unit.global_position):
				target = unit
				best = offset.length()
	if not is_instance_valid(target): return false
	var action: Dictionary = actor.action_for("PRIMARY_TAP",actor.combat.combo)
	var distance: float = actor.global_position.distance_to(target.global_position)
	if distance > 18.0 or not actor.arena.line_clear(actor.global_position,target.global_position): return false
	actor.arena.locked_target = target
	actor.face_action_target()
	if distance <= maxf(.9,actor.combat._action_reach(action,target)*.80): return false
	destination = weakref(target)
	approach_time = 0.0
	return true

func direction(delta: float, manual: Vector3) -> Vector3:
	if not manual.is_zero_approx() or actor.control_input_blocked() or actor.combat.state not in ["NORMAL","MOVE"]:
		cancel()
		return manual
	if not approaching(): return manual
	var target: Node = destination.get_ref()
	approach_time += delta
	if target.combat.state == "DEAD" or not target.is_inside_tree() or not actor.arena.are_hostile(actor,target) or approach_time > 6.0 or actor.arena.pointer_blocked:
		cancel()
		return manual
	var offset: Vector3 = target.global_position-actor.global_position
	offset.y = 0
	var action: Dictionary = actor.action_for("PRIMARY_TAP",actor.combat.combo)
	var reach: float = maxf(.9,actor.combat._action_reach(action,target)*.80)
	if offset.length() <= reach and actor.arena.line_clear(actor.global_position,target.global_position):
		cancel()
		actor.arena.locked_target = target
		actor.facing = offset.normalized()
		actor.combat.weapon_action("PRIMARY_TAP")
		return Vector3.ZERO
	var navigation: Node = actor.arena.host.get("world_navigation") if is_instance_valid(actor.arena.host) else null
	return navigation.direction_for(actor,target.global_position) if is_instance_valid(navigation) else offset.normalized()

func leap_plan(target: Node, action: Dictionary) -> Dictionary:
	if not is_instance_valid(target): return {"error":"请锁定一个敌人"}
	var from := actor.global_position
	var offset: Vector3 = target.global_position-from
	offset.y = 0
	var separation: float = float(target.definition.body.radius)*float(target.definition.body.scale.x)+.65
	var point: Vector3 = target.global_position-offset.normalized()*minf(separation,offset.length())
	var ray := PhysicsRayQueryParameters3D.create(point+Vector3.UP*2.0,point-Vector3.UP*3.0,1)
	var ground := actor.get_world_3d().direct_space_state.intersect_ray(ray)
	if ground.is_empty() or ground.normal.y < .65: return {"error":"目标附近没有可落脚的位置"}
	point.y = ground.position.y + .035
	if absf(point.y-from.y)>1.5: return {"error":"目标与落点高度差太大"}
	var plan := {"error":"", "from":from, "to":point, "height":1.1, "windup":.16, "duration":float(action.get("startup",.82)), "blocked":false}
	var previous := from
	for i in range(1,17):
		var next := arc(plan,float(i)/16.0)
		var pose := actor.global_transform
		pose.origin = previous
		if actor.test_move(pose,next-previous): return {"error":"跃起路径被挡住"}
		previous = next
	return plan

func arc(plan: Dictionary, progress: float) -> Vector3:
	return plan.from.lerp(plan.to,progress)+Vector3.UP*sin(progress*PI)*float(plan.height)

func advance_leap(delta: float) -> void:
	if leap.is_empty(): return
	if actor.combat.state != "ACTION" or not actor.combat.runner.current_action.get("leap_motion",false):
		leap.clear()
		return
	var progress := clampf((actor.combat.runner.action_time+delta-float(leap.windup))/maxf(.01,float(leap.duration)-float(leap.windup)),0,1)
	var desired := arc(leap,progress)
	var collision: KinematicCollision3D = actor.move_and_collide(desired-actor.global_position)
	actor.velocity = Vector3.ZERO
	if collision != null and not (progress>.92 and collision.get_normal().y>.65): leap.blocked = true
	if leap.blocked:
		actor.combat.runner.cancel_action()
		actor.combat.state = "NORMAL"
		leap.clear()
		actor.combat.fail("跳劈路径受阻")
