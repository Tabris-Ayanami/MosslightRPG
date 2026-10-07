extends SceneTree
var game: Node
var checks := 0
var failed := 0
func _initialize(): call_deferred("run")
func check(ok: bool,label: String):
	checks += 1
	if not ok: failed += 1
	print("PASS " if ok else "FAIL ",label)
func simulate(w: Node,seconds: float,fps := 60):
	for i in range(int(seconds*fps)): w._process(1.0/fps)
func dry_reset(w: Node):
	w.set_weather(0,true)
	w.wetness = 0
	w.snow_cover = 0
func run():
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted = true
	game.set_process(false)
	var w: Node = game.weather
	w.set_process(false)
	w.lightning_enabled = false
	w.clock = 3600
	w.wind_phase = 20
	w.set_wind(2)
	check(w.wind_phase==20,"selecting a stronger wind never rewrites the phase after an hour of play")
	var max_step := 0.0
	for i in range(300):
		var before: float = w.wind_phase
		w._process(1.0/60)
		max_step = maxf(max_step,w.wind_phase-before)
	check(max_step<=1.9/60+.00001,"wind phase increments remain bounded through the entire transition")
	w.set_wind(0)
	var before_phase: float = w.wind_phase
	simulate(w,4)
	check(w.wind_phase>before_phase and w.wind_phase-before_phase<7.7,"decreasing wind also advances phase continuously")
	dry_reset(w)
	w.set_weather(2)
	simulate(w,4)
	check(w.rain_amount>.99 and w.wetness>.4 and w.wetness<.6,"full rainfall starts while wet fronts are still spreading")
	var at_four: float = w.wetness
	simulate(w,1)
	check(w.wetness>at_four and w.wetness<.9,"wet fronts continue spreading after the precipitation transition ends")
	simulate(w,1.1)
	check(is_equal_approx(w.wetness,1),"downpour fully saturates the ground within 6.1 seconds, including the rain transition")
	w.set_weather(0,true)
	check(w.wetness==1,"stopping rain preserves accumulated moisture")
	simulate(w,7)
	check(w.wetness>.5 and w.wetness<.8,"drying takes time after the rain has stopped")
	simulate(w,20)
	check(is_zero_approx(w.wetness),"clear daylight eventually dries the whole surface")
	dry_reset(w)
	w.set_weather(1,true)
	simulate(w,4.2)
	check(w.wetness>.20 and w.wetness<.25,"light rain soaks more slowly than a downpour")
	simulate(w,17)
	check(w.wetness==1,"long light rain can also wet every patch")
	dry_reset(w)
	w.set_weather(4,true)
	simulate(w,2)
	check(w.wetness>w.snow_cover and w.snow_cover>.1 and w.snow_cover<.2,"snow first moistens the surface while white coverage builds more slowly")
	simulate(w,11)
	check(w.snow_cover==1 and w.wetness==1,"continuous snowfall reaches complete upward-surface coverage")
	w.set_weather(0,true)
	w.wetness = .1
	simulate(w,2)
	check(w.snow_cover<1 and w.snow_cover>.9 and w.wetness>0,"melting retains snow and moisture instead of instantly resetting")
	dry_reset(w)
	w.set_weather(2,true)
	simulate(w,3,30)
	var wet_30: float = w.wetness
	dry_reset(w)
	w.set_weather(2,true)
	simulate(w,3,120)
	check(absf(w.wetness-wet_30)<.0001,"surface accumulation is independent of 30/120 FPS")
	print("WEATHER_SPREAD_RESULT ",checks-failed,"/",checks)
	game.queue_free()
	await process_frame
	await process_frame
	quit(1 if failed else 0)
