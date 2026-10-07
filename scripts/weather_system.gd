extends Node
## Orthogonal time / precipitation / wind controls. No in-game UI is created.
signal weather_changed(kind: int)
signal lightning_struck
signal thunder_sounded
enum TimeOfDay { DAY, DUSK, NIGHT }
enum Weather { CLEAR, LIGHT_RAIN, HEAVY_RAIN, THUNDERSTORM, SNOW }
enum Wind { BREEZE, STRONG, GALE }
const Effects = preload("res://scripts/weather_effects.gd")
const Audio = preload("res://scripts/weather_audio.gd")
const GLOBAL_NAMES := ["weather_clock","weather_wind_phase","weather_wetness","weather_surface_scale","weather_wind","weather_rain","weather_snow","weather_cloud","weather_light"]
const HOURS := [12.0,18.0,22.0]
const WIND_STRENGTHS := [1.0,3.8,7.0]
const PROFILES := [Vector3(0,0,0),Vector3(.20,0,.45),Vector3(1,0,.90),Vector3(1,0,1),Vector3(0,1,.65)]

@export_group("Time of day")
@export_enum("白天", "黄昏", "黑夜") var time_of_day := 0
@export var automatic_day_cycle := false
@export_range(60,3600,30) var day_length_seconds := 720.0
@export_group("Weather")
@export_enum("晴天", "小雨", "暴雨", "雷暴", "下雪") var weather_type := 0
@export var automatic_weather := false
@export_range(20,600,5) var weather_interval_seconds := 120.0
@export_range(.2,15,.1) var transition_seconds := 4.0
@export var lightning_enabled := true
@export_range(0,1,.05) var lightning_brightness := .8
@export_group("Wind")
@export_enum("微风", "大风", "暴风") var wind_type := 0
@export_range(0,360,1) var wind_direction_degrees := 30.0
@export_group("Surface accumulation")
@export_range(1,90,1) var soaking_seconds := 4.0
@export_range(5,300,5) var drying_seconds := 25.0
@export_range(2,180,1) var snow_settling_seconds := 12.0
@export_range(5,300,5) var snow_melting_seconds := 30.0
@export_range(.5,2,.05) var spread_scale := 1.0
@export_group("Preview")
@export var keyboard_preview := true

var game: Node
var effects: Node3D
var ambience: Node
var clock := 0.0
var wind_phase := 0.0
var wetness := 0.0
var hour := 12.0
var rain_amount := 0.0
var snowfall := 0.0
var snow_cover := 0.0
var cloud_cover := 0.0
var wind_strength := 1.0
var flash := 0.0
var lightning_count := 0
var thunder_count := 0
var current_light := Vector3.ONE
var _selected := Vector3i(-1,-1,-1)
var _from := PackedFloat32Array()
var _blend := 1.0
var _weather_timer := 0.0
var _strike_timer := 7.0
var _flash_remaining := 0.0
var _thunder_delay := -1.0
var _base_sun_rotation := Vector3.ZERO
var _random := RandomNumberGenerator.new()

func setup(owner_game: Node) -> void:
	game = owner_game
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_random.seed = 29531
	_base_sun_rotation = game.garden_sun.rotation
	hour = HOURS[clampi(time_of_day,0,2)]
	effects = Effects.new()
	effects.name = "WeatherEffects"
	game.world.add_child(effects)
	effects.setup(game)
	ambience = Audio.new()
	ambience.name = "WeatherAudio"
	add_child(ambience)
	_prepare_tree_wind(game.reference_map)
	_read_settings(true)
	_apply_environment()

func set_time(value: int, instant := false) -> void:
	time_of_day = clampi(value,0,2)
	automatic_day_cycle = false
	_read_settings(instant)

func set_weather(value: int, instant := false) -> void:
	weather_type = clampi(value,0,4)
	_read_settings(instant)

func set_wind(value: int, instant := false) -> void:
	wind_type = clampi(value,0,2)
	_read_settings(instant)

func _read_settings(instant := false) -> void:
	if game == null: return
	var selection := Vector3i(clampi(time_of_day,0,2),clampi(weather_type,0,4),clampi(wind_type,0,2))
	if selection == _selected and not instant: return
	var changed_weather := selection.y != _selected.y
	_selected = selection
	_from = PackedFloat32Array([hour,rain_amount,snowfall,cloud_cover,wind_strength])
	_blend = 1.0 if instant else 0.0
	if changed_weather:
		_weather_timer = 0
		_strike_timer = _random.randf_range(5,9)
		if selection.y != Weather.THUNDERSTORM:
			_thunder_delay = -1
			_flash_remaining = 0
			flash = 0
		weather_changed.emit(selection.y)
	_update_transition(0)
	_apply_environment()

func _process(delta: float) -> void:
	if game == null: return
	_read_settings()
	clock += delta
	var previous_wind_speed := _wind_speed()
	_update_transition(delta)
	# Integrate velocity. Multiplying the elapsed game time by a changing speed
	# teleports the phase and becomes arbitrarily violent in long sessions.
	wind_phase += delta*(previous_wind_speed+_wind_speed())*.5
	if automatic_day_cycle:
		hour = fposmod(hour+24.0*delta/maxf(60,day_length_seconds),24.0)
	if automatic_weather:
		_weather_timer += delta
		if _weather_timer >= weather_interval_seconds:
			var options: Array[int] = [0,0,1,2,3,4]
			while options.has(weather_type): options.erase(weather_type)
			set_weather(options[_random.randi_range(0,options.size()-1)])
	_update_surfaces(delta)
	_update_lightning(delta)
	_apply_environment()

func _wind_speed() -> float:
	return 1.0+(wind_strength-1.0)*.15

func _update_surfaces(delta: float) -> void:
	# Exposure accumulates independently of particle emission. Even light rain
	# eventually saturates the ground; stopping rain doesn't instantly dry it.
	var previous_snow := snow_cover
	if snowfall > .001:
		snow_cover = minf(1.0,snow_cover+snowfall*delta/maxf(1,snow_settling_seconds))
	else:
		snow_cover = maxf(0.0,snow_cover-delta*(1.0/maxf(1,snow_melting_seconds)+rain_amount/28.0))
	var moisture := rain_amount+snowfall*.65
	if moisture > .001:
		wetness = minf(1.0,wetness+moisture*delta/maxf(1,soaking_seconds))
	else:
		var evaporation := lerpf(1.0,.45,_phase()*.5)
		wetness = maxf(0.0,wetness-delta*evaporation/maxf(1,drying_seconds))
	# Melting snow leaves moisture, instead of revealing instantly dry grass.
	wetness = minf(1.0,wetness+maxf(0,previous_snow-snow_cover)*.75)

func _update_transition(delta: float) -> void:
	_blend = minf(1.0,_blend+delta/maxf(.2,transition_seconds))
	var weight := smoothstep(0,1,_blend)
	var profile: Vector3 = PROFILES[_selected.y]
	if not automatic_day_cycle:
		hour = lerpf(_from[0],HOURS[_selected.x],weight)
	rain_amount = lerpf(_from[1],profile.x,weight)
	snowfall = lerpf(_from[2],profile.y,weight)
	cloud_cover = lerpf(_from[3],profile.z,weight)
	var strength: float = WIND_STRENGTHS[_selected.z]
	if _selected.y == Weather.THUNDERSTORM: strength = maxf(strength,7)
	wind_strength = lerpf(_from[4],strength,weight)

func _phase() -> float:
	# 0 day, 1 sunset/sunrise, 2 moonlight. Continuous at midnight.
	if hour < 5 or hour >= 20: return 2.0
	if hour < 8: return lerpf(2,0,smoothstep(5,8,hour))
	if hour < 16: return 0.0
	return lerpf(0,2,smoothstep(16,20,hour))

func _apply_environment() -> void:
	if game == null: return
	var phase := _phase()
	var colors := [Color("fff2d6"),Color("f8a471"),Color("829fe8")]
	var energies := [1.2,.80,.21]
	var rotations := [_base_sun_rotation,Vector3(deg_to_rad(-40),_base_sun_rotation.y-.65,0),Vector3(deg_to_rad(-58),_base_sun_rotation.y+1.1,0)]
	var index := mini(1,int(phase))
	var weight := phase-index
	var color: Color = colors[index].lerp(colors[index+1],weight)
	var strength: float = lerpf(energies[index],energies[index+1],weight)*(1-cloud_cover*.52)
	var light_flash := flash*lightning_brightness
	game.garden_sun.light_color = color.lerp(Color("dceaff"),light_flash*.8)
	game.garden_sun.light_energy = strength+light_flash*2.4
	game.garden_sun.rotation = rotations[index].lerp(rotations[index+1],weight)
	var environment: Environment = game.garden_environment
	environment.ambient_light_color = Color("859eac").lerp(Color("5b73af"),phase*.5)
	environment.ambient_light_energy = lerpf(.35,.21,phase*.5)+light_flash*.4
	environment.background_color = Color("638f91").lerp(Color("1b2948"),phase*.5).lerp(Color("707f89"),cloud_cover*.3)
	environment.fog_enabled = cloud_cover > .05
	environment.fog_light_color = environment.background_color
	environment.fog_density = cloud_cover*.0035
	environment.fog_sky_affect = 0
	var light: Color = Color.WHITE.lerp(color.srgb_to_linear(),phase*.5)
	current_light = Vector3(light.r,light.g,light.b)*clampf(strength/1.2,.13,1)+Vector3(.8,.88,1)*light_flash
	var direction := Vector2.from_angle(deg_to_rad(wind_direction_degrees))
	RenderingServer.global_shader_parameter_set("weather_clock",clock)
	RenderingServer.global_shader_parameter_set("weather_wind_phase",wind_phase)
	RenderingServer.global_shader_parameter_set("weather_wetness",wetness)
	RenderingServer.global_shader_parameter_set("weather_surface_scale",spread_scale)
	RenderingServer.global_shader_parameter_set("weather_wind",Vector4(direction.x,direction.y,wind_strength,_wind_speed()))
	RenderingServer.global_shader_parameter_set("weather_rain",rain_amount)
	RenderingServer.global_shader_parameter_set("weather_snow",snow_cover)
	RenderingServer.global_shader_parameter_set("weather_cloud",cloud_cover)
	RenderingServer.global_shader_parameter_set("weather_light",current_light)
	effects.update_effects(rain_amount,snowfall,direction,wind_strength,smoothstep(.35,1.7,phase),flash)
	ambience.set_levels(rain_amount,wind_strength,game.sound.muted)

func _update_lightning(delta: float) -> void:
	_flash_remaining = maxf(0,_flash_remaining-delta)
	flash = 0
	if _flash_remaining > .35: flash = 1
	elif _flash_remaining > .25: flash = .10
	elif _flash_remaining > .13: flash = .65
	elif _flash_remaining > 0: flash = _flash_remaining/.13*.4
	if _thunder_delay >= 0:
		_thunder_delay -= delta
		if _thunder_delay < 0:
			ambience.thunder(game.sound.muted)
			thunder_count += 1
			thunder_sounded.emit()
	if weather_type == Weather.THUNDERSTORM and lightning_enabled:
		_strike_timer -= delta
		if _strike_timer <= 0:
			trigger_lightning()
			_strike_timer = _random.randf_range(8,17)

func trigger_lightning() -> void:
	if game == null or weather_type != Weather.THUNDERSTORM or not lightning_enabled: return
	_flash_remaining = .47
	flash = 1
	_thunder_delay = _random.randf_range(.65,1.8)
	lightning_count += 1
	var at: Vector3 = game.player.global_position+game.camera_forward()*12+game.camera_right()*_random.randf_range(-12,12)
	at.y = .8
	effects.show_lightning(at,_random)
	lightning_struck.emit()
	_apply_environment()

func preview_input(event: InputEvent) -> bool:
	if not keyboard_preview or game.paused or not event is InputEventKey or not event.pressed or event.echo: return false
	match event.physical_keycode:
		KEY_1: set_time(TimeOfDay.DAY)
		KEY_2: set_time(TimeOfDay.DUSK)
		KEY_3: set_time(TimeOfDay.NIGHT)
		KEY_4: set_weather(Weather.CLEAR)
		KEY_5: set_weather(Weather.LIGHT_RAIN)
		KEY_6: set_weather(Weather.HEAVY_RAIN)
		KEY_7: set_weather(Weather.SNOW)
		KEY_8: set_weather(Weather.THUNDERSTORM)
		KEY_9: set_wind((wind_type+1)%3)
		KEY_0: trigger_lightning()
		_: return false
	return true

func _prepare_tree_wind(node: Node) -> void:
	if node is Node3D and node.has_node("ClusteredLeaves"):
		var anchor: Vector3 = node.global_position
		for geometry: GeometryInstance3D in node.find_children("*","GeometryInstance3D",true,false):
			geometry.set_instance_shader_parameter("weather_tree",Vector4(anchor.x,anchor.y,anchor.z,1))
			# Max clamped tree height gives < 3.1 m displacement in a gale.
			geometry.extra_cull_margin = maxf(geometry.extra_cull_margin,3.2)
		return
	for child in node.get_children(): _prepare_tree_wind(child)

func _exit_tree() -> void:
	# Do not leak storm/snow uniforms into another scene or an editor preview.
	if game == null: return
	for key in GLOBAL_NAMES:
		var setting: Dictionary = ProjectSettings.get_setting("shader_globals/"+key)
		RenderingServer.global_shader_parameter_set(key,setting.value)
