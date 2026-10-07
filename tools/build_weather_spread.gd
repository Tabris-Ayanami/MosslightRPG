extends SceneTree
## Offline data bake, not an albedo image. R/G encode wet/snow arrival times.
## Runtime only samples one shared texture; no per-frame diffusion bake/readback.
const SIZE := 512
const CELLS := 24
const PERIOD_METERS := 128.0

func _initialize() -> void:
	var image := Image.create(SIZE,SIZE,false,Image.FORMAT_RGH)
	var wet := features(42917)
	var snow := features(78301)
	for y in range(SIZE):
		for x in range(SIZE):
			var uv := (Vector2(x,y)+Vector2(.5,.5))/SIZE
			# Periodic domain distortion breaks perfect circles without a tile seam.
			var p := uv*CELLS
			p += Vector2(sin(TAU*(uv.x*5+uv.y*7))*.16+sin(TAU*(uv.x*17-uv.y*11))*.055,
				sin(TAU*(uv.x*9-uv.y*4))*.16+sin(TAU*(uv.x*13+uv.y*19))*.055)
			image.set_pixel(x,y,Color(arrival(p,wet),arrival(p,snow),0,1))
	DirAccess.make_dir_recursive_absolute("res://assets/weather")
	var texture := ImageTexture.create_from_image(image)
	var error := ResourceSaver.save(texture,"res://assets/weather/surface_arrival.res",ResourceSaver.FLAG_COMPRESS)
	print("WEATHER_SPREAD_BAKE ",SIZE,"x",SIZE," period=",PERIOD_METERS,"m, RG wet/snow, error=",error)
	quit(error)

func features(seed_value: int) -> Array[Vector4]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var result: Array[Vector4] = []
	for i in range(CELLS*CELLS):
		result.append(Vector4(rng.randf_range(.1,.9),rng.randf_range(.1,.9),
			rng.randf_range(.035,.34),rng.randf_range(.37,.49)))
	return result

func arrival(p: Vector2, points: Array[Vector4]) -> float:
	var cell := Vector2i(floor(p.x),floor(p.y))
	var earliest := 2.0
	# Weighted start times can make a point beyond the nearest cell win.
	for dy in range(-2,3):
		for dx in range(-2,3):
			var neighbor := cell+Vector2i(dx,dy)
			var point := points[posmod(neighbor.y,CELLS)*CELLS+posmod(neighbor.x,CELLS)]
			var delta := p-(Vector2(neighbor)+Vector2(point.x,point.y))
			var distance := (delta*Vector2(.92,1.08)).length()
			earliest = minf(earliest,point.z+distance*point.w)
	# A 0.14-wide front must finish everywhere by progress=1.
	return clampf(earliest,.02,.85)
