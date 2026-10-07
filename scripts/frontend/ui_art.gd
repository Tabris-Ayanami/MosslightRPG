@static_unload
extends RefCounted
## Shared visual vocabulary. No player, inventory or quest data belongs here.
const FONT = preload("res://assets/ui/fonts/NotoSansSC.ttf")
const PAPER := Color("f3efd9")
const MUTED := Color("bcc8ad")
const INK := Color("193d36")
const GOLD := Color("dec785")
const MINT := Color("a3d7b1")
static var fonts: Dictionary = {}

static func invisible_button(button: Button) -> void:
	# Hotspots draw no plate in ANY native state, including during page dismissal.
	for part in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(part, StyleBoxEmpty.new())

static func font(weight: int = 500) -> Font:
	if not fonts.has(weight):
		var face := FontVariation.new()
		face.base_font = FONT
		face.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
		fonts[weight] = face
	return fonts[weight]

static func text(c: CanvasItem, p: Vector2, value: String, size: int = 16, color := PAPER, weight: int = 500) -> void:
	c.draw_string(font(weight), p, value, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)

static func centered(c: CanvasItem, p: Vector2, value: String, size: int = 16, color := PAPER, weight: int = 500) -> void:
	var width := font(weight).get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	text(c, p - Vector2(width * .5, 0), value, size, color, weight)

static func plate(c: CanvasItem, rect: Rect2, color: Color, border := Color.TRANSPARENT, radius: int = 8) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.border_color = border
	box.set_border_width_all(1 if border.a > 0 else 0)
	c.draw_style_box(box, rect)

static func diamond(c: CanvasItem, p: Vector2, r: float, color: Color, fill: bool = true) -> void:
	var points := PackedVector2Array([p + Vector2(0,-r),p + Vector2(r,0),p + Vector2(0,r),p + Vector2(-r,0)])
	if fill: c.draw_colored_polygon(points,color)
	else:
		points.append(points[0])
		c.draw_polyline(points,color,1.4,true)

static func icon(c: CanvasItem, kind: String, p: Vector2, r: float, color := PAPER) -> void:
	var width := maxf(1.4,r*.095)
	match kind:
		"coin":
			c.draw_circle(p,r*.74,Color("b87d46"))
			c.draw_arc(p,r*.66,0,TAU,24,Color("f2d191"),width,true)
			c.draw_rect(Rect2(p-Vector2.ONE*r*.18,Vector2.ONE*r*.36),INK)
		"sword":
			c.draw_colored_polygon(PackedVector2Array([p+Vector2(-.28,.20)*r,p+Vector2(.50,-.77)*r,p+Vector2(.79,-.89)*r,p+Vector2(.76,-.53)*r,p+Vector2(-.10,.37)*r]),color)
			c.draw_line(p+Vector2(-.48,.04)*r,p+Vector2(.13,.61)*r,color,width*1.6,true)
			c.draw_line(p+Vector2(-.18,.35)*r,p+Vector2(-.58,.78)*r,color,width*2,true)
		"bow":
			c.draw_arc(p+Vector2(-.26,0)*r,r*.83,-1.25,1.25,20,color,width,true)
			c.draw_line(p+Vector2(0,-.79)*r,p+Vector2(0,.79)*r,color,width*.65,true)
			c.draw_line(p+Vector2(-.6,.08)*r,p+Vector2(.9,-.15)*r,color,width,true)
			c.draw_line(p+Vector2(.6,-.33)*r,p+Vector2(.9,-.15)*r,color,width,true)
		"wind":
			for i in range(3):
				var y := (i-1)*r*.45
				c.draw_line(p+Vector2(-.8*r,y),p+Vector2(.25*r,y),color,width,true)
				c.draw_arc(p+Vector2(.25*r,y-r*.20),r*.20,-PI/2,PI/2,12,color,width,true)
		"dash":
			for i in range(2):
				var x := (i-.5)*r*.65
				c.draw_polyline(PackedVector2Array([p+Vector2(x-r*.30,-r*.65),p+Vector2(x+r*.30,0),p+Vector2(x-r*.30,r*.65)]),color,width*1.6,true)
		"leaf":
			c.draw_colored_polygon(PackedVector2Array([p+Vector2(-.65,.55)*r,p+Vector2(-.66,-.18)*r,p+Vector2(-.14,-.68)*r,p+Vector2(.77,-.82)*r,p+Vector2(.57,.24)*r,p+Vector2(.02,.57)*r]),color)
			c.draw_line(p+Vector2(-.8,.83)*r,p+Vector2(.4,-.43)*r,INK,width,true)
		"bag":
			plate(c,Rect2(p+Vector2(-.67,-.43)*r,Vector2(1.34,1.18)*r),Color.TRANSPARENT,color,roundi(r*.2))
			c.draw_arc(p+Vector2(0,-.41)*r,r*.38,PI,TAU,12,color,width,true)
			c.draw_line(p+Vector2(-.63,.02)*r,p+Vector2(.63,.02)*r,color,width,true)
			c.draw_line(p+Vector2(0,-.10)*r,p+Vector2(0,.23)*r,color,width*1.5,true)
		"journal":
			plate(c,Rect2(p+Vector2(-.66,-.8)*r,Vector2(1.32,1.6)*r),Color.TRANSPARENT,color,2)
			c.draw_line(p+Vector2(-.33,-.8)*r,p+Vector2(-.33,.8)*r,color,width,true)
			c.draw_line(p+Vector2(-.09,-.30)*r,p+Vector2(.39,-.30)*r,color,width,true)
			c.draw_line(p+Vector2(-.09,.02)*r,p+Vector2(.27,.02)*r,color,width,true)
		"map":
			c.draw_polyline(PackedVector2Array([p+Vector2(-.85,.7)*r,p+Vector2(-.85,-.55)*r,p+Vector2(-.25,-.78)*r,p+Vector2(.3,-.55)*r,p+Vector2(.83,-.8)*r,p+Vector2(.83,.48)*r,p+Vector2(.3,.74)*r,p+Vector2(-.25,.52)*r,p+Vector2(-.85,.7)*r]),color,width,true)
			for x in [-.25,.3]: c.draw_line(p+Vector2(x,-.56)*r,p+Vector2(x,.5)*r,color,width*.7,true)
		"sun":
			c.draw_circle(p,r*.32,color)
			for i in range(8):
				var v := Vector2.from_angle(i*TAU/8)
				c.draw_line(p+v*r*.53,p+v*r*.77,color,width,true)
		"moon":
			c.draw_arc(p,r*.68,.4,4.9,24,color,width*1.7,true)
			c.draw_arc(p+Vector2(.32,-.21)*r,r*.55,.9,4.35,20,color,width*1.2,true)
		"settings":
			for i in range(3):
				var x := (i-1)*r*.6
				var y := r*(-.28 if i==1 else .28)
				c.draw_line(p+Vector2(x,-.72*r),p+Vector2(x,.72*r),color,width,true)
				c.draw_circle(p+Vector2(x,y),r*.17,color)
		"potion":
			plate(c,Rect2(p+Vector2(-.24,-.85)*r,Vector2(.48,.48)*r),color,Color.TRANSPARENT,1)
			plate(c,Rect2(p+Vector2(-.54,-.43)*r,Vector2(1.08,1.19)*r),Color(color,.22),color,roundi(r*.3))
			c.draw_line(p+Vector2(-.37,.2)*r,p+Vector2(.37,.2)*r,color,width*2,true)
		"apple", "pear":
			c.draw_circle(p+Vector2(-.24,.13)*r,r*.47,color)
			c.draw_circle(p+Vector2(.24,.13)*r,r*.47,color)
			c.draw_line(p+Vector2(0,-.22)*r,p+Vector2(.12,-.70)*r,color,width,true)
			c.draw_line(p+Vector2(.12,-.52)*r,p+Vector2(.49,-.64)*r,color,width*2,true)
		"crystal":
			diamond(c,p,r*.85,color)
			c.draw_line(p+Vector2(0,-r*.72),p+Vector2(0,r*.72),INK,width,true)
		"close":
			c.draw_line(p+Vector2(-.5,-.5)*r,p+Vector2(.5,.5)*r,color,width,true)
			c.draw_line(p+Vector2(.5,-.5)*r,p+Vector2(-.5,.5)*r,color,width,true)
		_: diamond(c,p,r*.5,color,false)
