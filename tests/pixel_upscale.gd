extends SceneTree
## Real shader sampling: integer crispness and bounded fractional edge filtering.
var rect: TextureRect
var checks := 0
var failed := 0

func _initialize() -> void: call_deferred("run")
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failed+=1
	print("PASS " if ok else "FAIL ",label)
func grab() -> Image:
	for i in range(3): await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()
func intermediate(image: Image,size: int) -> int:
	var total := 0
	for y in range(size):
		for x in range(size):
			var c := image.get_pixel(x,y)
			if c.r>.02 and c.r<.98: total+=1
	return total

func run() -> void:
	if DisplayServer.get_name()=="headless":
		quit(1)
		return
	root.size=Vector2i(128,128)
	root.content_scale_size=Vector2i.ZERO
	root.content_scale_mode=Window.CONTENT_SCALE_MODE_DISABLED
	var pattern := Image.create(16,16,false,Image.FORMAT_RGBA8)
	for y in range(16):
		for x in range(16): pattern.set_pixel(x,y,Color.WHITE if (x+y)%2==0 else Color.BLACK)
	rect=TextureRect.new()
	rect.texture=ImageTexture.create_from_image(pattern)
	rect.texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR
	rect.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	rect.size=Vector2.ONE*96
	var mat := ShaderMaterial.new()
	mat.shader=preload("res://shaders/upscale.gdshader")
	rect.material=mat
	root.add_child(rect)
	var integer := await grab()
	print("PIXEL_SAMPLE ",integer.get_size()," ",integer.get_pixel(3,3)," ",integer.get_pixel(11,3))
	check(intermediate(integer,96)==0,"integer upscaling preserves exact black / white source texels")
	check(integer.get_pixel(3,3).r>.98 and integer.get_pixel(11,3).r<.02,"padded sampling preserves the intended cropped content")
	rect.size=Vector2.ONE*91
	var fractional := await grab()
	var edges := intermediate(fractional,91)
	check(edges>100 and edges<91*91*.45,"noninteger scaling filters a narrow set of edge pixels: %d"%edges)
	rect.size=Vector2.ONE*96
	mat.set_shader_parameter("snap_offset",Vector2(.17,0))
	var shifted := await grab()
	check(intermediate(shifted,96)>100 and intermediate(shifted,96)<96*96*.28,"fractional camera compensation retains solid pixel centers")
	print("PIXEL_UPSCALE_RESULT ",checks-failed,"/",checks)
	quit(1 if failed else 0)
