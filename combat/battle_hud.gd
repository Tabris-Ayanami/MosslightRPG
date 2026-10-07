extends RefCounted
## One relation-driven overhead/boss/number presenter for world and laboratory.
## Weak identities and sampled HP avoid signal lifetimes or references to corpses.
const Art = preload("res://scripts/frontend/ui_art.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
const TRAIL_DELAY := .24
const TRAIL_SPEED := 1.35
const RED := Color("ba7270")
const ALLY := Color("91b984")
const GOLD := Color("f2c99a")
const TEXT := Color("f5ebda")
var states: Dictionary = {}
var overhead_entries: Array[Dictionary] = []
var lock_entries: Array[Dictionary] = []
var boss_entry: Dictionary = {}
var number_entries: Array[Dictionary] = []
var status_entries: Array[Dictionary] = []
var ui_scale := 1.0
var boss_active := false
var _canvas: WeakRef
var _retained: Dictionary = {}

class RetainedEntry extends Node2D:
	var presenter: RefCounted
	var kind := ""
	var data: Dictionary = {}
	var drawing_scale := 1.0
	var draw_count := 0
	func configure(next_kind: String, entry: Dictionary, scale_factor: float) -> void:
		var local := entry.duplicate()
		position = entry.feet if next_kind == "lock" else entry.position
		local.erase("position")
		if next_kind == "lock":
			local.head = (entry.head - entry.feet).snapped(Vector2(.001,.001))
			local.feet = Vector2.ZERO
		else:
			local.position = Vector2.ZERO
		# Impact is sampled for gameplay/UI consumers but is not drawn by this bar.
		local.erase("impact")
		local.erase("bounds")
		if next_kind == "number": local.age = minf(float(local.age), .12)
		if next_kind == "status": local.erase("age")
		if kind != next_kind or data != local or drawing_scale != scale_factor:
			kind = next_kind
			data = local
			drawing_scale = scale_factor
			queue_redraw()
	func _draw() -> void:
		draw_count += 1
		presenter._draw_entry(self, kind, data)

func attach(canvas: CanvasItem) -> void:
	# Scene ownership keeps draw commands; weak links avoid keeping dead HUDs alive.
	clear()
	_canvas = weakref(canvas)

func _sync_retained() -> void:
	var canvas: CanvasItem = _canvas.get_ref() if _canvas != null else null
	if not is_instance_valid(canvas): return
	var live := {}
	for group in [["overhead",overhead_entries],["lock",lock_entries],["boss",[boss_entry] if not boss_entry.is_empty() else []],["number",number_entries],["status",status_entries]]:
		for index in range(group[1].size()):
			var entry: Dictionary = group[1][index]
			var key: String = group[0] + ":" + str(entry.get("id",index))
			live[key] = true
			var node: RetainedEntry = _retained[key].get_ref() if _retained.has(key) else null
			if not is_instance_valid(node):
				node = RetainedEntry.new()
				node.name = "Battle_" + group[0]
				node.presenter = self
				canvas.add_child(node)
				_retained[key] = weakref(node)
			# Preserve bars -> lock -> boss -> numbers -> status drawing order.
			node.z_index = 1 + ["overhead","lock","boss","number","status"].find(group[0])
			node.configure(group[0],entry,ui_scale)
	for key in _retained.keys():
		if live.has(key): continue
		var node: Node2D = _retained[key].get_ref()
		if is_instance_valid(node):
			node.hide()
			node.queue_free()
		_retained.erase(key)

func clear() -> void:
	states.clear()
	overhead_entries.clear()
	lock_entries.clear()
	boss_entry.clear()
	number_entries.clear()
	status_entries.clear()
	boss_active = false
	_sync_retained()

func update(arena: Node, delta: float, viewport_size: Vector2, hidden := false) -> void:
	overhead_entries.clear()
	lock_entries.clear()
	boss_entry.clear()
	number_entries.clear()
	status_entries.clear()
	boss_active = false
	if not is_instance_valid(arena) or not is_instance_valid(arena.player) or not is_instance_valid(arena.camera):
		clear()
		return
	ui_scale = clampf(minf(viewport_size.x / 1280.0, viewport_size.y / 720.0), .6, 2.0)
	var live_ids: Dictionary = {}
	var best_boss_distance := INF
	var observer: Node=arena.controlled_actor()
	if not is_instance_valid(observer):
		clear()
		return
	# Controller identity decides which body already owns the corner HUD;
	# faction relationship decides every other unit's overhead presentation.
	for unit: Node in arena.units():
		var relation: StringName=arena.relation_between(observer,unit)
		if relation not in [&"ally",&"hostile"] or unit.combat.state == "DEAD" or unit.resources.current("HP") <= 0:
			continue
		var hostile: bool=relation==&"hostile"
		var id: int = unit.get_instance_id()
		live_ids[id] = true
		_sample(unit, 0.0 if hidden else maxf(delta, 0.0))
		# Allies remain readable while idle. Hostiles still reveal their bars
		# only in combat; merely locking a target does not engage it.
		if hidden: continue
		if hostile and arena.locked_target == unit and not arena.camera.is_position_behind(unit.global_position):
			var ground: Vector3=unit.global_position+Vector3.UP*.025
			var feet: Vector2=arena.world_to_screen(ground)
			var radius: float=maxf(.42,float(unit.definition.body.radius)*float(unit.definition.body.scale.x)+.10)
			# The same horizontal near/right basis as the player's stamina ring.
			# Projecting a world-space circle makes it lie flat under the feet.
			var near := Vector3(arena.camera.global_basis.z.x,0,arena.camera.global_basis.z.z).normalized()
			var right := Vector3(arena.camera.global_basis.x.x,0,arena.camera.global_basis.x.z).normalized()
			lock_entries.append({"id":id,"feet":feet,"head":feet,"show_head":false,
				"ring_right":(arena.world_to_screen(ground+right*radius)-feet).snapped(Vector2(.001,.001)),
				"ring_near":(arena.world_to_screen(ground+near*radius)-feet).snapped(Vector2(.001,.001))})
		if hostile and not unit.combat.in_combat: continue
		var distance: float = unit.global_position.distance_to(observer.global_position)
		if hostile and unit.is_boss and distance <= 35.0:
			# The arena header stays present when its boss moves offscreen.
			if distance < best_boss_distance or arena.locked_target == unit:
				best_boss_distance = -1.0 if arena.locked_target == unit else distance
				boss_entry = _entry(unit, Vector2(viewport_size.x * .5, 68.0 * ui_scale), 420.0 * ui_scale,relation)
				boss_entry["title"] = str(arena.database.enemies.get(unit.enemy_id, {}).get("boss_title", "区域头目"))
		if distance > 24.0: continue
		var world: Vector3 = unit.global_position + Vector3.UP * (2.8 if unit.is_boss else 2.05)
		if arena.camera.is_position_behind(world): continue
		var point: Vector2 = arena.world_to_screen(world)
		if not Rect2(Vector2(-100, -80), viewport_size + Vector2(200, 160)).has_point(point): continue
		# A boss is represented once, in the screen header; its lock ring remains in-world.
		if hostile and unit.is_boss: continue
		overhead_entries.append(_entry(unit,point,76.0*ui_scale,relation))
	for id in states.keys():
		if not live_ids.has(id): states.erase(id)
	boss_active = not boss_entry.is_empty()
	if hidden:
		_sync_retained()
		return
	for floating in arena.floaters:
		var is_damage: bool = bool(floating.get("is_damage", false))
		if is_damage and not Preferences.get_damage_numbers(): continue
		var world: Vector3 = floating.get("position", Vector3.ZERO)
		var target: Node = floating.target.get_ref() if floating.get("target") is WeakRef else null
		if is_damage and is_instance_valid(target):
			world = target.global_position + Vector3.UP * (2.8 if target.is_boss else 2.05)
		if arena.camera.is_position_behind(world): continue
		var point: Vector2 = arena.world_to_screen(world)
		var age: float = floating.get("time", 0.0)
		var shift: float = float(floating.get("lane", 0)) * 42.0
		point += Vector2(shift + shift * age * .45, -27.0 - age * 37.0) * ui_scale if is_damage else Vector2(0, -age * 28.0) * ui_scale
		if not Rect2(Vector2(-120,-100), viewport_size + Vector2(240,200)).has_point(point): continue
		var color: Color = floating.get("color", TEXT)
		color.a *= clampf(float(floating.get("life", .85)) / .28, 0.0, 1.0)
		var bounds := Rect2()
		if is_damage:
			var lift: float = floating.get("screen_lift",0.0)
			point.y -= lift * ui_scale
			var text_size: Vector2 = Art.font(700).get_string_size(str(floating.get("text","")),HORIZONTAL_ALIGNMENT_LEFT,-1,roundi(21*ui_scale))
			bounds = Rect2(point-Vector2(text_size.x*.5,text_size.y),text_size).grow(3*ui_scale)
			for _attempt in range(number_entries.size()):
				var rise := 0.0
				for previous in number_entries:
					if bounds.intersects(previous.bounds):
						rise = maxf(rise, bounds.end.y - previous.bounds.position.y + 4.0 * ui_scale)
				if rise <= 0: break
				lift += rise / ui_scale
				point.y -= rise
				bounds.position.y -= rise
			# Keep the assigned lift for this number's lifetime, including after an older number expires.
			floating["screen_lift"] = lift
		var entry := {"position": point, "text": str(floating.get("text", "")), "color": color, "age": age, "target_id": target.get_instance_id() if is_instance_valid(target) else 0}
		if is_damage:
			entry["bounds"] = bounds
			number_entries.append(entry)
		else: status_entries.append(entry)
	_sync_retained()

func _sample(enemy: Node, delta: float) -> void:
	var id: int = enemy.get_instance_id()
	var ratio: float = clampf(enemy.health.ratio(), 0.0, 1.0)
	var maximum: float = enemy.resources.max_value("HP")
	if not states.has(id) or not is_equal_approx(float(states[id].maximum), maximum):
		states[id] = {"target": weakref(enemy), "current": ratio, "trail": ratio, "delay": 0.0, "impact": 0.0, "maximum": maximum}
	var state: Dictionary = states[id]
	if ratio < float(state.current) - .00001:
		state.trail = maxf(float(state.trail), float(state.current))
		state.delay = TRAIL_DELAY
		state.impact = .20
	elif ratio > float(state.current) + .00001:
		state.trail = ratio
		state.delay = 0.0
	state.current = ratio
	state.impact = maxf(0.0, float(state.impact) - delta)
	var delay_before: float = state.delay
	state.delay = maxf(0.0, delay_before - delta)
	if state.delay <= 0:
		state.trail = move_toward(float(state.trail), ratio, maxf(0.0, delta - delay_before) * TRAIL_SPEED)

func _entry(enemy: Node, point: Vector2, width: float, relation: StringName) -> Dictionary:
	var state: Dictionary = states[enemy.get_instance_id()]
	return {"id": enemy.get_instance_id(), "relation":relation, "position": point, "width": width, "name": str(enemy.display_name), "level": enemy.loadout.level, "ratio": state.current, "trail": state.trail,
		"impact": state.impact, "poise": clampf(enemy.combat.current_poise / maxf(1.0, enemy.combat.max_poise()),0,1), "exposed": enemy.combat.state in ["EXPOSED", "GUARD_BROKEN"]}

func draw(canvas: CanvasItem) -> void:
	if _canvas != null and is_instance_valid(_canvas.get_ref()): return
	for entry in overhead_entries: _draw_entry(canvas, "overhead", entry)
	for entry in lock_entries: _draw_entry(canvas, "lock", entry)
	if not boss_entry.is_empty(): _draw_entry(canvas, "boss", boss_entry)
	for entry in number_entries: _draw_entry(canvas, "number", entry)
	for entry in status_entries: _draw_entry(canvas, "status", entry)

func _draw_entry(canvas: CanvasItem, kind: String, entry: Dictionary) -> void:
	if kind == "overhead":
		var p: Vector2 = entry.position
		var height: float = 6.0 * ui_scale
		var rect := Rect2(p + Vector2(-float(entry.width) * .5, 0), Vector2(entry.width, height))
		var allied: bool=entry.relation==&"ally"
		_bar(canvas, rect, float(entry.ratio), float(entry.trail), bool(entry.exposed),ALLY if allied else RED)
		if not allied:
			canvas.draw_rect(Rect2(p + Vector2(-entry.width*.5, height+2*ui_scale),Vector2(entry.width,ui_scale)),Color("2c3637"))
			canvas.draw_rect(Rect2(p + Vector2(-entry.width*.5, height+2*ui_scale),Vector2(entry.width*entry.poise,ui_scale)),Color("dcc2a0"))
		_label(canvas, p+Vector2(0,-6*ui_scale), entry.name+" · Lv%d" % entry.level+ (" · 破绽" if entry.exposed else ""), 11*ui_scale, TEXT)
	elif kind == "lock":
		var red := Color("f15c55")
		var right: Vector2=entry.get("ring_right",Vector2(16,0)*ui_scale)
		var near: Vector2=entry.get("ring_near",Vector2(0,8)*ui_scale)
		var ring := PackedVector2Array()
		for i in range(49):
			var angle := TAU*i/48.0
			ring.append(entry.feet+right*cos(angle)+near*sin(angle))
		canvas.draw_polyline(ring,Color(red,.95),1.25*ui_scale,true)
		for i in range(4):
			var angle := i*PI*.5
			var direction := right*cos(angle)+near*sin(angle)
			var side := (right*-sin(angle)+near*cos(angle))*.17
			var tip: Vector2 = entry.feet+direction*1.13
			var base: Vector2 = entry.feet+direction*1.48
			canvas.draw_colored_polygon(PackedVector2Array([tip,base+side,base-side]),red)
	elif kind == "boss":
		var p: Vector2 = entry.position
		_label(canvas,p+Vector2(0,-35*ui_scale),entry.title,12*ui_scale,Color("d6bba6"))
		_label(canvas,p+Vector2(0,-12*ui_scale),entry.name+" · Lv%d" % entry.level,20*ui_scale,TEXT)
		_bar(canvas,Rect2(p-Vector2(entry.width*.5,0),Vector2(entry.width,9*ui_scale)),entry.ratio,entry.trail,entry.exposed)
		Art.diamond(canvas,p+Vector2(-entry.width*.5-10*ui_scale,4.5*ui_scale),3*ui_scale,Color(GOLD,.65))
		Art.diamond(canvas,p+Vector2(entry.width*.5+10*ui_scale,4.5*ui_scale),3*ui_scale,Color(GOLD,.65))
	elif kind == "number":
		var pop: float = 1.0 + .12 * maxf(0.0,1.0-float(entry.age)/.12)
		_label(canvas,entry.position,entry.text,18*ui_scale*pop,entry.color,700)
	elif kind == "status":
		_label(canvas,entry.position,entry.text,17*ui_scale,entry.color,600)

func _bar(canvas: CanvasItem, rect: Rect2, ratio: float, trail: float, exposed: bool, fill_color:=RED) -> void:
	var cut: float=minf(rect.size.y*.55,rect.size.x*.5)
	var contour:=PackedVector2Array([rect.position+Vector2(cut,0),rect.position+Vector2(rect.size.x,0),rect.end-Vector2(cut,0),rect.position+Vector2(0,rect.size.y)])
	canvas.draw_colored_polygon(contour,Color("493f3b"))
	if trail > ratio: _bar_fill(canvas,contour,rect,trail,Color("d6b58a"))
	if ratio > 0: _bar_fill(canvas,contour,rect,ratio,fill_color)
	contour.append(contour[0])
	canvas.draw_polyline(contour,Color(GOLD,.8) if exposed else Color(Color("bdaf92"),.65),maxf(1,.6*ui_scale),true)

func _bar_fill(canvas: CanvasItem,contour: PackedVector2Array,rect: Rect2,ratio: float,color: Color) -> void:
	if ratio >= 1.0:
		canvas.draw_colored_polygon(contour,color)
		return
	var right: float=rect.size.x*clampf(ratio,0,1)
	var clip:=PackedVector2Array([rect.position,rect.position+Vector2(right,0),rect.position+Vector2(right,rect.size.y),rect.position+Vector2(0,rect.size.y)])
	for fill in Geometry2D.intersect_polygons(contour,clip):
		if fill.size()>=3: canvas.draw_colored_polygon(fill,color)

func _label(canvas: CanvasItem, at: Vector2, text: String, font_size: float, color: Color, weight := 600) -> void:
	var size := maxi(8,roundi(font_size))
	var font: Font = Art.font(weight)
	var point:=at-Vector2(font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,size).x*.5,0)
	canvas.draw_string_outline(font,point,text,HORIZONTAL_ALIGNMENT_LEFT,-1,size,maxi(2,roundi(2*ui_scale)),Color(.09,.11,.14,color.a*.82))
	canvas.draw_string(font,point,text,HORIZONTAL_ALIGNMENT_LEFT,-1,size,color)
