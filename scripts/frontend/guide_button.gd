extends Button
const A=preload("res://scripts/frontend/ui_art.gd")
const F=preload("res://scripts/frontend/field_guide_art.gd")
const LEATHER=preload("res://scripts/frontend/leather_art.gd")
const CAREER_MARKS=preload("res://scripts/frontend/career_marks.gd")
const CONTENT_ART=preload("res://scripts/frontend/content_art.gd")
var content_icon: Texture2D
var kind := "bag"
var role := "item"
var caption := ""
var quantity := ""
var tint := F.SAGE
var selected := false
var learned := true
var pulse := 0.0
var reveal := 1.0
var label_size := 20
var pencil_black := 0.0

func _ready() -> void:
	texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	mouse_force_pass_scroll_events=false
	A.invisible_button(self)
	add_theme_font_override("font",F.font())
	add_theme_font_size_override("font_size",16)
	for state in ["font_color","font_hover_color","font_pressed_color","font_focus_color","font_disabled_color"]: add_theme_color_override(state,Color.TRANSPARENT)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	pressed.connect(func(): pulse=1.0)

func _process(delta: float) -> void:
	if pulse>0:
		pulse=maxf(0,pulse-delta*4)
		queue_redraw()

func _draw() -> void:
	var hot := is_hovered() or has_focus()
	var center := size*.5
	var ink := F.INK if not disabled else Color(F.SOFT,.7)
	match role:
		"top_bookmark":
			var hide_color := Color("856347") if not selected else Color("537267")
			LEATHER.draw(self,Rect2(1,1,size.x-2,size.y-1),hide_color.lightened(.08 if hot else 0),5,true)
			F.centered(self,Vector2(center.x,24),text,label_size,Color("efe0be") if selected else Color("dcc7a5"),600 if selected else 400)
		"equip_small":
			if selected or hot: F.wash(self,center,Vector2(size.x*.46,27),Color(F.SAGE,.48 if selected else .22))
			if CONTENT_ART.draw(self,content_icon,Vector2(37,39),24): pass
			elif kind!="": F.item(self,kind,Vector2(37,39),24,tint)
			else: F.pen(self,Vector2(29,39),Vector2(45,39),Color(F.SOFT,.43),.8)
			F.text(self,Vector2(77,28),caption,14,F.SOFT)
			var fs := 19
			while fs>13 and F.font().get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,fs).x>size.x-84: fs-=1
			F.text(self,Vector2(77,54),text,fs,ink,500)
		"career":
			var graphite := Color("999387").lerp(Color("302c26"),pencil_black)
			if disabled and not selected: graphite.a=.42
			var at := Vector2(53,38)
			if hot and not disabled: F.wash(self,at,Vector2(34,34),Color(F.SAGE,.3))
			F.ring(self,at,29,Color(graphite,.45 if not selected else .8),.75)
			if not CONTENT_ART.draw(self,content_icon,at,23,graphite.a): CAREER_MARKS.draw(self,kind,at,23,graphite)
			F.hatch(self,Rect2(at+Vector2(-16,22),Vector2(32,4)),Color(graphite,.2),4)
			F.centered(self,Vector2(53,83),text,20,graphite,600 if selected else 400)
			if caption!="": F.centered(self,Vector2(53,103),caption,12,Color(graphite,.7))
		"item","equipment":
			if selected or hot: F.wash(self,center,Vector2(size.x*.47,size.y*.36),Color(F.SAGE,.56 if selected else .25))
			var where := center-Vector2(0,3) if role=="item" else Vector2(size.x*.5,41)
			var radius := minf(size.x,size.y)*(.25 if role=="equipment" else .32)
			if not CONTENT_ART.draw(self,content_icon,where,radius): F.item(self,kind,where,radius,tint)
			if selected: F.stroke(self,Vector2(12,12),5,[Vector2(-.5,0),Vector2(-.1,.5),Vector2(.8,-.6)],F.INK,1.1)
			if role=="equipment":
				F.centered(self,Vector2(center.x,91),text,19,F.INK,600)
				F.centered(self,Vector2(center.x,114),caption,13,F.SOFT)
			if quantity!="": F.text(self,Vector2(size.x-10-F.font().get_string_size(quantity,HORIZONTAL_ALIGNMENT_LEFT,-1,15).x,size.y-9),quantity,15,F.INK)
		"tab":
			var fill := Color("d5c7a9") if selected else Color("e4d8bd")
			fill.a=.73 if selected else .37
			F.shape(self,Vector2.ZERO,1,[Vector2(1,2),Vector2(size.x-5,0),Vector2(size.x-1,4),Vector2(size.x-2,size.y-1),Vector2(0,size.y)],fill,Color(F.LINE,.85),.85)
			F.centered(self,Vector2(center.x,center.y+7),text,label_size,ink,600 if selected else 400)
			if selected or hot: F.pen(self,Vector2(14,size.y-5),Vector2(size.x-14,size.y-5),Color(F.INK,.72 if selected else .36),1.2)
		"text":
			if hot and not disabled: F.wash(self,center,Vector2(size.x*.42,size.y*.28),Color(F.SAGE,.30))
			F.centered(self,Vector2(center.x,center.y+7),text,label_size,ink,600 if selected else 400)
			if selected: draw_circle(Vector2(7,center.y),2.0,F.SAGE)
		"trait":
			if hot and not disabled: F.wash(self,center,Vector2(size.x*.45,13),Color(F.SAGE,.2))
			if selected: F.text(self,Vector2(5,center.y+8),"›",25,F.SAGE)
			F.text(self,Vector2(31,center.y+8),text,label_size,F.INK if selected else F.SOFT,600 if selected else 400)
		"bookmark":
			var hide_color := Color("71513b") if not selected else Color("536a53")
			LEATHER.draw(self,Rect2(1,1,size.x-2,size.y-3),hide_color.lightened(.08 if hot else 0),7,true)
			var stamp := Color("ead6b2") if selected else Color("cbb18b")
			if kind=="person": F.item(self,kind,Vector2(37,23),11,stamp)
			else: A.icon(self,kind,Vector2(37,23),11,stamp)
			F.centered(self,Vector2(37,54),text,20,stamp,600)
			F.centered(self,Vector2(37,72),caption,11,Color(stamp,.66))
		"node":
			var at := Vector2(center.x,28)
			if selected or hot: F.wash(self,at,Vector2(32,30),Color(F.SAGE,.6))
			F.ring(self,at,23,Color(F.INK,1.0 if learned else .48),1.2)
			if learned: F.ring(self,at,19,Color(F.SOFT,.35),.6)
			if CONTENT_ART.draw(self,content_icon,at,16,1.0 if learned else .36): pass
			elif kind in ["flower","feather"]: F.item(self,kind,at,12,Color(F.SAGE,.8))
			else: A.icon(self,kind,at,12,Color(F.INK,.9 if learned else .36))
			F.centered(self,Vector2(center.x,65),text,16,Color(F.INK,1.0 if learned else .63),500)
			if not learned: F.text(self,Vector2(size.x-19,19),"·",18,F.SOFT)
		"loadout":
			if selected or hot: F.wash(self,center-Vector2(0,8),Vector2(42,36),Color(F.SAGE,.5))
			F.ring(self,Vector2(center.x,32),27,Color(F.INK,.75),1.0)
			if CONTENT_ART.draw(self,content_icon,Vector2(center.x,32),20): pass
			elif kind in ["flower","feather"]: F.item(self,kind,Vector2(center.x,32),16,F.SAGE)
			elif kind!="": A.icon(self,kind,Vector2(center.x,32),16,F.INK)
			else: F.centered(self,Vector2(center.x,38),"—",20,F.SOFT)
			F.centered(self,Vector2(center.x,78),caption,20,F.INK,600)
			F.centered(self,Vector2(center.x,102),text,16,F.SOFT)
		"ink_slot":
			var alpha := smoothstep(.40,.91,reveal)
			F.centered(self,Vector2(center.x,center.y+10+(1-alpha)*4),text,29,Color(F.INK,alpha),600)
			if hot and alpha>.8: F.ring(self,center,25,Color(F.INK,.65),.9)
		"slot":
			var fill := Color(.20,.31,.26,.63)
			if selected: fill=Color(.55,.66,.47,.63)
			if hot: fill=fill.lightened(.13)
			A.plate(self,Rect2(Vector2(2,2),Vector2(size.x-4,size.y-17)),fill,Color(A.PAPER,.40 if selected or hot else .16),8)
			if kind in ["potion","apple"]: F.item(self,kind,center-Vector2(0,10),19,tint)
			else: A.icon(self,kind,center-Vector2(0,10),18,tint)
			if pulse>0: A.plate(self,Rect2(Vector2(2,2),size-Vector2(4,17)),Color(A.PAPER,pulse*.2),Color.TRANSPARENT,8)
			A.centered(self,Vector2(center.x,size.y-2),caption,10,A.PAPER,600)
			if quantity!="": A.text(self,Vector2(size.x-17,15),quantity,10,A.PAPER,700)
		"utility":
			draw_circle(center,20,Color(.11,.23,.18,.77 if hot else .63))
			draw_arc(center,20,0,TAU,48,Color(A.PAPER,.6 if hot else .25),1,true)
			A.icon(self,kind,center,12,A.PAPER)
		"close":
			var hide_color := Color("844838").lightened(.10 if hot else 0)
			LEATHER.draw(self,Rect2(1,1,size.x-2,size.y-1),hide_color,4,true)
			# A narrow pull-tab: its root is tucked under the first sheet.
			var at := Vector2(center.x,18)
			F.stroke(self,at,9,[Vector2(-.5,-.5),Vector2(.53,.46)],Color("ead0aa"),1.5)
			F.stroke(self,at,9,[Vector2(.49,-.49),Vector2(-.5,.5)],Color("ead0aa"),1.5)
