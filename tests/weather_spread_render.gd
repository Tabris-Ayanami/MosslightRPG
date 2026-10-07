extends SceneTree
## Actual shared shaders rendered on Vulkan, plus full-scene progression captures.
var game: Node
var w: Node
var probe: SubViewport
var material: ShaderMaterial
var checks := 0
var failed := 0
func _initialize(): call_deferred("run")
func ticks(n: int):
	for i in range(n): await process_frame
func check(ok: bool,label: String):
	checks += 1
	if not ok: failed += 1
	print("PASS " if ok else "FAIL ",label)
func grab() -> Image:
	w._apply_environment()
	await ticks(2)
	await RenderingServer.frame_post_draw
	return probe.get_texture().get_image()
func count_lit(image: Image,channel := 0,threshold := .5) -> int:
	var count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x,y)[channel]>threshold: count += 1
	return count
func advancing(a: Image,b: Image,channel := 0) -> bool:
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			if b.get_pixel(x,y)[channel]+.002<a.get_pixel(x,y)[channel]: return false
	return true
func islands(image: Image) -> int:
	var size := image.get_width()
	var visited := PackedByteArray()
	visited.resize(size*size)
	var count := 0
	for y in range(size):
		for x in range(size):
			if visited[y*size+x] or image.get_pixel(x,y).r<.65: continue
			var pending: Array[Vector2i] = [Vector2i(x,y)]
			visited[y*size+x] = 1
			var area := 0
			while not pending.is_empty():
				var p := pending.pop_back() as Vector2i
				area += 1
				for d: Vector2i in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
					var q := p+d
					if q.x<0 or q.y<0 or q.x>=size or q.y>=size: continue
					if visited[q.y*size+q.x] or image.get_pixel(q.x,q.y).r<.65: continue
					visited[q.y*size+q.x] = 1
					pending.append(q)
			if area>=4: count += 1
	return count
func setup_probe():
	probe = SubViewport.new()
	probe.size = Vector2i(192,192)
	probe.own_world_3d = true
	probe.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(probe)
	var camera := Camera3D.new()
	probe.add_child(camera)
	camera.position.z = 3
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new()
	mesh.mesh.size = Vector2(2,2)
	material = ShaderMaterial.new()
	material.shader = load("res://tests/weather_probe.gdshader")
	mesh.material_override = material
	probe.add_child(mesh)
func advance(seconds: float):
	for i in range(int(seconds*60)): w._process(1.0/60)
func shot(label: String):
	w._apply_environment()
	await ticks(14)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/weather-spread/"+label+".png")
	print("SPREAD_CAPTURE ",label," wet=",snappedf(w.wetness,.001)," snow=",snappedf(w.snow_cover,.001))
func run():
	if DisplayServer.get_name()=="headless":
		push_error("Requires real GPU rendering")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://docs/weather-spread")
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted = true
	await ticks(35)
	game.set_process(false)
	game.player.set_physics_process(false)
	game.player.invulnerable = 0
	w = game.weather
	w.set_process(false)
	w.lightning_enabled = false
	setup_probe()
	w.wetness = 0
	w.snow_cover = 0
	var dry := await grab()
	check(count_lit(dry,0,.001)==0 and count_lit(dry,1,.001)==0,"zero accumulation leaves every shader coverage pixel dry and snow-free")
	w.wetness = .24
	var early := await grab()
	var patches := islands(early)
	early.save_png("res://docs/weather-spread/mask-early.png")
	check(patches>=5 and count_lit(early)<192*192*.35,"wetting starts from %d separate local patches, not one broad band" % patches)
	w.wetness = .45
	var middle := await grab()
	middle.save_png("res://docs/weather-spread/mask-middle.png")
	check(advancing(early,middle) and count_lit(middle)>count_lit(early)*2,"existing patches expand and merge without previously wet pixels turning dry")
	w.wetness = 1
	var full := await grab()
	check(count_lit(full,0,.995)==192*192,"100 percent wet exposure covers every rendered ground coordinate")
	w.wetness = .35
	w.snow_cover = .35
	var both := await grab()
	var different := 0
	for y in range(192):
		for x in range(192):
			var c := both.get_pixel(x,y)
			if absf(c.r-c.g)>.15: different += 1
	check(different>3000,"rain and snow share the spread mechanism with independent arrival patterns")
	w.snow_cover = 1
	var all_snow := await grab()
	check(count_lit(all_snow,1,.995)==192*192,"snow coverage also reaches every upward-facing sample")
	material.set_shader_parameter("origin",Vector2(-.001,0))
	material.set_shader_parameter("extent",Vector2(0,128))
	var left := await grab()
	material.set_shader_parameter("origin",Vector2(.001,0))
	var right := await grab()
	var seam := 0.0
	for y in range(192): seam = maxf(seam,absf(left.get_pixel(90,y).r-right.get_pixel(90,y).r))
	check(seam<.025,"world texture wrapping has no visible coverage seam: %.4f" % seam)
	material.set_shader_parameter("mode",2)
	material.set_shader_parameter("origin",Vector2.ZERO)
	material.set_shader_parameter("extent",Vector2(40,40))
	w.wetness = 0
	w.snow_cover = 0
	var dry_surface := await grab()
	w.wetness = 1
	var wet_surface := await grab()
	var dry_green := dry_surface.get_pixel(90,90).srgb_to_linear().g
	var wet_green := wet_surface.get_pixel(90,90).srgb_to_linear().g
	check(absf(wet_green/dry_green-.58)<.035,"shared coating visibly darkens a fully soaked material: %.3f linear ratio" % (wet_green/dry_green))
	material.set_shader_parameter("mode",1)
	w.clock = 3600
	w.wind_phase = 12
	w.set_wind(0,true)
	var initial := await grab()
	w.set_wind(2)
	var previous := initial.get_pixel(90,90).srgb_to_linear().r
	var max_step := 0.0
	for i in range(250):
		w._process(1.0/60)
		await process_frame
		await RenderingServer.frame_post_draw
		var current := probe.get_texture().get_image().get_pixel(90,90).srgb_to_linear().r
		max_step = maxf(max_step,absf(current-previous))
		previous = current
	check(max_step<.045,"actual shared wind shader stays continuous after one hour: max frame displacement %.4f m" % max_step)
	w.clock = 2
	var short_session := await grab()
	w.clock = 36000
	var long_session := await grab()
	check(short_session.get_pixel(90,90)==long_session.get_pixel(90,90),"changing elapsed game time alone cannot teleport the shader wind")
	probe.queue_free()
	w.clock = 12
	w.wind_phase = 12
	w.set_time(0,true)
	w.set_wind(0,true)
	w.wetness = 0
	w.snow_cover = 0
	w.set_weather(0,true)
	await shot("rain-00")
	w.set_weather(2)
	advance(4)
	await shot("rain-04")
	advance(4)
	await shot("rain-08")
	advance(4)
	await shot("rain-12")
	advance(10)
	await shot("rain-22")
	w.set_weather(0,true)
	advance(30)
	await shot("drying-30")
	w.wetness = 0
	w.snow_cover = 0
	w.set_weather(4)
	advance(8)
	await shot("snow-08")
	advance(10)
	await shot("snow-18")
	advance(14)
	await shot("snow-32")
	advance(18)
	await shot("snow-50")
	print("WEATHER_SPREAD_RENDER_RESULT ",checks-failed,"/",checks)
	game.queue_free()
	await ticks(3)
	quit(1 if failed else 0)
