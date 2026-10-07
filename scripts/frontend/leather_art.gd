@static_unload
extends RefCounted
## Reusable tanned-hide material in page coordinates, not screen-space noise.
static var grain: Texture2D

static func texture() -> Texture2D:
	if grain: return grain
	var noise := FastNoiseLite.new()
	noise.seed=40927
	noise.frequency=.14
	noise.noise_type=FastNoiseLite.TYPE_CELLULAR
	noise.cellular_return_type=FastNoiseLite.RETURN_DISTANCE2_SUB
	var broad := FastNoiseLite.new()
	broad.seed=728
	broad.frequency=.028
	var image := Image.create(256,256,false,Image.FORMAT_RGB8)
	for y in range(256):
		for x in range(256):
			var pore: float=noise.get_noise_2d(x,y)
			var value: float=clampf(.86+pore*.14+broad.get_noise_2d(x,y)*.12,0,1)
			image.set_pixel(x,y,Color(value,value,value))
	image.generate_mipmaps()
	grain=ImageTexture.create_from_image(image)
	return grain

static func draw(c: CanvasItem,rect: Rect2,color: Color,radius := 9.0,stitch := true) -> void:
	var polygon := PackedVector2Array()
	for corner in range(4):
		var center: Vector2=rect.position+[Vector2(rect.size.x-radius,radius),Vector2(rect.size.x-radius,rect.size.y-radius),Vector2(radius,rect.size.y-radius),Vector2(radius,radius)][corner]
		for j in range(7): polygon.append(center+Vector2.from_angle(-PI*.5+corner*PI*.5+j*PI/12)*radius)
	var uv := PackedVector2Array()
	for point in polygon: uv.append((point-rect.position)/128.0)
	c.texture_repeat=CanvasItem.TEXTURE_REPEAT_ENABLED
	c.draw_polygon(polygon,PackedColorArray([color]),uv,texture())
	polygon.append(polygon[0])
	c.draw_polyline(polygon,color.darkened(.48),2.4,true)
	var inner := rect.grow(-4)
	c.draw_line(inner.position+Vector2(4,0),inner.position+Vector2(inner.size.x-4,0),color.lightened(.28),1.2,true)
	if stitch:
		var seam := rect.grow(-8)
		for x in range(6,int(seam.size.x)-5,10):
			for y in [seam.position.y,seam.end.y]:
				c.draw_line(Vector2(seam.position.x+x,y+1),Vector2(seam.position.x+x+4,y),Color("c4a67a",.57),.9,true)
		for y in range(6,int(seam.size.y)-5,10):
			for x in [seam.position.x,seam.end.x]:
				c.draw_line(Vector2(x,seam.position.y+y),Vector2(x+.5,seam.position.y+y+4),Color("c4a67a",.57),.9,true)
	# Small abrasion marks stay on the edge where hands actually touch it.
	for i in range(9):
		var at := rect.position+Vector2(4+fmod(i*67.31,maxf(1,rect.size.x-10)),rect.size.y-4-fmod(i*1.3,3))
		c.draw_line(at,at+Vector2(3+i%4,-.6),Color("c5a37b",.23),.8,true)
