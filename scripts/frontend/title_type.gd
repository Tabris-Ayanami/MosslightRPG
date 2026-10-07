extends Control
## The blade lettering and radial menu share the meadow's real shadows.
const A=preload("res://scripts/frontend/ui_art.gd")
const SERIF=preload("res://assets/ui/fonts/NotoSerifSC.ttf")
const OPTIONS=["开始游戏","新冒险","设置","退出"]
const CENTRE=Vector2(1070,40)
const ANGLES=[2.81,2.66,2.54,2.44]
const RADIUS=920.0
var selected := 0
var slide := [0.0,0.0,0.0,0.0]
var title_font: FontVariation
var ground_options: Control

class GroundOptions extends Control:
	var source: Control
	func _draw() -> void:
		for i in range(4):
			draw_set_transform(source.option_position(i),source.option_rotation(i))
			A.text(self,Vector2(source.slide[i],0),OPTIONS[i],64 if i<2 else 45,A.PAPER,900)
			A.text(self,Vector2(-30,-7),"0%d"%(i+1),11,A.PAPER,600)
			if source.selected==i:
				var length := A.font(900).get_string_size(OPTIONS[i],HORIZONTAL_ALIGNMENT_LEFT,-1,64 if i<2 else 45).x
				draw_line(Vector2(source.slide[i],12),Vector2(length+source.slide[i],12),Color(A.PAPER,.7),1.1,true)
				A.diamond(self,Vector2(-17,-24),4,A.PAPER)
		draw_set_transform(Vector2.ZERO)
static func option_position(index: int) -> Vector2:
	return CENTRE+Vector2.from_angle(ANGLES[index])*RADIUS
static func option_rotation(index: int) -> float:
	return ANGLES[index]-PI
func _ready() -> void:
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	title_font=FontVariation.new()
	title_font.base_font=SERIF
	title_font.variation_opentype={TextServerManager.get_primary_interface().name_to_tag("wght"):900}
	title_font.variation_embolden=.3
	ground_options=GroundOptions.new()
	ground_options.name="MeadowLettering"
	ground_options.source=self
	ground_options.mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(ground_options)
func _process(delta: float) -> void:
	for i in range(4): slide[i]=lerpf(slide[i],12.0 if i==selected else 0.0,1-exp(-delta*10))
	queue_redraw()
	ground_options.queue_redraw()
func _draw() -> void:
	draw_set_transform_matrix(Transform2D(Vector2(1,0),Vector2(-.20,.94),Vector2(68,169)))
	draw_string(title_font,Vector2.ZERO,"刀剑神域",HORIZONTAL_ALIGNMENT_LEFT,-1,111,A.PAPER)
	draw_colored_polygon(PackedVector2Array([Vector2(3,12),Vector2(398,12),Vector2(470,3),Vector2(414,17),Vector2(-13,17)]),A.PAPER)
	draw_line(Vector2(4,23),Vector2(402,23),A.PAPER,1.1,true)
	draw_set_transform(Vector2.ZERO)
