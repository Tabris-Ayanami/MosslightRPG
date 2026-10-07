extends Control
## Each glyph condenses locally, then drifts up and right on dismissal.
const A=preload("res://scripts/frontend/ui_art.gd")
const SHADER=preload("res://shaders/frontend/cloud_glyph.gdshader")
var letters: Array[Label]=[]
var homes: Array[Vector2]=[]
var age := 0.0
var departing := false
var departure_age := 0.0
var font_size := 40
var delay := 0.0
var backdrop := false
var puff: GradientTexture2D
func _ready() -> void:
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	var gradient := Gradient.new()
	gradient.set_color(0,Color(1,1,1,.24))
	gradient.set_color(1,Color(1,1,1,0))
	puff=GradientTexture2D.new()
	puff.gradient=gradient
	puff.width=64
	puff.height=64
	puff.fill=GradientTexture2D.FILL_RADIAL
	puff.fill_from=Vector2(.5,.5)
	puff.fill_to=Vector2(1,.5)
func configure(value: String, at: Vector2, point_size: int, wait: float=0) -> void:
	position=at
	font_size=point_size
	delay=wait
	var offset := 0.0
	for i in range(value.length()):
		var glyph := Label.new()
		glyph.text=value[i]
		glyph.mouse_filter=Control.MOUSE_FILTER_IGNORE
		glyph.add_theme_font_override("font",A.font(650))
		glyph.add_theme_font_size_override("font_size",point_size)
		glyph.add_theme_color_override("font_color",Color("fffdf4"))
		glyph.add_theme_color_override("font_outline_color",Color("183a35",.95))
		glyph.add_theme_constant_override("outline_size",2 if point_size>=20 else 1)
		glyph.add_theme_color_override("font_shadow_color",Color("102d2b",.65))
		glyph.add_theme_constant_override("shadow_offset_x",0)
		glyph.add_theme_constant_override("shadow_offset_y",2)
		glyph.add_theme_constant_override("shadow_outline_size",1)
		glyph.material=ShaderMaterial.new()
		glyph.material.shader=SHADER
		glyph.material.set_shader_parameter("seed",float(i)*7.71)
		add_child(glyph)
		letters.append(glyph)
		homes.append(Vector2(offset,0))
		offset+=A.font(650).get_string_size(value[i],HORIZONTAL_ALIGNMENT_LEFT,-1,point_size).x+point_size*.065
	size=Vector2(offset,point_size*1.5)
	position.x-=offset*.5
	_process(0)
func dissolve() -> void:
	departing=true
	departure_age=0
func _process(delta: float) -> void:
	age+=delta
	if departing: departure_age+=delta
	for i in range(letters.size()):
		var enter := smoothstep(0,1.05,age-delay-float(i)*.045)
		var leave := smoothstep(0,1.0,departure_age-float(i)*.023) if departing else 0.0
		var letter := letters[i]
		letter.position=homes[i]+Vector2(-14,10)*(1-enter)+Vector2(66,-43)*leave
		letter.scale=Vector2.ONE*(1.0+.13*(1-enter)+leave*.23)
		letter.modulate.a=enter*(1-leave)
		letter.material.set_shader_parameter("formation",enter*(1-leave))
		letter.material.set_shader_parameter("clock",age)
	queue_redraw()
func _draw() -> void:
	if not puff: return
	if backdrop:
		var opacity := smoothstep(0,1.05,age-delay)
		if departing: opacity*=1.0-smoothstep(0,1.0,departure_age)
		A.plate(self,Rect2(Vector2(-16,-3),size+Vector2(32,6)),Color("183a35",.82*opacity),Color.TRANSPARENT,6)
	for i in range(letters.size()):
		var phase := clampf((age-delay-i*.045)/1.3,0,1)
		var cloud_alpha := sin(phase*PI)*.7
		if departing: cloud_alpha=sin(clampf(departure_age-i*.023,0,1)*PI)*.65
		for j in range(3):
			var drift := departure_age if departing else phase
			var centre := homes[i]+Vector2(font_size*.5,font_size*.66)+Vector2(j*8-8,-j*6)+Vector2(38,-24)*drift
			var radius := font_size*(.40+float(j)*.10)
			draw_texture_rect(puff,Rect2(centre-Vector2.ONE*radius,Vector2.ONE*radius*2),false,Color(1,1,1,cloud_alpha))
