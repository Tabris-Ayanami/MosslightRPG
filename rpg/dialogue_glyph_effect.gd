extends RichTextEffect
var bbcode := "spoken"
var reveal: RefCounted
func _process_custom_fx(glyph: CharFXTransform) -> bool:
	if reveal==null: return true
	var index:=glyph.relative_index
	if index>=reveal.arrivals.size():
		glyph.visible=false
		return true
	var phase:=smoothstep(0,.075,reveal.elapsed-float(reveal.arrivals[index]))
	glyph.color.a*=phase
	glyph.offset.y+=roundf((1-phase)*2)
	return true
