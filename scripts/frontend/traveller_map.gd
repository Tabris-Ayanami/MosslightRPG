extends "res://addons/dynamic_minimap/minimap.gd"
## DynamicMinimap tracking/projection + the shared scene-derived atlas.
## Upstream MIT source is kept intact; no per-frame group scan or 3D rerender.
signal requested_map
const F=preload("res://scripts/frontend/field_guide_art.gd")
const DOCUMENT=preload("res://scripts/frontend/atlas_document.gd")
const INN=preload("res://rpg/inn_room.gd")
var document: Control
var map_root: Node3D
var atlas_view: SubViewport
var ground: TextureRect
var clock := 0.0
var build_revision := 0

func _ready() -> void:
	radius=82
	world_scale=23
	rotate_with_player=false
	enabled_auto_register=false
	use_default_icons=false
	size=Vector2.ONE*radius*2
	mouse_filter=Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	mouse_force_pass_scroll_events=false
	ground=TextureRect.new()
	ground.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	ground.size=size
	ground.mouse_filter=Control.MOUSE_FILTER_IGNORE
	ground.material=ShaderMaterial.new()
	ground.material.shader=preload("res://shaders/frontend/atlas_window.gdshader")
	add_child(ground)
	ground.show_behind_parent=true

func bind_world(world: Node3D,player: Node3D) -> void:
	clear_world()
	map_root=world
	player_node=player
	var revision := build_revision
	# Existing chunk nodes may already have generated placeholder height arrays;
	# a populated dictionary alone does not imply persisted storage is ready.
	await get_tree().process_frame
	if revision!=build_revision or not is_instance_valid(map_root): return
	var terrain: Node=world.get_node("SculptableTerrain")
	# Terrain storage is loaded in a deferred callback, after game._ready().
	if terrain.chunks.is_empty(): await terrain.load_finished
	if revision!=build_revision or not is_instance_valid(map_root): return
	atlas_view=SubViewport.new()
	atlas_view.name="HandDrawnAtlas"
	atlas_view.size=Vector2i(DOCUMENT.RESOLUTION)
	atlas_view.disable_3d=true
	atlas_view.render_target_update_mode=SubViewport.UPDATE_ONCE
	add_child(atlas_view)
	document=DOCUMENT.new()
	atlas_view.add_child(document)
	document.build(world)
	ground.texture=atlas_view.get_texture()
	ground.material.set_shader_parameter("atlas",atlas_view.get_texture())
	_update_ground()
	queue_redraw()

func clear_world() -> void:
	build_revision+=1
	player_node=null
	map_root=null
	document=null
	if is_instance_valid(ground):
		ground.texture=null
		ground.material.set_shader_parameter("atlas",null)
	if is_instance_valid(atlas_view): atlas_view.queue_free()
	atlas_view=null
	targets.clear()

func _get_world_2d_pos(node) -> Vector2:
	if not is_instance_valid(node) or not is_instance_valid(map_root): return Vector2.ZERO
	var p: Vector3=map_root.to_local(node.global_position)
	return Vector2(p.x,p.z)

func heading_angle() -> float:
	if not is_instance_valid(player_node) or not is_instance_valid(map_root): return 0
	var facing: Vector3=map_root.global_basis.inverse()*player_node.facing
	return Vector2(facing.x,facing.z).angle()+PI*.5

func _process(delta: float) -> void:
	if not visible or not is_instance_valid(player_node): return
	clock+=delta
	if clock<.05: return
	clock=0
	_update_ground()
	queue_redraw()

func _update_ground() -> void:
	ground.visible=not _inside_inn()
	ground.material.set_shader_parameter("focus",_get_world_2d_pos(player_node))
	ground.material.set_shader_parameter("extent",Vector2.ONE*world_scale*2)

func _draw() -> void:
	if not is_instance_valid(document) or not is_instance_valid(player_node): return
	var center := Vector2.ONE*radius
	if _inside_inn():
		draw_circle(center,radius,Color("ded1ae"))
		var room_rect := Rect2(center-Vector2(55,50),Vector2(110,100))
		draw_rect(room_rect,Color("ac9470"))
		draw_rect(room_rect,Color("665643"),false,3)
		draw_rect(Rect2(center+Vector2(-43,-34),Vector2(19,31)),Color("e5dac1"))
		draw_rect(Rect2(center+Vector2(-41,-23),Vector2(15,18)),Color("79968a"))
		draw_line(center+Vector2(-9,42),center+Vector2(9,42),Color("668771"),5)
		var point: Vector3=player_node.global_position-INN.ROOM
		draw_player(self,center+Vector2(point.x,point.z)*11,heading_angle(),5)
		return
	for marker: Dictionary in document.landmarks:
		var at: Vector2=_world_to_minimap(marker.at)
		var offset := at-center
		var edge := offset.length()>radius-9
		if edge: at=center+offset.normalized()*(radius-9)
		F.ring(self,at,3.5,Color("574e38"),1)
		draw_circle(at,2,Color("e6c879"))
		if edge: draw_line(at,at+offset.normalized()*3,Color("675e45"),1,true)
	draw_player(self,center,heading_angle(),7)

func _inside_inn() -> bool:
	return is_instance_valid(player_node) and player_node.global_position.distance_to(INN.ROOM)<12

static func draw_player(c: CanvasItem,at: Vector2,angle: float,r := 8.0) -> void:
	var polygon := PackedVector2Array()
	for v in [Vector2(0,-1.3),Vector2(.65,.8),Vector2(0,.4),Vector2(-.65,.8)]: polygon.append(at+v.rotated(angle)*r)
	c.draw_colored_polygon(polygon,Color("fff5d5"))
	polygon.append(polygon[0])
	c.draw_polyline(polygon,Color("61543b"),1.5,true)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index==MOUSE_BUTTON_LEFT: requested_map.emit()
		accept_event()

func _exit_tree() -> void: clear_world()
