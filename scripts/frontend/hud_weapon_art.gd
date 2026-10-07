extends RefCounted
const A=preload("res://scripts/frontend/ui_art.gd")

static func draw(c: CanvasItem,kind: String,rect: Rect2,active: float) -> void:
	var color:=Color(A.PAPER,lerpf(.62,1.0,active))
	var p:=rect.position+Vector2(8,rect.size.y*.5)
	var length: float=rect.size.x-17
	c.draw_line(rect.position+Vector2(4,rect.size.y-1),rect.end-Vector2(4,1),Color(A.PAPER,lerpf(.10,.45,active)),1,true)
	match kind:
		"fist":
			var center:=p+Vector2(length*.5,0)
			c.draw_colored_polygon(PackedVector2Array([center+Vector2(-13,-3),center+Vector2(-9,-7),center+Vector2(8,-7),center+Vector2(12,-3),center+Vector2(10,6),center+Vector2(-6,7),center+Vector2(-13,2)]),color)
			for offset in [-4,1,6]: c.draw_line(center+Vector2(offset,-5),center+Vector2(offset,0),Color(.2,.29,.24,.6),1,true)
			c.draw_line(center+Vector2(-10,1),center+Vector2(-2,3),Color(.2,.29,.24,.6),1,true)
		"sword", "greatsword", "dagger", "katana":
			if kind == "dagger":
				p.x += length * .22
				length *= .56
			c.draw_line(p,p+Vector2(13,0),color,3,true)
			c.draw_line(p+Vector2(13,-6),p+Vector2(13,6),color,2,true)
			var blade:=PackedVector2Array([p+Vector2(16,-3),p+Vector2(length-9,-3),p+Vector2(length,0),p+Vector2(length-9,3),p+Vector2(16,3)])
			c.draw_colored_polygon(blade,color)
			c.draw_line(p+Vector2(18,0),p+Vector2(length-10,0),Color(.19,.29,.24,.65),1,true)
			if kind == "greatsword": c.draw_line(p+Vector2(17,-4),p+Vector2(length-12,-4),color,2,true)
			if kind == "katana": c.draw_arc(p+Vector2(length*.5,-length*.68),length*.7,.92,2.19,24,color,1,true)
		"spear":
			c.draw_line(p,p+Vector2(length-24,0),color,2.5,true)
			c.draw_colored_polygon(PackedVector2Array([p+Vector2(length-30,0),p+Vector2(length-20,-5),p+Vector2(length,0),p+Vector2(length-20,5)]),color)
			c.draw_line(p+Vector2(length-30,-4),p+Vector2(length-30,4),color,2,true)
		"axe":
			c.draw_line(p,p+Vector2(length-14,0),color,3.5,true)
			var head:=p+Vector2(length-18,0)
			c.draw_colored_polygon(PackedVector2Array([head+Vector2(-10,-8),head+Vector2(9,-10),head+Vector2(15,-5),head+Vector2(15,5),head+Vector2(9,10),head+Vector2(-10,8),head+Vector2(-3,2),head+Vector2(-3,-2)]),color)
			c.draw_line(head+Vector2(10,-7),head+Vector2(12,7),Color(.19,.29,.24,.65),1,true)
		"orb":
			var center:=p+Vector2(length*.5,0)
			c.draw_circle(center,7,color)
			c.draw_arc(center,10,.3,5.5,24,color,1,true)
		"bow":
			var bow:=PackedVector2Array([p,p+Vector2(length*.24,-6),p+Vector2(length*.5,-8),p+Vector2(length*.76,-6),p+Vector2(length,0)])
			c.draw_polyline(bow,color,2,true)
			c.draw_line(p,p+Vector2(length,0),color,1,true)
			c.draw_line(p+Vector2(3,4),p+Vector2(length-3,4),color,1.4,true)
			c.draw_line(p+Vector2(length-8,1),p+Vector2(length-3,4),color,1.4,true)
		"crystal", "staff":
			c.draw_line(p,p+Vector2(length-12,0),color,3,true)
			A.diamond(c,p+Vector2(length-5,0),7,color)
		"shield":
			var center:=p+Vector2(length*.5,0)
			c.draw_colored_polygon(PackedVector2Array([center+Vector2(-15,-7),center+Vector2(15,-7),center+Vector2(12,3),center+Vector2(0,9),center+Vector2(-12,3)]),color)
			c.draw_line(center+Vector2(0,-5),center+Vector2(0,6),Color(.18,.27,.22,.75),1,true)
		_:
			c.draw_line(p+Vector2(length*.25,0),p+Vector2(length*.75,0),Color(color,.25),1,true)
