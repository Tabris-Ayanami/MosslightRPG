extends SceneTree
## Full GPU renders, including real precipitation and the regular pixel pipeline.
var game: Node
func _initialize(): call_deferred("run")
func ticks(n: int):
	for i in range(n): await process_frame
func shot(label: String, time: int, kind: int, wind := 0, at := Vector3(1.6,2.35,4.8), height := 18.0, yaw := 0.3947911197):
	game.player.restore(game.GARDEN_ORIGIN+at)
	game.player.invulnerable = 0.0
	game.camera_height = height
	game.target_camera_height = height
	game.camera_yaw = yaw
	game.smooth_target = game.player.global_position+game._camera_lead()
	game.weather.set_time(time,true)
	game.weather.set_weather(kind,true)
	game.weather.set_wind(wind,true)
	# This overview previews mature weather; weather_spread_render checks the
	# real accumulation timeline without assigning intermediate surface states.
	game.weather.wetness = (.45 if kind==1 else 1.0) if kind>0 else 0.0
	game.weather.snow_cover = .85 if kind == 4 else 0.0
	await ticks(360 if kind == 4 else 125)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/weather/"+label+".png")
	print("WEATHER_CAPTURE ",label," rain=",game.weather.rain_amount," snow=",game.weather.snow_cover," wind=",game.weather.wind_strength)
func run():
	if DisplayServer.get_name() == "headless":
		push_error("Weather screenshots require the GPU.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://docs/weather")
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted = true
	await ticks(25)
	await shot("day-breeze",0,0)
	await shot("dusk",1,0)
	await shot("night",2,0)
	await shot("light-rain",0,1)
	await shot("downpour",0,2,1)
	await shot("thunderstorm",1,3,2)
	game.weather.trigger_lightning()
	await ticks(2)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/weather/lightning.png")
	print("WEATHER_CAPTURE lightning")
	await shot("snow",0,4)
	await shot("forest-gale",0,0,2,Vector3(40,2.4,3),14)
	await shot("village-dusk",1,0,0,Vector3(1,2.4,-36),18)
	await shot("village-night",2,0,0,Vector3(1,2.4,-36),18)
	await shot("village-snow",0,4,1,Vector3(1,2.4,-36),18)
	await shot("rain-far-orbit",0,2,2,Vector3(1.6,2.35,4.8),32,-1.17)
	await shot("snow-night-close",2,4,2,Vector3(2.5,2.35,7.5),8,2.5)
	game.queue_free()
	await ticks(3)
	quit()
