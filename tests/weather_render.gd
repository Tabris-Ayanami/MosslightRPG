extends SceneTree
## Verify rendered changes, rather than just the weather controller's variables.
var game: Node
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
	await ticks(4)
	await RenderingServer.frame_post_draw
	return game.viewport.get_texture().get_image()
func differences(a: Image,b: Image) -> int:
	var count := 0
	for y in range(20,a.get_height()-20):
		for x in range(20,a.get_width()-20):
			var c := a.get_pixel(x,y)
			var d := b.get_pixel(x,y)
			if Vector3(c.r,c.g,c.b).distance_to(Vector3(d.r,d.g,d.b))>.05: count += 1
	return count
func luminance(image: Image) -> float:
	var total := 0.0
	var count := 0
	for y in range(0,image.get_height(),4):
		for x in range(0,image.get_width(),4):
			var c := image.get_pixel(x,y)
			total += c.r*.2126+c.g*.7152+c.b*.0722
			count += 1
	return total/count
func run():
	if DisplayServer.get_name()=="headless":
		push_error("Requires a real GPU")
		quit(1)
		return
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted=true
	await ticks(30)
	game.set_process(false)
	game.player.visible=false
	game.weather.set_process(false)
	game.weather.clock=10
	game.weather.set_wind(0,true)
	var day := await grab()
	game.weather.set_wind(2,true)
	var gale := await grab()
	var wind_pixels := differences(day,gale)
	check(wind_pixels>200,"gale actually changes rendered vegetation and water: %d changed pixels" % wind_pixels)
	game.weather.set_wind(0,true)
	var restored := await grab()
	var returned := differences(day,restored)
	check(returned<100,"same wind/time restores geometry: %d changed pixels" % returned)
	game.weather.set_time(2,true)
	var night := await grab()
	var ratio := luminance(night)/luminance(day)
	check(ratio>.08 and ratio<.65,"rendered night is darker but readable: %.3f relative luminance" % ratio)
	game.weather.set_time(0,true)
	game.weather.set_weather(2,true)
	await ticks(160)
	game.weather.effects.rain.visible=false
	var without_rain := await grab()
	game.weather.effects.rain.visible=true
	var with_rain := await grab()
	var rain_pixels := differences(without_rain,with_rain)
	check(rain_pixels>100,"rain particles are visible through the actual pixel pipeline: %d pixels" % rain_pixels)
	game.weather.set_weather(4,true)
	await ticks(400)
	game.weather.effects.snow.visible=false
	var without_snow := await grab()
	game.weather.effects.snow.visible=true
	var with_snow := await grab()
	var snow_pixels := differences(without_snow,with_snow)
	check(snow_pixels>60,"snowflakes are visible in the actual scene: %d pixels" % snow_pixels)
	print("WEATHER_RENDER_RESULT ",checks-failed,"/",checks)
	game.queue_free()
	await ticks(3)
	quit(1 if failed else 0)
