extends Node
## Player-centred ambience beds and a debounced exploration/village music crossfade.
const LOOPS := {
	"birds": preload("res://assets/audio/ambience/birds.ogg"),
	"crickets": preload("res://assets/audio/ambience/crickets.ogg"),
	"water": preload("res://assets/audio/ambience/water.ogg"),
	"exploration": preload("res://assets/audio/music/exploration.ogg"),
	"village": preload("res://assets/audio/music/village.ogg")
}
var game: Node
var surfaces: Node
var voices: Dictionary = {}
var levels := {"birds": 0.0, "crickets": 0.0, "water": 0.0, "exploration": 0.0, "village": 0.0}
var region := &"exploration"
var _candidate := &"exploration"
var _candidate_time := 0.0
var _village_blend := 0.0
var _fade_in := 0.0
var _water_distance := 24.0
var _water_probe_timer := 0.0
var _thunder_duck := 0.0

func setup(owner_game: Node, detector: Node) -> void:
	game = owner_game
	surfaces = detector
	for kind: String in LOOPS:
		var voice := AudioStreamPlayer.new()
		voice.name = kind.capitalize()
		var stream: AudioStreamOggVorbis = LOOPS[kind].duplicate()
		stream.loop = true
		voice.stream = stream
		voice.bus = &"Music" if kind in ["exploration", "village"] else &"Ambience"
		voice.volume_db = -80
		add_child(voice)
		voices[kind] = voice
	game.weather.thunder_sounded.connect(_on_thunder)

func _on_thunder() -> void:
	_thunder_duck = 1.0

func _process(delta: float) -> void:
	if game == null:
		return
	var at: Vector3 = game.reference_map.to_local(game.player.global_position)
	var desired := region
	if at.z < -27 and absf(at.x) < 23:
		desired = &"village"
	elif at.z > -24 or absf(at.x) > 26:
		desired = &"exploration"
	if desired != _candidate:
		_candidate = desired
		_candidate_time = 0
	_candidate_time += delta
	if _candidate_time >= 1.2:
		region = _candidate
	_village_blend = move_toward(_village_blend, 1.0 if region == &"village" else 0.0, delta / 4.0)
	_fade_in = move_toward(_fade_in, 1.0, delta / 3.0)
	_thunder_duck = move_toward(_thunder_duck, 0.0, delta / 3.5)
	_water_probe_timer -= delta
	if _water_probe_timer <= 0:
		_water_probe_timer = .4
		_water_distance = surfaces.water_distance(game.player.global_position)
	var weather: Node = game.weather
	var daylight := smoothstep(-.2, .35, cos((weather.hour - 12.0) * PI / 12.0))
	var storm := clampf((weather.wind_strength - 1.0) / 6.0, 0, 1)
	var wildlife: float = (1.0 - weather.rain_amount * .92) * (1.0 - storm * .8) * (1.0 - weather.snowfall * .9)
	var forest := smoothstep(18, 31, at.x)
	_set_level("birds", (.38 + forest * .32) * daylight * wildlife, delta)
	_set_level("crickets", .43 * (1.0 - daylight) * wildlife * (1.0 - weather.snow_cover * .85), delta)
	_set_level("water", .40 * exp(-_water_distance * .22) * (1.0 - weather.rain_amount * .65), delta)
	var music_gain: float = _fade_in * lerpf(.68, 1.0, daylight) * (1.0 - weather.rain_amount * .25) * (1.0 - _thunder_duck * .42)
	_set_level("exploration", sqrt(1.0 - _village_blend) * music_gain, delta, true)
	_set_level("village", sqrt(_village_blend) * music_gain, delta, true)

func _set_level(kind: String, target: float, delta: float, music := false) -> void:
	# Music already has a four-second fade; ambience needs smoothing of shore probes.
	levels[kind] = target if music else lerpf(levels[kind], target, 1.0 - exp(-delta * 1.4))
	var voice: AudioStreamPlayer = voices[kind]
	voice.volume_db = linear_to_db(maxf(.0001, levels[kind]))
	# Muting an active loop preserves its phase. A silent headless scene does not
	# start decoders unnecessarily; unmuting starts the currently audible layers.
	if levels[kind] > .0001 and not voice.playing and not game.sound.muted:
		voice.play()
	elif levels[kind] <= .0001 and voice.playing:
		voice.stop()

func _exit_tree() -> void:
	for voice: AudioStreamPlayer in voices.values():
		voice.stop()
		voice.stream = null
