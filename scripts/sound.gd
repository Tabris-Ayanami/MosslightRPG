extends Node
## Central mix and bounded one-shot pools. Music/ambience follow the player and weather.
signal footstep_played(surface: StringName, variant: int, landing: bool)
const Surfaces = preload("res://scripts/audio_surfaces.gd")
const Footsteps = preload("res://scripts/footsteps.gd")
const WorldAudio = preload("res://scripts/world_audio.gd")
const STEP_COUNTS := {&"grass": 6, &"stone": 6, &"water": 3, &"wood": 4, &"dirt": 2}
@export_group("Mix (dB)")
@export_range(-40, 0, .5) var master_volume_db := -2.0
@export_range(-40, 0, .5) var music_volume_db := -12.0
@export_range(-40, 0, .5) var ambience_volume_db := -7.0
@export_range(-40, 0, .5) var footsteps_volume_db := -2.0
@export_range(-40, 0, .5) var effects_volume_db := -9.0
@export_range(-40, 6, .5) var weather_volume_db := 2.0
var cache: Dictionary = {}
var voices: Array[AudioStreamPlayer] = []
var step_voices: Array[AudioStreamPlayer] = []
var step_streams: Dictionary = {}
var cloth: Array[AudioStream] = []
var slices: Array[AudioStream] = []
var surfaces: Node
var footsteps: Node
var world_audio: Node
var cursor := 0
var step_cursor := 0
var _random := RandomNumberGenerator.new()
var _previous_variants: Dictionary = {}
var muted := false:
	set(value):
		muted = value
		var bus := AudioServer.get_bus_index(&"Game")
		if bus >= 0:
			AudioServer.set_bus_mute(bus, value)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_random.randomize()
	apply_mix()
	for i in range(8):
		var voice := AudioStreamPlayer.new()
		voice.name = "Effect%d" % i
		voice.bus = &"Effects"
		add_child(voice)
		voices.append(voice)
	for i in range(6):
		var voice := AudioStreamPlayer.new()
		voice.name = "Footstep%d" % i
		voice.bus = &"Footsteps"
		add_child(voice)
		step_voices.append(voice)
	for surface: StringName in STEP_COUNTS:
		var streams: Array[AudioStream] = []
		for i in range(STEP_COUNTS[surface]):
			streams.append(load("res://assets/audio/footsteps/%s_%02d.wav" % [surface, i + 1]))
		step_streams[surface] = streams
	for i in range(4):
		cloth.append(load("res://assets/audio/effects/cloth%d.wav" % (i + 1)))
	slices.assign([preload("res://assets/audio/effects/knifeSlice.wav"), preload("res://assets/audio/effects/knifeSlice2.wav")])

func setup(game: Node) -> void:
	surfaces = Surfaces.new()
	surfaces.name = "SurfaceDetector"
	add_child(surfaces)
	surfaces.setup(game.reference_map)
	footsteps = Footsteps.new()
	footsteps.name = "Footsteps"
	add_child(footsteps)
	footsteps.setup(game.player, self, surfaces)
	world_audio = WorldAudio.new()
	world_audio.name = "WorldAudio"
	add_child(world_audio)
	world_audio.setup(game, surfaces)

func apply_mix() -> void:
	var mix := {&"Game": master_volume_db, &"Music": music_volume_db, &"Ambience": ambience_volume_db,
		&"Footsteps": footsteps_volume_db, &"Effects": effects_volume_db, &"Weather": weather_volume_db}
	for bus_name: StringName in mix:
		var index := AudioServer.get_bus_index(bus_name)
		assert(index >= 0, "Missing audio bus: " + bus_name)
		AudioServer.set_bus_volume_db(index, mix[bus_name])
	muted = muted
	preload("res://rpg/game_preferences.gd").apply_audio_preferences(mix)

func reset_footsteps() -> void:
	if is_instance_valid(footsteps):
		footsteps.reset()

func play_footstep(surface: StringName, strength := 1.0, landing := false) -> void:
	if muted or get_tree().paused or step_voices.is_empty():
		return
	if not step_streams.has(surface):
		surface = &"grass"
	var streams: Array = step_streams[surface]
	var index := _variant(surface, streams.size())
	var voice := step_voices[step_cursor % step_voices.size()]
	step_cursor += 1
	voice.stream = streams[index]
	voice.pitch_scale = _random.randf_range(.95, 1.05) * (.86 if landing else 1.0)
	voice.volume_db = linear_to_db(maxf(.1, strength)) + _random.randf_range(-1.0, .6) + (2.0 if landing else 0.0)
	voice.play()
	footstep_played.emit(surface, index, landing)

func _variant(group: StringName, count: int) -> int:
	var previous: int = _previous_variants.get(group, -1)
	var index := _random.randi_range(0, count - 2) if previous >= 0 and count > 1 else _random.randi_range(0, count - 1)
	if previous >= 0 and count > 1 and index >= previous:
		index += 1
	_previous_variants[group] = index
	return index

func play_tone(kind: String) -> void:
	if muted or get_tree().paused or voices.is_empty() or not preload("res://combat/impact_feedback.gd").sound_enabled:
		return
	var voice := voices[cursor % voices.size()]
	cursor += 1
	voice.pitch_scale = 1.0
	voice.volume_db = 0.0
	if kind in ["roll", "jump"]:
		voice.stream = cloth[_variant(&"cloth", cloth.size())]
		voice.pitch_scale = .85 if kind == "roll" else 1.08
	elif kind in ["sword", "heavy"]:
		voice.stream = slices[_variant(&"slices", slices.size())]
		voice.pitch_scale = .72 if kind == "heavy" else _random.randf_range(.95, 1.08)
		voice.volume_db = 2.0 if kind == "heavy" else 0.0
	else:
		if not cache.has(kind):
			cache[kind] = _make_tone(kind)
		voice.stream = cache[kind]
		voice.volume_db = -9.0
	voice.play()

func _exit_tree() -> void:
	for voice in voices + step_voices:
		voice.stop()
		voice.stream = null

func _make_tone(kind: String) -> AudioStreamWAV:
	var settings: Array = {
		"sword": [450.0, 100.0, 0.13, 0.50], "heavy": [210.0, 50.0, 0.25, 0.5],
		"bow": [850.0, 210.0, 0.15, 0.17], "hit": [280.0, 70.0, 0.09, 0.5],
		"hurt": [190.0, 80.0, 0.24, 0.15], "roll": [240.0, 90.0, 0.18, 0.6],
		"jump": [250.0, 600.0, 0.15, 0.03], "charge": [650.0, 1150.0, 0.18, 0.01],
		"skill": [540.0, 140.0, 0.35, 0.28], "heal": [480.0, 1100.0, 0.5, 0.0],
		"chest": [720.0, 1400.0, 0.38, 0.0]
		,"impact_flesh": [180.0, 48.0, .105, .62], "impact_finish": [125.0, 30.0, .18, .55],
		"impact_guard": [1250.0, 480.0, .14, .3]
	}.get(kind, [440.0, 440.0, 0.12, 0.0])
	var count := int(22050 * settings[2])
	var data := PackedByteArray()
	data.resize(count * 2)
	var phase := 0.0
	var random := RandomNumberGenerator.new()
	random.seed = 42
	for i in range(count):
		var t := float(i) / count
		phase += lerpf(settings[0], settings[1], t) * TAU / 22050.0
		var sample: float = (sin(phase) * (1.0 - settings[3]) + random.randf_range(-1, 1) * settings[3]) * pow(1.0 - t, 2) * minf(t * 40, 1)
		data.encode_s16(i * 2, int(sample * 16000))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 22050
	stream.data = data
	return stream
