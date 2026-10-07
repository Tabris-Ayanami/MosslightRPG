extends SceneTree
## GPU acceptance checks: rendered impacts, clear bed, foreground masking and
## deterministic water animation. Run with --fixed-fps 30 and a real renderer.
var game: Node
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("PASS " if ok else "FAIL ",label)

func ticks(count: int, animate := false) -> void:
	for i in range(count):
		if animate: game.weather._process(1.0/30.0)
		await process_frame

func grab() -> Image:
	await ticks(4)
	await RenderingServer.frame_post_draw
	return game.viewport.get_texture().get_image()

func area(image: Image, region: Rect2) -> Rect2i:
	return Rect2i(Vector2i(region.position*Vector2(image.get_size())),Vector2i(region.size*Vector2(image.get_size())))

func difference(a: Image, b: Image, region := Rect2(0,0,1,1), threshold := .025) -> int:
	var bounds := area(a,region)
	var count := 0
	for y in range(bounds.position.y,bounds.end.y):
		for x in range(bounds.position.x,bounds.end.x):
			var c := a.get_pixel(x,y)
			var d := b.get_pixel(x,y)
			if Vector3(c.r,c.g,c.b).distance_to(Vector3(d.r,d.g,d.b)) > threshold: count += 1
	return count

func contrast(image: Image, region: Rect2) -> float:
	var bounds := area(image,region)
	var total := 0.0
	var count := 0
	for y in range(bounds.position.y,bounds.end.y-1):
		for x in range(bounds.position.x,bounds.end.x-1):
			var c := image.get_pixel(x,y)
			var d := image.get_pixel(x+1,y)
			total += absf(c.get_luminance()-d.get_luminance())
			count += 1
	return total/maxi(count,1)

func mean_luminance(image: Image, region: Rect2) -> float:
	var bounds := area(image,region)
	var total := 0.0
	for y in range(bounds.position.y,bounds.end.y):
		for x in range(bounds.position.x,bounds.end.x): total+=image.get_pixel(x,y).get_luminance()
	return total/float(bounds.size.x*bounds.size.y)

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Rain/water art acceptance needs a GPU.")
		quit(1)
		return
	root.size=Vector2i(1280,720)
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted=true
	game.hud.hide()
	game.player.hide()
	game.set_process(false)
	game.weather.set_process(false)
	game.weather.lightning_enabled=false
	for actor: Node in game.world.find_children("*","CharacterBody3D",true,false):
		actor.set_physics_process(false)
	game.camera_height=10.0
	game.target_camera_height=10.0
	game.camera_yaw=.3947911197
	game.camera_pitch_degrees=55.0
	game.smooth_target=game.GARDEN_ORIGIN+Vector3(2.5,1.7,9)
	game._resize()
	game._process(0.0)
	game.weather.set_time(0,true)
	game.weather.set_weather(0,true)
	game.weather.clock=12.0
	game.weather.wind_phase=12.0
	game.weather._apply_environment()
	await ticks(20)
	var water := await grab()
	game.reference_map.get_node("Lake").visible=false
	var bed := await grab()
	var bed_region := Rect2(.04,.66,.32,.28)
	var contrast_ratio := contrast(water,bed_region)/maxf(contrast(bed,bed_region),.0001)
	check(contrast_ratio>.45 and contrast_ratio<1.6,"submerged pebble contrast remains visible: %.3f of exposed bed"%contrast_ratio)
	var pier_changes := difference(water,bed,Rect2(.465,.575,.04,.04))
	check(pier_changes<8,"water does not refract through the foreground pier: %d changed pixels"%pier_changes)
	game.reference_map.get_node("Lake").visible=true
	var restored := await grab()
	var water_region := Rect2(.04,.66,.90,.28)
	check(difference(water,restored,water_region)<10,"same weather clock restores the water image")
	game.water_material.set_shader_parameter("use_reflection",false)
	var calm := await grab()
	game.weather.clock=13.4
	game.weather._apply_environment()
	var moved := await grab()
	var wave_changes := difference(calm,moved,water_region,.012)
	check(wave_changes>25,"calm water crests actually animate: %d changed pixels"%wave_changes)
	game.weather.clock=12.0
	game.weather._apply_environment()
	var reset := await grab()
	check(difference(calm,reset,water_region)<10,"water animation uses the controllable weather clock")
	game.water_material.set_shader_parameter("use_reflection",true)
	await ticks(4)
	var reflection: Image=game.reflection_viewport.get_texture().get_image()
	var empty := 0
	var solid := 0
	for y in range(0,reflection.get_height(),2):
		for x in range(0,reflection.get_width(),2):
			var alpha := reflection.get_pixel(x,y).a
			if alpha<.01: empty+=1
			elif alpha>.99: solid+=1
	check(empty>100 and solid>100,"reflection preserves transparent sky and opaque objects: %d / %d samples"%[empty,solid])
	# Inspect an entire lake view, rather than only the pebbled strip by the bank.
	game.camera_pitch_degrees=76
	game.smooth_target=game.GARDEN_ORIGIN+Vector3(-6,.6,23)
	game._process(0)
	game.reference_map.get_node("Lake").hide()
	var full_bed := await grab()
	game.reference_map.get_node("Lake").show()
	var full_water := await grab()
	var minimum_contrast := INF
	var maximum_haze := 0.0
	for y in range(4):
		for x in range(6):
			var region := Rect2(.05+x*.15,.05+y*.225,.15,.225)
			minimum_contrast=minf(minimum_contrast,contrast(full_bed,region))
			maximum_haze=maxf(maximum_haze,mean_luminance(full_water,region)-mean_luminance(full_bed,region))
	check(minimum_contrast>.005,"every lake region has readable bed detail, without bare grey patches: %.4f"%minimum_contrast)
	check(maximum_haze<.010,"water does not add broad white/grey haze over the bed: %.4f"%maximum_haze)
	game.camera_pitch_degrees=55
	game.smooth_target=game.GARDEN_ORIGIN+Vector3(2.5,1.7,9)
	game._process(0)
	game.weather.set_weather(2,true)
	await ticks(200,true)
	var effects: Node=game.weather.effects
	effects.rain.speed_scale=0.0
	effects.rain_impacts.speed_scale=0.0
	var impacts := await grab()
	effects.rain_impacts.hide()
	var no_impacts := await grab()
	var impact_changes := difference(impacts,no_impacts,Rect2(.02,.02,.96,.52),.012)
	check(impact_changes>5,"collision-emitted ground splashes are rendered: %d changed pixels"%impact_changes)
	effects.rain_impacts.show()
	check(effects.rain.get_node(effects.rain.sub_emitter)==effects.rain_impacts,"rain contacts route to the impact emitter")
	game.weather.set_weather(4,true)
	check(not effects.rain_impacts.visible and not effects.rain.emitting and effects.snow.emitting,"snow removes rain splashes and switches emitters")
	game.weather.set_weather(0,true)
	check(not effects.rain_impacts.visible and not effects.rain.emitting and not effects.snow.emitting,"clear weather removes precipitation and impact marks")
	print("RAIN_WATER_ART_RESULT ",passed,"/",passed+failed)
	game.queue_free()
	await ticks(4)
	quit(1 if failed else 0)
