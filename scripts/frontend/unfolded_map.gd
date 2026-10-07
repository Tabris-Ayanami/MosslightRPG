extends Control
signal closed
signal dismissed
const F=preload("res://scripts/frontend/field_guide_art.gd")
const SCROLL=preload("res://scripts/frontend/scroll_art.gd")
const MINI=preload("res://scripts/frontend/traveller_map.gd")
const OPEN_SECONDS=.72
const CLOSE_SECONDS=.48
var minimap: Control
var chart: TextureRect
var reveal_window: Control
var rolls: RolledEdges
var zoom := 1.0
var focus := Vector2(20,-22)
var dragging := false
var panel := Rect2()
var plot := Rect2()
var paper_rect := Rect2()
var shown_paper := Rect2()
var pin := Vector2.INF
var click_start := Vector2.ZERO
var marks: InkOverlay
var progress := 0.0
var closing := false
var hover_action := ""

class InkOverlay extends Control:
	var chart_owner: Control
	func _draw() -> void:
		if is_instance_valid(chart_owner): chart_owner.draw_marks(self)

class RolledEdges extends Control:
	var chart_owner: Control
	func _draw() -> void:
		if not is_instance_valid(chart_owner): return
		var r: Rect2=chart_owner.shown_paper
		var t: float=chart_owner.open_amount()
		SCROLL.roller(self,r.position.x,r.position.y-5,r.size.y+10,true,t)
		SCROLL.roller(self,r.end.x,r.position.y-5,r.size.y+10,false,t)

func _ready() -> void:
	mouse_filter=Control.MOUSE_FILTER_STOP
	mouse_force_pass_scroll_events=false
	reveal_window=Control.new()
	reveal_window.mouse_filter=Control.MOUSE_FILTER_IGNORE
	reveal_window.clip_contents=true
	add_child(reveal_window)
	chart=TextureRect.new()
	chart.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	chart.mouse_filter=Control.MOUSE_FILTER_IGNORE
	chart.material=ShaderMaterial.new()
	chart.material.shader=preload("res://shaders/frontend/atlas_window.gdshader")
	chart.material.set_shader_parameter("circular",false)
	chart.material.set_shader_parameter("aged_parchment",true)
	reveal_window.add_child(chart)
	marks=InkOverlay.new()
	marks.chart_owner=self
	marks.mouse_filter=Control.MOUSE_FILTER_IGNORE
	marks.clip_contents=true
	reveal_window.add_child(marks)
	rolls=RolledEdges.new()
	rolls.chart_owner=self
	rolls.mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(rolls)
	resized.connect(resize)
	resize()

func resize() -> void:
	panel=Rect2((size-Vector2(1170,614))*.5,Vector2(1170,614))
	paper_rect=Rect2(panel.position+Vector2(35,10),Vector2(1100,586))
	plot=paper_rect.grow(-14)
	chart.size=plot.size
	marks.size=plot.size
	rolls.size=size
	update_reveal()
	update_chart()

func present(source: Control) -> void:
	minimap=source
	visible=true
	dragging=false
	closing=false
	progress=0
	zoom=1
	focus=Vector2(20,-22)
	chart.material.set_shader_parameter("atlas",minimap.atlas_view.get_texture() if is_instance_valid(minimap.atlas_view) else null)
	chart.texture=minimap.atlas_view.get_texture() if is_instance_valid(minimap.atlas_view) else null
	update_reveal()
	update_chart()

func dismiss() -> void:
	closing=true
	dragging=false

func animating() -> bool: return visible and (closing or progress<1)
func open_amount() -> float: return smoothstep(0,1,progress)
func scale_factor() -> float: return 5.1*zoom
func project(p: Vector2) -> Vector2: return plot.get_center()+(p-focus)*scale_factor()
func unproject(p: Vector2) -> Vector2: return (p-plot.get_center())/scale_factor()+focus

func update_reveal() -> void:
	# Reveal the same unmoving ink document; never squash its lettering.
	var width := lerpf(37,paper_rect.size.x,open_amount())
	shown_paper=Rect2(Vector2(paper_rect.get_center().x-width*.5,paper_rect.position.y),Vector2(width,paper_rect.size.y))
	reveal_window.position=shown_paper.position
	reveal_window.size=shown_paper.size
	chart.position=plot.position-reveal_window.position
	marks.position=chart.position
	queue_redraw()
	rolls.queue_redraw()

func update_chart() -> void:
	if not is_instance_valid(chart): return
	focus.x=clampf(focus.x,-32,74)
	focus.y=clampf(focus.y,-72,29)
	chart.material.set_shader_parameter("focus",focus)
	chart.material.set_shader_parameter("extent",plot.size/scale_factor())
	if is_instance_valid(marks): marks.queue_redraw()

func actions() -> Dictionary:
	return {"close":Rect2(plot.end-Vector2(45,plot.size.y-12),Vector2(36,36)),
		"home":Rect2(plot.position+Vector2(34,plot.size.y-57),Vector2(85,37)),
		"minus":Rect2(plot.position+Vector2(133,plot.size.y-57),Vector2(34,37)),
		"plus":Rect2(plot.position+Vector2(174,plot.size.y-57),Vector2(34,37))}

func action_at(p: Vector2) -> String:
	for id: String in actions():
		if actions()[id].has_point(p): return id
	return ""

func draw_marks(c: CanvasItem) -> void:
	if not is_instance_valid(minimap) or not is_instance_valid(minimap.document): return
	for marker: Dictionary in minimap.document.landmarks:
		var at: Vector2=project(marker.at)-plot.position
		if not Rect2(Vector2(40,20),plot.size-Vector2(140,50)).has_point(at): continue
		F.ring(c,at,6,Color("59452f"),1.0)
		F.text(c,at+Vector2(13,-12),marker.name,25,Color("57432d"))
	var here: Vector2=project(minimap._get_world_2d_pos(minimap.player_node))-plot.position
	if Rect2(Vector2.ONE*12,plot.size-Vector2.ONE*24).has_point(here):
		F.wash(c,here,Vector2.ONE*14,Color("ead3a2"))
		MINI.draw_player(c,here,minimap.heading_angle(),9)
	if pin.is_finite():
		var at := project(pin)-plot.position
		F.stroke(c,at,8,[Vector2(-1,-1),Vector2(1,1)],Color("955c44"),1.7)
		F.stroke(c,at,8,[Vector2(1,-1),Vector2(-1,1)],Color("955c44"),1.7)
	# Cartouche and wind rose are printed directly in the vellum margin.
	F.text(c,Vector2(43,72),"风息原野",43,Color("695237"))
	F.text(c,Vector2(47,107),"山川与行迹",20,Color("8e7452"))
	var north := Vector2(plot.size.x-103,103)
	F.centered(c,north-Vector2(0,42),"北",21,Color("795d3c"))
	F.ring(c,north,27,Color("8b7250",.4),.75)
	for i in range(8):
		var a := i*PI*.25
		var r := 38 if i%2==0 else 24
		F.shape(c,north,r,[Vector2.ZERO,Vector2(-.12,-.33).rotated(a),Vector2(0,-1).rotated(a),Vector2(.12,-.33).rotated(a)],Color("e8d6ad") if i%2 else Color("9a7950"),Color("80613e"),.8)
	for id: String in actions():
		var at: Vector2=actions()[id].get_center()-plot.position
		var color := Color("623e2a") if hover_action==id else Color("866846")
		if id=="close":
			F.stroke(c,at,10,[Vector2(-.5,-.5),Vector2(.5,.5)],color,1.3)
			F.stroke(c,at,10,[Vector2(.5,-.5),Vector2(-.5,.5)],color,1.3)
		else: F.centered(c,at+Vector2(0,7),{"home":"归位","plus":"＋","minus":"−"}[id],24,color)

func _process(delta: float) -> void:
	if not visible: return
	if animating():
		progress=clampf(progress+delta*(-1.0/CLOSE_SECONDS if closing else 1.0/OPEN_SECONDS),0,1)
		update_reveal()
		if closing and progress<=0:
			visible=false
			closing=false
			dismissed.emit()
	if is_instance_valid(marks): marks.queue_redraw()

func _draw() -> void:
	SCROLL.paper(self,shown_paper)

func _gui_input(event: InputEvent) -> void:
	if animating():
		accept_event()
		return
	if event is InputEventMouseButton:
		if event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed:
				click_start=event.position
				match action_at(event.position):
					"close": closed.emit()
					"home":
						if is_instance_valid(minimap.player_node): focus=minimap._get_world_2d_pos(minimap.player_node); update_chart()
					"plus": set_zoom(zoom*1.25,plot.get_center())
					"minus": set_zoom(zoom/1.25,plot.get_center())
					_: dragging=plot.has_point(event.position)
			else:
				if dragging and click_start.distance_to(event.position)<5:
					pin=unproject(event.position)
					update_chart()
				dragging=false
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN] and plot.has_point(event.position):
			set_zoom(zoom*(1.18 if event.button_index==MOUSE_BUTTON_WHEEL_UP else 1/1.18),event.position)
		elif event.pressed and event.button_index==MOUSE_BUTTON_RIGHT:
			pin=Vector2.INF
			update_chart()
		accept_event()
	elif event is InputEventMouseMotion:
		hover_action=action_at(event.position)
		mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND if hover_action!="" else (Control.CURSOR_DRAG if plot.has_point(event.position) else Control.CURSOR_ARROW)
		if dragging:
			focus-=event.relative/scale_factor()
			update_chart()
		accept_event()

func set_zoom(value: float,anchor: Vector2) -> void:
	var world_anchor := unproject(anchor)
	zoom=clampf(value,.8,3.4)
	focus=world_anchor-(anchor-plot.get_center())/scale_factor()
	update_chart()

func _notification(what: int) -> void:
	if what==NOTIFICATION_VISIBILITY_CHANGED and not visible: dragging=false

