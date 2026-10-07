extends Node
## Procedural ambience: no downloaded recordings or extra runtime dependencies.
var rain_voice: AudioStreamPlayer
var wind_voice: AudioStreamPlayer
var thunder_voice: AudioStreamPlayer

func _ready() -> void:
	for kind in ["rain", "wind", "thunder"]:
		var voice := AudioStreamPlayer.new()
		voice.name = kind.capitalize()
		voice.bus = &"Weather"
		voice.stream = synthesize(kind)
		voice.volume_db = -60
		add_child(voice)
		if kind == "rain": rain_voice = voice
		elif kind == "wind": wind_voice = voice
		else: thunder_voice = voice

func set_levels(rain: float, wind: float, muted: bool) -> void:
	_sync_loop(rain_voice,not muted and rain>=.005)
	_sync_loop(wind_voice,not muted)
	if muted: thunder_voice.stop()
	rain_voice.volume_db = linear_to_db(maxf(.001, rain)) - 19.0
	wind_voice.volume_db = lerpf(-37.0, -20.0, clampf((wind-1.0)/6.0,0,1))

func _sync_loop(voice: AudioStreamPlayer, active: bool) -> void:
	if active and not voice.playing: voice.play()
	elif not active and voice.playing: voice.stop()

func _exit_tree() -> void:
	for voice in [rain_voice,wind_voice,thunder_voice]:
		if is_instance_valid(voice):
			voice.stop()
			voice.stream = null

func thunder(muted: bool) -> void:
	if muted: return
	thunder_voice.volume_db = -12
	thunder_voice.play()

static func synthesize(kind: String) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9107 if kind == "rain" else 5039
	var rate := 16000
	var seconds := 4.4 if kind == "thunder" else 6.0
	var count := int(rate*seconds)
	var bytes := PackedByteArray()
	bytes.resize(count*2)
	var low := 0.0
	var mid := 0.0
	for i in range(count):
		var t := float(i)/rate
		var white := rng.randf_range(-1,1)
		low = lerpf(low,white,.024)
		mid = lerpf(mid,white,.16)
		var sample: float
		if kind == "rain":
			sample = (white*.16+mid*.6)*(0.82+sin(t*TAU/seconds)*.18)
		elif kind == "wind":
			sample = (low*3.0+mid*.18)*(.62+.25*sin(t*TAU/seconds))
		else:
			var envelope := (1.0-exp(-t*18.0))*exp(-t*.85)
			sample = (low*3.0+mid*.28+sin(t*TAU*41.0)*.1)*envelope
		# Seamless silent join at the loop boundary, and no clicks in the thunder.
		var fade := minf(1.0,minf(t,seconds-t)*12.0)
		bytes.encode_s16(i*2,int(clampf(sample*fade,-.9,.9)*32767))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = bytes
	if kind != "thunder":
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = count
	return stream
