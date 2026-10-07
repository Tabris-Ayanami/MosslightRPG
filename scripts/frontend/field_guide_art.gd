@static_unload
extends RefCounted
## Small, resolution-independent illustrations for the traveller's field guide.
const A=preload("res://scripts/frontend/ui_art.gd")
const PENCIL=preload("res://scripts/frontend/pencil_items.gd")
const INK=Color("494236")
const SOFT=Color("897b63")
const SAGE=Color("737c61")
const PAPER=Color("ebdec4")
const LINE=Color("bdb091")
const FONT=preload("res://assets/ui/fonts/LongCang-Regular.ttf")
static var fonts: Dictionary={}

static func font(weight := 500) -> Font:
	if not fonts.has(weight):
		var face := FontVariation.new()
		face.base_font=FONT
		face.variation_embolden=.08 if weight>=600 else 0.0
		fonts[weight]=face
	return fonts[weight]

static func text(c: CanvasItem,p: Vector2,value: String,size := 16,color := INK,weight := 500) -> void:
	c.draw_string(font(weight),p,value,HORIZONTAL_ALIGNMENT_LEFT,-1,size,color)

static func centered(c: CanvasItem,p: Vector2,value: String,size := 16,color := INK,weight := 500) -> void:
	var width := font(weight).get_string_size(value,HORIZONTAL_ALIGNMENT_LEFT,-1,size).x
	text(c,p-Vector2(width*.5,0),value,size,color,weight)

static func ring(c: CanvasItem,p: Vector2,r: float,color := INK,width := 1.1) -> void:
	for pass_index in range(2):
		var path := PackedVector2Array()
		for i in range(73):
			var a := i*TAU/72
			var radius := r+sin(a*5+p.x*.014)*.65+sin(a*9+p.y*.01)*.35+pass_index*1.6
			path.append(p+Vector2.from_angle(a)*radius)
		c.draw_polyline(path,Color(color,color.a*(1.0 if pass_index==0 else .27)),width,true)

static func wash(c: CanvasItem,p: Vector2,r: Vector2,color := SAGE) -> void:
	for layer in range(3):
		var path := PackedVector2Array()
		for i in range(50):
			var a := TAU*i/50
			var rough := 1.0+sin(a*7+p.x*.01)*.035+sin(a*13+p.y*.01)*.021
			path.append(p+Vector2.from_angle(a)*r*rough*(1.0-layer*.07))
		c.draw_colored_polygon(path,Color(color,color.a*.13))

static func border(c: CanvasItem,rect: Rect2,color := LINE) -> void:
	pen(c,rect.position,rect.position+Vector2(rect.size.x,0),color)
	pen(c,rect.position+Vector2(rect.size.x,0),rect.end,color)
	pen(c,rect.end,rect.position+Vector2(0,rect.size.y),color)
	pen(c,rect.position+Vector2(0,rect.size.y),rect.position,color)

static func hatch(c: CanvasItem,rect: Rect2,color: Color,step := 6.0) -> void:
	var x := rect.position.x
	while x<rect.end.x:
		c.draw_line(Vector2(x,rect.end.y),Vector2(minf(x+rect.size.y*.6,rect.end.x),rect.position.y),color,.7,true)
		x+=step

static func points(p: Vector2, r: float, vertices: Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for vertex: Vector2 in vertices: result.append(p+vertex*r)
	return result

static func shape(c: CanvasItem,p: Vector2,r: float,vertices: Array,fill: Color,outline := INK,width := 1.5) -> void:
	var poly := points(p,r,vertices)
	var pigment := fill.lerp(PAPER,.24) if r>3.0 else fill
	pigment.a=fill.a
	c.draw_colored_polygon(poly,pigment)
	if r>12.0 and outline.a>0 and fill.a>0:
		for row in range(10):
			for col in range(8):
				var a := p+Vector2(-.85+col*.24,-.90+row*.21)*r
				var b := a+Vector2(.10,-.13)*r
				if Geometry2D.is_point_in_polygon(a,poly) and Geometry2D.is_point_in_polygon(b,poly): c.draw_line(a,b,Color(outline,.12),.6,true)
	poly.append(poly[0])
	c.draw_polyline(poly,outline,width,true)
	if r>8.0 and outline.a>0:
		for i in range(poly.size()-1): pen(c,poly[i]+Vector2(.6,-.5),poly[i+1]+Vector2(.4,.4),Color(outline,.22),.65)

static func stroke(c: CanvasItem,p: Vector2,r: float,vertices: Array,color := INK,width := 1.5) -> void:
	c.draw_polyline(points(p,r,vertices),color,width,true)

static func oval(c: CanvasItem,p: Vector2,radius: Vector2,fill: Color,outline := INK,width := 1.4) -> void:
	var poly := PackedVector2Array()
	for i in range(36):
		var a := TAU*i/36.0
		poly.append(p+Vector2(cos(a),sin(a))*radius)
	c.draw_colored_polygon(poly,fill)
	if outline.a>0:
		poly.append(poly[0])
		c.draw_polyline(poly,outline,width,true)

static func pen(c: CanvasItem,from: Vector2,to: Vector2,color := LINE,width := 1.0) -> void:
	var path := PackedVector2Array()
	var normal := (to-from).normalized().orthogonal()
	for i in range(13):
		var t := float(i)/12
		path.append(from.lerp(to,t)+normal*sin(t*19+from.x*.01)*.52)
	c.draw_polyline(path,color,width,true)

static func sprig(c: CanvasItem,p: Vector2,r: float,color := SAGE) -> void:
	stroke(c,p,r,[Vector2(-.25,.8),Vector2(-.10,.25),Vector2(.11,-.25),Vector2(.30,-.8)],color,1.2)
	for i in range(5):
		var y := .52-i*.27
		var x := -.20+i*.09
		var side := 1.0 if i%2==0 else -1.0
		shape(c,p,r,[Vector2(x,y),Vector2(x+side*.27,y-.02),Vector2(x+side*.35,y-.30),Vector2(x+side*.09,y-.18)],Color(color,.48),color,1)

static func item(c: CanvasItem,kind: String,p: Vector2,r: float,tint := SAGE) -> void:
	if PENCIL.draw(c,kind,p,r,tint): return
	var edge := Color("4a5142")
	var brown := Color("96744f")
	var pale := Color("faf3dd")
	match kind:
		"coin":
			for i in range(3):
				var at := p + Vector2((i-1)*.24, .26-i*.22)*r
				c.draw_circle(at,r*.55,Color("bd884e"))
				c.draw_arc(at,r*.53,0,TAU,24,edge,1.2,true)
				c.draw_arc(at,r*.43,0,TAU,24,Color("f3d69b"),1.2,true)
				c.draw_rect(Rect2(at-Vector2.ONE*r*.12,Vector2.ONE*r*.24),edge)
		"fist":
			shape(c,p,r,[Vector2(-.7,-.25),Vector2(-.48,-.61),Vector2(.48,-.61),Vector2(.7,-.30),Vector2(.58,.46),Vector2(-.31,.58),Vector2(-.7,.12)],pale,edge)
			for x in [-.25,.05,.35]: stroke(c,p,r,[Vector2(x,-.48),Vector2(x,-.03)],edge,1.1)
			stroke(c,p,r,[Vector2(-.57,.02),Vector2(-.12,.19)],edge,1.2)
		"apple":
			shape(c,p,r,[Vector2(0,-.37),Vector2(-.31,-.5),Vector2(-.63,-.36),Vector2(-.73,-.04),Vector2(-.65,.39),Vector2(-.39,.72),Vector2(-.08,.77),Vector2(.13,.70),Vector2(.41,.73),Vector2(.68,.38),Vector2(.73,.0),Vector2(.58,-.36),Vector2(.28,-.48)],Color("d97b64"),edge)
			shape(c,p,r,[Vector2(.11,-.51),Vector2(.35,-.83),Vector2(.77,-.84),Vector2(.50,-.51)],Color("8da576"),edge,1.2)
			stroke(c,p,r,[Vector2(0,-.32),Vector2(.09,-.72),Vector2(.03,-.91)],brown,2.3)
			stroke(c,p,r,[Vector2(-.46,-.19),Vector2(-.51,.02),Vector2(-.43,.20)],Color("f8c4a0"),r*.12)
			stroke(c,p,r,[Vector2(.46,.02),Vector2(.39,.4),Vector2(.24,.55)],Color("b85b4f"),r*.12)
		"pear":
			shape(c,p,r,[Vector2(-.13,-.66),Vector2(-.32,-.32),Vector2(-.38,-.02),Vector2(-.65,.28),Vector2(-.67,.55),Vector2(-.45,.78),Vector2(0,.86),Vector2(.42,.76),Vector2(.61,.49),Vector2(.48,.16),Vector2(.21,-.24),Vector2(.17,-.57)],Color("ddc677"),edge)
			stroke(c,p,r,[Vector2(0,-.60),Vector2(.08,-.93)],brown,2)
			shape(c,p,r,[Vector2(.07,-.78),Vector2(.36,-.95),Vector2(.66,-.75),Vector2(.32,-.65)],Color("809b6a"),edge,1)
			stroke(c,p,r,[Vector2(-.33,.1),Vector2(-.42,.35),Vector2(-.35,.5)],pale,r*.10)
		"potion":
			shape(c,p,r,[Vector2(-.23,-.76),Vector2(.24,-.76),Vector2(.24,-.35),Vector2(.51,-.13),Vector2(.58,.22),Vector2(.48,.68),Vector2(.21,.79),Vector2(-.27,.77),Vector2(-.52,.58),Vector2(-.56,.1),Vector2(-.24,-.34)],Color("d8e6de"),edge)
			shape(c,p,r,[Vector2(-.44,.04),Vector2(.44,.06),Vector2(.42,.56),Vector2(.19,.67),Vector2(-.22,.64),Vector2(-.4,.49)],Color("78acba"),Color("78acba"),1)
			shape(c,p,r,[Vector2(-.27,-.92),Vector2(.29,-.90),Vector2(.25,-.62),Vector2(-.24,-.62)],brown,edge,1.2)
			stroke(c,p,r,[Vector2(-.30,-.13),Vector2(-.36,.08),Vector2(-.32,.43)],Color("fff9e9"),r*.11)
		"sword":
			shape(c,p,r,[Vector2(-.3,.28),Vector2(.53,-.81),Vector2(.77,-.98),Vector2(.83,-.62),Vector2(-.08,.45)],Color("ced9d1"),edge)
			stroke(c,p,r,[Vector2(-.14,.31),Vector2(.66,-.68)],Color("fcf9eb"),1.4)
			stroke(c,p,r,[Vector2(-.44,.53),Vector2(-.70,.84)],brown,r*.19)
			stroke(c,p,r,[Vector2(-.64,.15),Vector2(-.10,.69)],edge,r*.16)
			stroke(c,p,r,[Vector2(-.61,.12),Vector2(-.06,.65)],Color("c8ae74"),r*.11)
			oval(c,p+Vector2(-.72,.86)*r,Vector2.ONE*r*.1,Color("c8ae74"),edge,1)
		"bow":
			stroke(c,p,r,[Vector2(-.39,-.87),Vector2(.16,-.67),Vector2(.47,-.17),Vector2(.43,.34),Vector2(.08,.76),Vector2(-.37,.89)],edge,r*.17)
			stroke(c,p,r,[Vector2(-.39,-.87),Vector2(.16,-.67),Vector2(.47,-.17),Vector2(.43,.34),Vector2(.08,.76),Vector2(-.37,.89)],Color("bb9362"),r*.10)
			stroke(c,p,r,[Vector2(-.39,-.87),Vector2(-.37,.89)],Color("b2ad92"),1)
			stroke(c,p,r,[Vector2(-.85,.28),Vector2(.86,-.3)],brown,1.5)
			shape(c,p,r,[Vector2(.55,-.37),Vector2(.92,-.33),Vector2(.72,-.08)],Color("c4d3c7"),edge,1)
		"leaf","herb":
			sprig(c,p,r*.95,Color("648667"))
			stroke(c,p,r,[Vector2(-.3,.83),Vector2(.42,.16),Vector2(.64,-.53)],Color("648667"),1.5)
			shape(c,p,r,[Vector2(.37,.27),Vector2(.26,-.13),Vector2(.46,-.51),Vector2(.58,-.09)],Color("9db67b"),edge,1)
			stroke(c,p,r,[Vector2(-.35,.67),Vector2(.07,.80)],Color("bc9c6b"),2)
		"flower":
			for i in range(3):
				var head := p+Vector2((i-1)*.42,-.46+absf(i-1)*.28)*r
				c.draw_line(p+Vector2(-.14,.80)*r,head,Color("749267"),1.5,true)
				for j in range(5): oval(c,head+Vector2.from_angle(j*TAU/5)*r*.16,Vector2.ONE*r*.13,Color("faf1d9"),Color("b3aa8b"),.8)
				c.draw_circle(head,r*.10,Color("d5b96c"))
			shape(c,p,r,[Vector2(-.11,.49),Vector2(.19,.17),Vector2(.50,.18),Vector2(.24,.49)],Color("92aa79"),edge,1)
		"crystal":
			shape(c,p,r,[Vector2(-.48,.56),Vector2(-.64,.05),Vector2(-.21,-.71),Vector2(.40,-.92),Vector2(.62,-.24),Vector2(.19,.79)],tint,edge)
			shape(c,p,r,[Vector2(-.21,-.71),Vector2(-.16,.04),Vector2(.19,.79),Vector2(.28,-.20),Vector2(.40,-.92)],tint.lightened(.30),Color.TRANSPARENT,0)
			stroke(c,p,r,[Vector2(-.48,.56),Vector2(-.16,.04),Vector2(.28,-.20),Vector2(.62,-.24)],tint.darkened(.23),1)
		"wood":
			shape(c,p,r,[Vector2(-.75,.2),Vector2(.33,-.72),Vector2(.70,-.55),Vector2(.78,-.11),Vector2(-.40,.79),Vector2(-.72,.64)],Color("b4936a"),edge)
			stroke(c,p,r,[Vector2(-.59,.35),Vector2(-.07,-.02),Vector2(.49,-.52)],brown,1.3)
			stroke(c,p,r,[Vector2(-.22,.41),Vector2(.28,.02),Vector2(.58,-.15)],brown,1.1)
			oval(c,p+Vector2(-.51,.49)*r,Vector2(.23,.29)*r,Color("d4bb8e"),edge,1.1)
			oval(c,p+Vector2(-.51,.49)*r,Vector2(.12,.17)*r,Color.TRANSPARENT,brown,1)
		"stone":
			shape(c,p,r,[Vector2(-.77,.26),Vector2(-.50,-.46),Vector2(.04,-.72),Vector2(.56,-.39),Vector2(.79,.27),Vector2(.24,.69),Vector2(-.34,.66)],Color("a8b0a0"),edge)
			shape(c,p,r,[Vector2(-.50,-.46),Vector2(.04,-.72),Vector2(.20,-.15),Vector2(-.25,.11)],Color("cbd1bd"),Color.TRANSPARENT,0)
			stroke(c,p,r,[Vector2(.20,-.15),Vector2(.46,.36),Vector2(.24,.69)],Color("828f83"),1.2)
		"mushroom":
			shape(c,p,r,[Vector2(-.22,.03),Vector2(.18,.03),Vector2(.30,.75),Vector2(-.16,.83),Vector2(-.31,.60)],Color("ead9b6"),edge)
			shape(c,p,r,[Vector2(-.80,.04),Vector2(-.66,-.43),Vector2(-.28,-.73),Vector2(.14,-.77),Vector2(.55,-.53),Vector2(.79,-.08),Vector2(.52,.16),Vector2(-.39,.18)],Color("bb8765"),edge)
			for v: Vector2 in [Vector2(-.37,-.34),Vector2(.03,-.56),Vector2(.38,-.26)]: oval(c,p+v*r,Vector2(.13,.09)*r,Color("f3ddb2"),Color.TRANSPARENT)
		"scroll":
			shape(c,p,r,[Vector2(-.47,-.75),Vector2(.53,-.54),Vector2(.34,.70),Vector2(-.67,.50)],Color("e6d5ae"),edge)
			oval(c,p+Vector2(0,-.66)*r,Vector2(.56,.14)*r,Color("f8e9c5"),edge,1)
			oval(c,p+Vector2(-.16,.60)*r,Vector2(.54,.13)*r,Color("ddc599"),edge,1)
			for i in range(3): stroke(c,p,r,[Vector2(-.3,-.26+i*.20),Vector2(.26,-.17+i*.20)],Color("a89570"),1)
		"shell":
			shape(c,p,r,[Vector2(-.78,.02),Vector2(-.67,-.41),Vector2(-.30,-.69),Vector2(.21,-.66),Vector2(.62,-.39),Vector2(.77,.09),Vector2(.18,.69),Vector2(-.25,.69)],Color("dfbaa3"),edge)
			for i in range(5): stroke(c,p,r,[Vector2(-.03,.56),Vector2((i-2)*.26,-.46)],Color("b99581"),1)
		"feather":
			shape(c,p,r,[Vector2(-.59,.70),Vector2(-.58,.12),Vector2(-.22,-.48),Vector2(.60,-.87),Vector2(.67,-.39),Vector2(.34,.18),Vector2(-.08,.54)],Color("9eb6bc"),edge)
			stroke(c,p,r,[Vector2(-.74,.88),Vector2(.37,-.54)],Color("edf0dc"),1.6)
			for i in range(3): stroke(c,p,r,[Vector2(-.40+i*.25,.50-i*.3),Vector2(-.10+i*.26,.47-i*.31)],Color("628890"),1)
		"coat":
			shape(c,p,r,[Vector2(-.23,-.75),Vector2(-.61,-.56),Vector2(-.83,.09),Vector2(-.55,.24),Vector2(-.43,-.11),Vector2(-.59,.78),Vector2(-.11,.85),Vector2(0,.58),Vector2(.17,.83),Vector2(.59,.70),Vector2(.39,-.1),Vector2(.56,.23),Vector2(.81,.11),Vector2(.53,-.58),Vector2(.23,-.77)],Color("526263"),edge)
			stroke(c,p,r,[Vector2(-.23,-.75),Vector2(0,-.32),Vector2(.23,-.77)],Color("b6b8a2"),1.5)
			stroke(c,p,r,[Vector2(0,-.32),Vector2(0,.53)],Color("a4aba0"),1)
		"boot":
			shape(c,p,r,[Vector2(-.41,-.83),Vector2(.24,-.80),Vector2(.16,.14),Vector2(.63,.38),Vector2(.74,.68),Vector2(.55,.80),Vector2(-.51,.78),Vector2(-.61,.60),Vector2(-.43,.12)],Color("987958"),edge)
			stroke(c,p,r,[Vector2(-.53,.61),Vector2(-.10,.64),Vector2(.66,.60)],Color("574f42"),r*.14)
			stroke(c,p,r,[Vector2(-.38,-.66),Vector2(.21,-.65)],Color("ceb28a"),r*.15)
			for i in range(3): stroke(c,p,r,[Vector2(-.22,-.38+i*.19),Vector2(.06,-.34+i*.19)],Color("d5c1a0"),1.3)
		"ring":
			oval(c,p+Vector2(-.06,.21)*r,Vector2(.48,.55)*r,Color("d9be7e"),edge)
			oval(c,p+Vector2(-.06,.21)*r,Vector2(.28,.36)*r,PAPER,edge,1)
			oval(c,p+Vector2(.02,-.41)*r,Vector2(.31,.36)*r,Color("739b88"),edge)
			stroke(c,p,r,[Vector2(-.10,-.53),Vector2(.05,-.63)],pale,1.8)
		"bag","satchel":
			oval(c,p+Vector2(0,-.46)*r,Vector2(.39,.36)*r,Color.TRANSPARENT,edge,2)
			A.plate(c,Rect2(p+Vector2(-.65,-.41)*r,Vector2(1.3,1.19)*r),Color("b99d72"),edge,roundi(r*.19))
			shape(c,p,r,[Vector2(-.65,-.4),Vector2(.65,-.4),Vector2(.57,.02),Vector2(0,.25),Vector2(-.59,.03)],Color("cfb88b"),edge,1.3)
			A.plate(c,Rect2(p+Vector2(-.12,-.10)*r,Vector2(.24,.44)*r),Color("886f4d"),edge,2)
		"person":
			c.draw_circle(p+Vector2(0,-.37)*r,r*.32,tint)
			oval(c,p+Vector2(0,.42)*r,Vector2(.58,.37)*r,tint,Color.TRANSPARENT)
		_: A.icon(c,kind,p,r,tint)

static func landscape(c: CanvasItem,p: Vector2,w: float) -> void:
	var col := Color(SOFT,.28)
	stroke(c,p,w,[Vector2(0,0),Vector2(.15,-.09),Vector2(.24,-.06),Vector2(.40,-.18),Vector2(.54,-.08),Vector2(.71,-.16),Vector2(.88,-.02),Vector2(1,0)],col,1)
	stroke(c,p,w,[Vector2(.64,-.01),Vector2(.64,-.22),Vector2(.68,-.28),Vector2(.72,-.22),Vector2(.72,-.01)],col,1)
	stroke(c,p,w,[Vector2(.77,0),Vector2(.77,-.13),Vector2(.89,-.13),Vector2(.89,0)],col,1)
	for i in range(4):
		var at := p+Vector2(w*(.04+i*.12),-5)
		sprig(c,at,13+i%2*7,col)
	pen(c,p+Vector2(-8,5),p+Vector2(w+8,5),col)

static func book_cover(c: CanvasItem,p: Vector2) -> void:
	var leather=preload("res://scripts/frontend/leather_art.gd")
	# Broad double spread, a rounded saddle spine and a visible 22 px page block.
	for i in range(5): A.plate(c,Rect2(p+Vector2(-22-i*2,12+i*4),Vector2(1164+i*4,589+i*2)),Color(.035,.06,.03,.06),Color.TRANSPARENT,22)
	leather.draw(c,Rect2(p+Vector2(-18,-12),Vector2(1156,612)),Color("6e4932"),17)
	leather.draw(c,Rect2(p+Vector2(530,-13),Vector2(61,615)),Color("61432e"),13,false)
	# A rounded block of many leaves, staggered towards the fore edge.
	for i in range(9,-1,-1):
		var depth := float(i)*2.2
		A.plate(c,Rect2(p+Vector2(-5,depth+5),Vector2(1130,553)),Color("c4b18d").lerp(Color("e6d7b4"),1.0-float(i)/12),Color("ae9c7c",.50),9)

static func book(c: CanvasItem,p: Vector2) -> void:
	var leather=preload("res://scripts/frontend/leather_art.gd")
	shape(c,p,1,[Vector2(10,3),Vector2(80,0),Vector2(472,2),Vector2(529,9),Vector2(560,20),Vector2(560,552),Vector2(520,543),Vector2(68,546),Vector2(9,548),Vector2(0,536),Vector2(0,16)],PAPER,Color("d3c6a9"),1.4)
	shape(c,p,1,[Vector2(560,20),Vector2(591,9),Vector2(650,2),Vector2(1046,0),Vector2(1109,4),Vector2(1120,16),Vector2(1120,534),Vector2(1109,548),Vector2(1048,546),Vector2(603,544),Vector2(560,552)],Color("ede1ca"),Color("c8b794"),1.4)
	for i in range(27):
		c.draw_rect(Rect2(p+Vector2(533+i,21),Vector2(1,523)),Color(.38,.27,.12,.16*float(i)/27))
		c.draw_rect(Rect2(p+Vector2(560+i,21),Vector2(1,523)),Color(.38,.27,.12,.14*(1-float(i)/27)))
	pen(c,p+Vector2(560,22),p+Vector2(560,550),Color("b09b7a"),1.1)
	for y in [123,266,408]:
		stroke(c,p+Vector2(560,y),1,[Vector2(-3,-8),Vector2(2,-2),Vector2(-1,8)],Color("a49575",.5),.8)
	for i in range(165):
		var at := p+Vector2(18+fmod(i*147.73,1083),18+fmod(i*63.29,514))
		c.draw_line(at,at+Vector2(2+i%3,.3),Color(.61,.50,.33,.065),.65,true)
	shape(c,p,1,[Vector2(16,4),Vector2(47,2),Vector2(13,36)],Color("e4d9bd"),Color("c6b999"),1)
	# Corner guards are cowhide, following the same folded edge as the cover.
	for side in [0,1]:
		var x := -13.0 if side==0 else 1082.0
		leather.draw(c,Rect2(p+Vector2(x,559),Vector2(50,32)),Color("79553b"),6)
	shape(c,p,1,[Vector2(110,570),Vector2(130,570),Vector2(131,610),Vector2(120,602),Vector2(109,611)],Color("73856d"),Color("455949"),1)
