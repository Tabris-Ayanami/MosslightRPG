extends SceneTree
## Real input, frame scheduling, transitions, light/audio response and scene reload.
var game: Node
var checks := 0
var failed := 0
func _initialize(): call_deferred("run")
func ticks(n: int):
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool,label: String):
	checks += 1
	if not ok: failed += 1
	print("PASS " if ok else "FAIL ",label)
func key(code: Key):
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.alt_pressed = code >= KEY_0 and code <= KEY_9
	event.pressed = true
	Input.parse_input_event(event)
	await ticks(1)
	event.pressed = false
	Input.parse_input_event(event)
	await ticks(1)
func run():
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.sound.muted = true
	await ticks(12)
	var w: Node = game.weather
	w.transition_seconds = .5
	check(w.time_of_day == 0 and w.weather_type == 0 and is_equal_approx(w.wind_strength,1),"default day, clear sky and breeze")
	check(not game.hud.visible,"weather creates no HUD or text")
	var village_only: bool = w.effects.lanterns.size()==4
	for lantern: OmniLight3D in w.effects.lanterns:
		village_only = village_only and lantern.global_position.z < game.GARDEN_ORIGIN.z-25
	check(village_only,"all four lights remain inside the village; no garden or forest lamps")
	check(game.camera.environment == game.reflection_camera.environment,"main view and reflection share the time/weather environment")
	var leaf: GeometryInstance3D = game.reference_map.get_node("AncientTrees").get_child(0).get_node("ClusteredLeaves")
	var trunk: GeometryInstance3D = leaf.get_parent().get_node("ForkedTrunk")
	check(leaf.get_instance_shader_parameter("weather_tree") == trunk.get_instance_shader_parameter("weather_tree"),"leaf clumps and branches share their actual tree-root wind anchor")
	check(leaf.extra_cull_margin >= 3.1,"storm displacement is inside expanded foliage culling bounds")
	var day_energy: float = game.garden_sun.light_energy
	await key(KEY_2)
	check(w.hour > 12 and w.hour < 18,"time changes interpolate rather than jump")
	await ticks(34)
	check(is_equal_approx(w.hour,18) and game.garden_sun.light_color.r > game.garden_sun.light_color.b*1.5,"dusk reaches warm sunlight")
	check(w.effects.lanterns[0].visible,"lanterns light at dusk")
	await key(KEY_3)
	await ticks(34)
	check(game.garden_sun.light_energy < day_energy*.3 and game.garden_sun.light_energy > .1,"night keeps readable moonlight")
	check(w.current_light.z>w.current_light.x,"unshaded water highlights receive the night colour")
	await key(KEY_5)
	await ticks(34)
	check(w.rain_amount>.1 and w.rain_amount<.3 and w.effects.rain.emitting,"light rain emits a low density of real particles")
	check(w.time_of_day==2 and w.snowfall==0,"rain preserves selected time and excludes snow")
	await key(KEY_6)
	await ticks(34)
	check(is_equal_approx(w.rain_amount,1) and game.garden_environment.fog_enabled,"heavy rain reaches full emission and weather haze")
	check(w.effects.rain.process_material.collision_mode==ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT,"precipitation is configured for height-field contact hiding")
	check(not w.effects.rain.local_coords,"existing rain remains in world space as the camera moves")
	await key(KEY_9)
	await ticks(34)
	check(is_equal_approx(w.wind_strength,3.8) and w.rain_amount==1,"strong wind can combine with heavy rain")
	await key(KEY_9)
	await ticks(34)
	check(is_equal_approx(w.wind_strength,7),"gale preset")
	await key(KEY_9)
	await ticks(34)
	check(is_equal_approx(w.wind_strength,1),"wind cycle returns to the default breeze")
	await key(KEY_7)
	await ticks(34)
	check(w.effects.snow.emitting and not w.effects.rain.emitting,"snow switches precipitation systems cleanly")
	w._process(w.snow_settling_seconds*.45)
	var settled: float = w.snow_cover
	check(settled>.4 and settled<.65,"snow accumulates gradually on surfaces")
	await key(KEY_4)
	await ticks(34)
	w._process(10)
	check(w.snow_cover<settled and w.snow_cover>0,"settled snow melts gradually after snowfall stops")
	check(not w.effects.rain.emitting and not w.effects.snow.emitting,"clear weather stops both emitters")
	await key(KEY_8)
	await ticks(34)
	check(w.wind_strength==7 and w.rain_amount==1,"thunderstorm combines downpour and gale")
	await key(KEY_0)
	check(w.lightning_count==1 and w.flash>0 and w.effects.bolt.visible,"lightning creates a bolt and lights the scene")
	check(w.thunder_count==0,"thunder is delayed after the flash")
	await ticks(125)
	check(w.thunder_count==1 and w.flash==0 and not w.effects.bolt.visible,"thunder follows once and lightning fades out")
	w._strike_timer = .01
	await ticks(2)
	check(w.lightning_count==2,"storms also schedule lightning automatically")
	await key(KEY_4)
	await ticks(34)
	var count: int = w.lightning_count
	await key(KEY_0)
	check(w.lightning_count==count and w.flash==0,"clear weather cannot trigger leftover lightning")
	await key(KEY_ESCAPE)
	var frozen: float = w.clock
	await ticks(10)
	await key(KEY_8)
	check(w.clock==frozen and w.weather_type==0,"pause freezes the weather clock and ignores preview keys")
	await key(KEY_ESCAPE)
	await ticks(2)
	check(w.clock>frozen,"weather resumes after pause")
	w.automatic_day_cycle = true
	w.day_length_seconds = 120
	w.hour = 23.99
	w._process(1)
	check(w.hour<1 and w.hour>=0,"automatic day cycle wraps midnight continuously")
	w.automatic_weather = true
	w.weather_interval_seconds = 20
	w._weather_timer = 20
	w._process(.1)
	check(w.weather_type!=0,"optional automatic weather chooses a new preset")
	check(w.ambience.rain_voice.stream is AudioStreamWAV and w.ambience.thunder_voice.stream.get_length()>4,"rain, wind and thunder have generated audio streams")
	await key(KEY_M)
	var wind_running: bool = w.ambience.wind_voice.playing and not game.sound.muted
	await key(KEY_M)
	check(wind_running and game.sound.muted and not w.ambience.rain_voice.playing and not w.ambience.wind_voice.playing,"M toggles weather ambience together with game sound")
	game.queue_free()
	await ticks(3)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(3)
	check(game.weather.rain_amount==0 and game.weather.snow_cover==0 and not game.garden_environment.fog_enabled,"reloading returns to clean day defaults without stale weather")
	print("WEATHER_TEST_RESULT ",checks-failed,"/",checks)
	game.queue_free()
	await ticks(3)
	quit(1 if failed else 0)
