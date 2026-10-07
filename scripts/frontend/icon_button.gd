extends Button
const A=preload("res://scripts/frontend/ui_art.gd")
var kind := "bag"
var caption := ""
var tint := A.PAPER
var filled := false
var pulse := 0.0
func _ready() -> void:
	mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	A.invisible_button(self)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	pressed.connect(_pulse)
func _pulse() -> void: pulse=1.0
func _process(delta: float) -> void:
	if pulse>0:
		pulse=maxf(0,pulse-delta*3)
		queue_redraw()
func _draw() -> void:
	var hot := is_hovered() or has_focus()
	var center := size*.5-Vector2(0,4 if caption!="" else 0)
	var r := minf(size.x,size.y)*.40
	if filled or hot or pulse>0:
		A.plate(self,Rect2(Vector2(2,2),size-Vector2(4,4)),Color(.09,.20,.17,.62 if not hot else .88),Color(A.GOLD,.60 if hot else .25),8)
	if pulse>0: draw_circle(center,r+4,Color(A.GOLD,pulse*.16))
	A.icon(self,kind,center,r*.62,tint if not hot else A.GOLD)
	if caption!="": A.centered(self,Vector2(size.x*.5,size.y-4),caption,10,A.PAPER,700)
