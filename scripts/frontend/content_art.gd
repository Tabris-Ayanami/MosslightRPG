extends RefCounted
## Fit a validated content image in the same space as an illustrated fallback.
static func draw(canvas: CanvasItem, texture: Texture2D, center: Vector2, radius: float, alpha := 1.0) -> bool:
	if texture == null or texture.get_width() <= 0 or texture.get_height() <= 0:
		return false
	var extent := texture.get_size()
	extent *= radius * 2.0 / maxf(extent.x, extent.y)
	canvas.draw_texture_rect(texture, Rect2(center - extent * 0.5, extent), false, Color(1, 1, 1, alpha))
	return true
