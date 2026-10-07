@static_unload
extends RefCounted
## Fibrous vellum and rolled edges, shared by every animation frame.
const F=preload("res://scripts/frontend/field_guide_art.gd")
static var grain: Texture2D

static func texture() -> Texture2D:
	if grain: return grain
	var fine := FastNoiseLite.new()
	fine.seed=3017
	fine.frequency=.72
	var broad := FastNoiseLite.new()
	broad.seed=5481
	broad.frequency=.026
	var image := Image.create(256,256,false,Image.FORMAT_RGB8)
	for y in range(256):
		for x in range(256):
			var v := .92+fine.get_noise_2d(x,y)*.055+broad.get_noise_2d(x,y)*.065
			var fibre := fine.get_noise_2d(x*.18,y*1.8)*.018
			image.set_pixel(x,y,Color(v+fibre,v+fibre,v+fibre))
	image.generate_mipmaps()
	grain=ImageTexture.create_from_image(image)
	return grain

static func edge_y(x: float) -> float:
	return sin(x*.093)*1.0+sin(x*.026+2)*2.2+sin(x*.31)*.55

static func paper(c: CanvasItem,rect: Rect2) -> void:
	var outline := PackedVector2Array()
	var steps := maxi(6,ceili(rect.size.x/7))
	for i in range(steps+1):
		var x := rect.position.x+rect.size.x*i/steps
		outline.append(Vector2(x,rect.position.y+edge_y(x)))
	for i in range(steps,-1,-1):
		var x := rect.position.x+rect.size.x*i/steps
		outline.append(Vector2(x,rect.end.y+edge_y(x+87)*1.25))
	for layer in range(5,0,-1):
		var shadow := PackedVector2Array()
		for point in outline: shadow.append(point+Vector2(layer*.8,6+layer*1.8))
		c.draw_colored_polygon(shadow,Color(.08,.06,.025,.045))
	var uv := PackedVector2Array()
	for point in outline: uv.append(point/256.0)
	c.texture_repeat=CanvasItem.TEXTURE_REPEAT_ENABLED
	c.draw_polygon(outline,PackedColorArray([Color("eee0bb")]),uv,texture())
	outline.append(outline[0])
	c.draw_polyline(outline,Color("8c6c41",.6),1.4,true)
	for y in [rect.position.y,rect.end.y]:
		for i in range(3):
			var path := PackedVector2Array()
			for k in range(steps+1):
				var x := rect.position.x+rect.size.x*k/steps
				path.append(Vector2(x,y+edge_y(x)+(i+1)*1.5*(1 if y==rect.position.y else -1)))
			c.draw_polyline(path,Color("9b7849",.10-i*.02),2.5,true)

static func roller(c: CanvasItem,x: float,top: float,height: float,left: bool,openness: float) -> void:
	var width := lerpf(33,22,openness)
	var direction := 1.0 if left else -1.0
	var center := x-direction*width*.19
	c.draw_rect(Rect2(center-width*.62,top-3,width*1.24,height+6),Color("745737",.38))
	for i in range(32):
		var u := (i+.5)/32.0
		var lighting := .64+.39*pow(maxf(0,sin(u*PI)),.6)-.12*u
		var shade := Color("dfcda6")*Color(lighting,lighting,lighting,1)
		var rect := Rect2(center-width*.5+u*width,top,width/32.0+.8,height)
		c.draw_texture_rect_region(texture(),rect,Rect2(rect.position,rect.size),shade)
	for y in [top,top+height]:
		F.oval(c,Vector2(center,y),Vector2(width*.52,6),Color("c3aa7b"),Color("856640"),.9)
		var spiral := PackedVector2Array()
		for j in range(80):
			var a := j*.15
			var r := lerpf(width*.46,1.0,j/79.0)
			spiral.append(Vector2(center+cos(a)*r,y+sin(a)*r*.24))
		c.draw_polyline(spiral,Color("79603c",.72),.85,true)
	var seam_x := center+direction*width*.48
	c.draw_line(Vector2(seam_x,top+5),Vector2(seam_x,top+height-5),Color("f8ebca",.73),1.2,true)
