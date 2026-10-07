extends Button
## Lightweight sky card; the twenty slots stay readable without twenty cloud effects.
const A=preload("res://scripts/frontend/ui_art.gd")
var record: Dictionary={}
var selected := false
func _ready() -> void:
	A.invisible_button(self)
	mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
func _fit(value: String,pixels: int,width: float) -> String:
	var result := value
	while result.length()>1 and A.font(650).get_string_size(result,HORIZONTAL_ALIGNMENT_LEFT,-1,pixels).x>width:
		result=result.left(-2)+"…"
	return result
func _draw() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color=Color(.17,.29,.33,.27 if selected else .12)
	style.border_color=Color("fff9df",.8 if selected else .24)
	style.set_border_width_all(2 if selected else 1)
	style.set_corner_radius_all(9)
	draw_style_box(style,Rect2(Vector2.ZERO,size))
	var occupied: bool=record.get("occupied",false)
	var valid: bool=record.get("valid",false)
	A.text(self,Vector2(12,22),"%02d"%(int(record.get("slot",0))+1),12,Color("e9eedf",.6),600)
	var title: String=record.get("name","") if occupied else "未启程"
	if occupied and not valid: title="记录暂不可读"
	A.text(self,Vector2(40,24),_fit(title,19,size.x-54),19,Color("fff9e9",1.0 if occupied else .62),650)
	if occupied and valid:
		A.text(self,Vector2(13,44),_fit(str(record.get("location","风息原野")),12,size.x-80),12,Color("e8eee7"),600)
		A.text(self,Vector2(size.x-59,44),"Lv. %d"%int(record.get("level",0)),11,Color("e8eee7",.8),600)
		var stamp: String=str(record.get("display_time",record.get("saved_at_local",""))).replace("T"," ").left(16)
		A.text(self,Vector2(13,63),stamp,12,Color("e8eee7",.72),600)
	else:
		A.text(self,Vector2(14,52),"请保留文件，稍后重试" if occupied else "以新的名字开始旅途",12,Color("e8eee7",.55),600)
