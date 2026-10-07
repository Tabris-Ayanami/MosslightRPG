extends Control
var game: Node
var progress := 0.0
var projection = preload("res://combat/stamina_ring.gd").new()
func _ready() -> void: mouse_filter=MOUSE_FILTER_IGNORE
func _draw() -> void:
	if progress<=0 or not is_instance_valid(game): return
	var actor: Node=game.controlled_actor()
	var origin: Vector3=actor.global_position+Vector3.UP*.03
	if game.camera.is_position_behind(origin): return
	var maximum: int=int(actor.resources.max_value("Stamina"))
	var radius:=clampf(.55+float(maximum-3)*.05,.55,.75)*1.45
	if is_instance_valid(game.combat_world):
		projection.update(game.combat_world, 0.0)
		radius = projection.radius_world
	var near:=Vector3(game.camera.global_basis.z.x,0,game.camera.global_basis.z.z).normalized()
	var right: Vector3=game.camera.global_basis.x
	var points:=PackedVector2Array()
	var fill:=PackedVector2Array()
	for i in range(65):
		var angle: float=-PI*.5+TAU*float(i)/64
		var p: Vector3=origin+(near*cos(angle)+right*sin(angle))*radius
		points.append(game.world_to_screen(p))
		if float(i)/64<=progress: fill.append(game.world_to_screen(p))
	var width:=maxf(2,game.get_viewport().get_visible_rect().size.y/360)
	draw_polyline(points,Color("384342",.50),width+2,true)
	draw_polyline(points,Color("9ca29c",.32),width,true)
	if fill.size()>1: draw_polyline(fill,Color("d0d0bd",.92),width,true)
