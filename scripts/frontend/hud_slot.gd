extends Button
## Compact combat-only slot. Book controls keep their own illustrated presenter.
const A=preload("res://scripts/frontend/ui_art.gd")
const F=preload("res://scripts/frontend/field_guide_art.gd")
const CONTENT_ART=preload("res://scripts/frontend/content_art.gd")
var content_icon: Texture2D
var kind := ""
var caption := ""
var quantity := ""
var cooldown := 0.0
var pulse := 0.0
var tint := A.PAPER
var role := "hud_slot"
var aiming := false
var _draw_state: Array = []

func _ready() -> void:
	A.invisible_button(self)
	focus_mode=Control.FOCUS_NONE
	mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	mouse_force_pass_scroll_events=false
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)

func _process(delta: float) -> void:
	var state: Array = [content_icon, kind, caption, quantity, ceili(cooldown), tint, aiming, disabled]
	if state != _draw_state:
		_draw_state = state
		queue_redraw()
	if pulse>0:
		pulse=maxf(0,pulse-delta*3.8)
		queue_redraw()

func _draw() -> void:
	var hot := is_hovered() and not disabled
	var outline := Color(A.PAPER,.68 if hot else .34)
	var plate := Color(.09,.17,.14,.77 if hot else .59)
	var corners:=PackedVector2Array([Vector2(5,1),Vector2(size.x-1,1),Vector2(size.x-1,size.y-6),Vector2(size.x-6,size.y-1),Vector2(1,size.y-1),Vector2(1,6)])
	draw_colored_polygon(corners,plate)
	corners.append(corners[0])
	draw_polyline(corners,outline,1,true)
	if aiming: draw_polyline(corners,Color(.2,.62,1,.85),1.5,true)
	if pulse>0: draw_colored_polygon(corners,Color(A.MINT,pulse*.20))
	var color := Color(tint,.44 if disabled else 1.0)
	if CONTENT_ART.draw(self,content_icon,Vector2(size.x*.5,21),16,color.a): pass
	elif kind in ["potion","apple","crystal","fist"]: F.item(self,kind,Vector2(size.x*.5,21),13,color)
	elif not kind.is_empty(): A.icon(self,kind,Vector2(size.x*.5,21),12,color)
	A.centered(self,Vector2(size.x*.5,size.y-5),caption,10,Color(A.PAPER,.6 if disabled else .95),600)
	if not quantity.is_empty():
		var width: float=A.font(600).get_string_size(quantity,HORIZONTAL_ALIGNMENT_LEFT,-1,10).x
		A.text(self,Vector2(size.x-width-4,12),quantity,10,A.PAPER,600)
	if cooldown>0:
		draw_circle(Vector2(size.x*.5,21),14,Color(.04,.09,.08,.8))
		A.centered(self,Vector2(size.x*.5,26),str(ceili(cooldown)),15,A.PAPER,700)
