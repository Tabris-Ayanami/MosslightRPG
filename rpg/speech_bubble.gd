extends Control
const Skins=preload("res://rpg/dialogue_skins.gd")
var skin_id := "villager_bubble"
var tail := Vector2.ZERO
var appearance := 1.0

func _ready() -> void:
	mouse_filter=MOUSE_FILTER_IGNORE
	texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST

func _outline(rect: Rect2) -> PackedVector2Array:
	var p:=rect.position
	var e:=rect.end
	return PackedVector2Array([p+Vector2(12,0),Vector2(e.x-12,p.y),Vector2(e.x-12,p.y+3),Vector2(e.x-5,p.y+3),Vector2(e.x-5,p.y+7),Vector2(e.x,p.y+7),Vector2(e.x,e.y-9),Vector2(e.x-4,e.y-9),Vector2(e.x-4,e.y-4),Vector2(e.x-12,e.y-4),Vector2(e.x-12,e.y),Vector2(p.x+12,e.y),Vector2(p.x+12,e.y-3),Vector2(p.x+5,e.y-3),Vector2(p.x+5,e.y-8),Vector2(p.x,e.y-8),p+Vector2(0,9),p+Vector2(4,9),p+Vector2(4,4),p+Vector2(12,4)])

func _draw() -> void:
	var skin:=Skins.resolve(skin_id)
	var fill:=Color(skin.fill)
	var edge:=Color(skin.edge)
	var accent:=Color(skin.accent)
	var bounds:=Rect2(Vector2.ZERO,size)
	draw_colored_polygon(_outline(Rect2(Vector2(0,3),size)),Color("283a2e",.19))
	var base:=Vector2(clampf(tail.x,18,size.x-18),size.y-3)
	var tip:=tail
	if tip.y<size.y: tip.y=size.y+14
	# The pointer terminates at the actor's projected head, including edge clamping.
	var pointer:=PackedVector2Array([base+Vector2(-9,0),tip,base+Vector2(7,0)])
	draw_colored_polygon(pointer,edge)
	draw_colored_polygon(_outline(bounds),edge)
	draw_colored_polygon(_outline(bounds.grow(-2)),fill)
	draw_colored_polygon(PackedVector2Array([base+Vector2(-6,-1),tip+Vector2(0,-3),base+Vector2(5,-1)]),fill)
	match str(skin.grain):
		"wood":
			for i in range(12):
				var y:=9+fposmod(i*23.71,size.y-18)
				var x:=12+fposmod(i*61.37,size.x-40)
				draw_line(Vector2(x,y),Vector2(minf(size.x-12,x+17+i%3*6),y),Color(accent,.10),1)
		"cloud":
			draw_line(Vector2(18,6),Vector2(size.x-18,6),Color.WHITE,.8)
		"mist":
			for i in range(6): draw_rect(Rect2(Vector2(15+i*9,6),Vector2(3,2)),Color(accent,.25))
		"royal":
			draw_line(Vector2(15,6),Vector2(size.x-15,6),Color(accent,.6),1)
			for i in [-1,0,1]: draw_rect(Rect2(size.x*.5+i*5-1,4-abs(i)*2,2,3),accent)
