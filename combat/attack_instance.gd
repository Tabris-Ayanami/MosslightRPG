extends Node3D

const Hitbox = preload("res://combat/hitbox_component.gd")
const Art = preload("res://scripts/art.gd")
var arena: Node
var source: Node
var action: Dictionary
var origin := Vector3.ZERO
var direction := Vector3.FORWARD
var aim_point := Vector3.ZERO
var target: Node
var hitbox := Hitbox.new()
var time := 0.0
var next_tick := 0.0
var travel := 0.0
var pierced := 0
var duration := .1
var interval := 0.0
var projectile := false
var visual: Node3D

func _ready() -> void:
	# The attacker can move while this projectile or persistent area exists.
	# A later impact reveals its launch point rather than a hidden live position.
	action["awareness_origin"] = origin
	projectile = float(action.get("projectile_speed", 0.0)) > 0.0
	interval = float(action.get("tick_interval", 0.0))
	duration = float(action.get("duration", action.get("active", .1)))
	if int(action.get("waves", 0)) > 0:
		duration = maxf(.01, float(action.get("waves", 1)) * maxf(.1, interval) - .001)
	position = origin + Vector3.UP * .8 if projectile else Vector3.ZERO
	var color: Color = arena.element_color(action.get("damage_type", "PHYSICAL"))
	if projectile:
		var stone: bool = action.get("animation_id", "") == "overhand_throw"
		visual = Art.sphere(self, Vector3.ZERO, Vector3(.55, .50, .55) if stone else Vector3(.18, .18, .65), Color("b9a184") if stone else color)
		visual.look_at(position + direction)
	else:
		var center := aim_point if action.get("targeting", "") in ["POINT", "TARGET"] or action.get("center_on_point", false) else origin
		var shape := CombatTargeting.shape_for(action)
		var melee_path: bool = action.get("animation_family", "") in ["SINGLE_BLADE", "SHORT_WEAPON", "POLEARM", "HEAVY_2H"] and action.get("presentation_type", "") == "WEAPON_ACTION" and shape in ["CONE", "DIRECTION", "LINE"] and interval <= 0.0
		if action.get("animation_family", "") == "UNARMED":
			pass
		elif melee_path:
			# The blade retains its real hand trail; this brief outer sweep also
			# shows the gameplay reach, including a spear's narrow thrust lane.
			if shape == "CONE":
				var arc := deg_to_rad(float(action.get("angle",90)))
				visual = Art.ring(self,origin+Vector3.UP*.18,float(action.get("range",3)),.065,Color("e7eacf"),atan2(direction.x,direction.z)-arc*.5,arc)
			else:
				visual = Art.line(self,origin+Vector3.UP*.20,origin+direction*float(action.get("range",3))+Vector3.UP*.20,.065,Color("e7eacf"))
			var material := StandardMaterial3D.new()
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.albedo_color = Color(.90,.96,1,.48)
			visual.material_override = material
			visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif shape in ["LINE", "DIRECTION", "POINT/LINE"]:
			var length := float(action.get("length", action.get("range", 3.0))) if shape == "POINT/LINE" else float(action.get("range", 3.0))
			var a := center - direction * length * .5 if shape == "POINT/LINE" or action.get("center_on_point", false) else center
			visual = Art.line(self, a + Vector3.UP * .09, a + direction * length + Vector3.UP * .09, float(action.get("width", 1.0)), color)
			visual.scale.y = .08
		elif shape == "CONE":
			var angle := deg_to_rad(float(action.get("angle", 90)))
			visual = Art.ring(self, center + Vector3.UP * .06, float(action.get("range", 3.0)), .09, color, atan2(direction.x, direction.z) - angle * .5, angle)
		else:
			visual = Art.ring(self, center + Vector3.UP * .06, float(action.get("radius", 2.0)), .10, color)
		if interval > 0.0:
			for i in range(8):
				var offset := Vector3(sin(i * TAU / 8), .12, cos(i * TAU / 8)) * float(action.get("radius", 2.0)) * .7
				if shape in ["LINE", "POINT/LINE"]:
					offset = direction * (float(i) / 7 - .5) * float(action.get("length", action.get("range", 6.0)))
				Art.sphere(self, center + offset + Vector3.UP * .25, Vector3(.2, .4, .2), color)
		_tick_hits()
		next_tick = interval if interval > 0.0 else 9999.0

func _physics_process(delta: float) -> void:
	if not is_instance_valid(source):
		queue_free()
		return
	if not projectile and interval <= 0.0 and (source.combat.hitstop_remaining > 0.0 or source.combat.stopped_this_tick): return
	time += delta
	if projectile:
		var start := global_position
		var end := start + direction * float(action.projectile_speed) * delta
		var query := PhysicsRayQueryParameters3D.create(start, end, 1)
		var wall := get_world_3d().direct_space_state.intersect_ray(query)
		if not wall.is_empty():
			end = wall.position
		var targets: Array = arena.targets_for(source)
		targets.sort_custom(func(a: Node3D, b: Node3D) -> bool: return a.global_position.distance_squared_to(start) < b.global_position.distance_squared_to(start))
		for victim in targets:
			if victim.combat.state == "DEAD":
				continue
			var point: Vector3 = victim.global_position + Vector3.UP * .8
			var closest := Geometry3D.get_closest_point_to_segment(point, start, end)
			if closest.distance_to(point) < CombatTargeting.projectile_radius(action) and hitbox.can_hit(victim, time):
				source.combat.hit_target(victim, action, direction)
				if float(action.get("explosion_radius", 0.0)) > 0.0:
					arena.effect_ring(victim.global_position, float(action.explosion_radius), arena.element_color(action.get("damage_type", "FIRE")), .35)
					for other in targets:
						if other != victim and other.global_position.distance_to(victim.global_position) <= float(action.explosion_radius) and hitbox.can_hit(other, time):
							source.combat.hit_target(other, action, direction)
				pierced += 1
				if pierced > int(action.get("pierce", 0)):
					queue_free()
					return
		global_position = end
		travel += start.distance_to(end)
		if not wall.is_empty() or travel >= float(action.get("range", 12)):
			queue_free()
	else:
		if interval <= 0.0 and action.has("instance_id") and (not source.combat.runner.busy() or source.combat.runner.action_phase != "ACTIVE" or source.combat.runner.current_action.get("instance_id", "") != action.get("parent_instance_id", action.instance_id)):
			queue_free()
			return
		if interval <= 0.0 and time < duration:
			_tick_hits()
		while interval > 0.0 and time + .00001 >= next_tick and next_tick < duration - .00001:
			_tick_hits(next_tick)
			next_tick += interval
		if time >= duration:
			queue_free()

func _tick_hits(scheduled_time := -1.0) -> void:
	if not is_instance_valid(source):
		return
	for victim in arena.targets_for(source):
		if victim.combat.state == "DEAD":
			continue
		if action.get("targeting", "") == "TARGET" and victim != target:
			continue
		if CombatTargeting.contains(action.get("targeting", "CONE"), origin, direction, victim.global_position, action, aim_point) and arena.line_clear(origin, victim.global_position):
			if hitbox.can_hit(victim, time if scheduled_time < 0.0 else scheduled_time, interval):
				source.combat.hit_target(victim, action, (victim.global_position - origin).normalized())
				# A parry or grab cancels this swing immediately, including its other targets.
				if interval <= 0.0 and action.has("instance_id") and (not source.combat.runner.busy() or source.combat.runner.current_action.get("instance_id", "") != action.get("parent_instance_id", action.instance_id)):
					return
