extends SceneTree
## Real-time mixer capture (Dummy output device, no microphone or system audio).
## Produces an audition WAV and verifies that the new paths emit actual PCM.
var game: Node
var capture := AudioEffectCapture.new()
var samples := PackedVector2Array()
var sections: Array[Dictionary] = []
var checks := 0
var failures := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", label)
func collect() -> void:
	var available := capture.get_frames_available()
	if available > 0:
		samples.append_array(capture.get_buffer(available))
func record_for(seconds: float) -> void:
	var until := Time.get_ticks_msec() + roundi(seconds * 1000)
	while Time.get_ticks_msec() < until:
		await process_frame
		collect()
func metric(start: int, label: String) -> Dictionary:
	var energy := 0.0
	var peak := 0.0
	for i in range(start, samples.size()):
		var frame := samples[i]
		energy += frame.length_squared()
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	var frames := samples.size() - start
	var rms := sqrt(energy / maxf(1, frames * 2))
	var result := {"section": label, "start_seconds": float(start) / AudioServer.get_mix_rate(),
		"seconds": float(frames) / AudioServer.get_mix_rate(), "rms_db": linear_to_db(maxf(.00000001, rms)), "peak": peak}
	sections.append(result)
	print("MIX ", JSON.stringify(result))
	return result
func bus_mute(bus: StringName, muted: bool) -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index(bus), muted)
func position_player(at: Vector3) -> void:
	game.player.global_position = game.reference_map.to_global(at)
	game.smooth_target = game.player.global_position
func run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.player.set_physics_process(false)
	game.sound.footsteps.set_physics_process(false)
	game.sound.muted = false
	# Finish the scene's initial physics registration before recording the mixer.
	for i in range(4):
		await physics_frame
		await process_frame
	capture.buffer_length = 4.0
	AudioServer.add_bus_effect(0, capture)
	for bus in [&"Music", &"Ambience", &"Weather", &"Effects"]: bus_mute(bus, true)
	await record_for(.2)
	for surface in [&"grass", &"stone", &"water", &"wood", &"dirt"]:
		var start := samples.size()
		for i in range(5):
			game.sound.play_footstep(surface, 1.0, i == 4)
			await record_for(.46)
		var m := metric(start, "footsteps_" + surface)
		check(m.rms_db > -45 and m.peak > .035, "%s footsteps emit audible PCM" % surface)
	for bus in [&"Music", &"Ambience", &"Weather", &"Effects"]: bus_mute(bus, false)
	position_player(Vector3(38, 2.2, 7))
	var start := samples.size()
	await record_for(5)
	var day := metric(start, "forest_day_music_birds")
	check(day.rms_db > -50, "daytime environment and exploration music reach the master bus")
	game.weather.set_time(2, true)
	start = samples.size()
	await record_for(4)
	var night := metric(start, "forest_night_crickets")
	check(night.rms_db > -52, "night ambience emits PCM")
	game.weather.set_time(0, true)
	position_player(Vector3(0, 2.2, -28))
	start = samples.size()
	await record_for(6.5)
	var village := metric(start, "enter_village_crossfade")
	check(village.rms_db > -50 and game.sound.world_audio.voices.village.playing, "village crossfade reaches its second music stream")
	position_player(Vector3(18, 2.2, 1.7))
	game.weather.set_weather(3, true)
	var event := InputEventKey.new()
	event.physical_keycode = KEY_0
	event.pressed = true
	Input.parse_input_event(event)
	start = samples.size()
	await record_for(4)
	var storm := metric(start, "bridge_water_storm_thunder")
	check(storm.rms_db > -45 and game.weather.thunder_count > 0, "water, storm and delayed thunder mix with music")
	# This stress case intentionally overlaps gameplay cues with weather/music.
	start = samples.size()
	for i in range(6):
		game.sound.play_footstep(&"water", 1.15, true)
		game.sound.play_tone("heavy")
		await record_for(.12)
	var overlap := metric(start, "overlap_headroom")
	check(overlap.peak <= db_to_linear(-1.0) + .002, "overlapping cues stay below the master limiter ceiling")
	game.sound.muted = true
	await record_for(.15)
	start = samples.size()
	await record_for(.4)
	var muted := metric(start, "muted")
	check(muted.seconds > .2 and muted.peak < .00001, "mute produces actual silence at the master bus")
	game.sound.muted = false
	paused = true
	await record_for(.15)
	start = samples.size()
	await record_for(.4)
	var stopped := metric(start, "paused")
	check(stopped.seconds > .2 and stopped.peak < .00001, "pause produces actual silence at the master bus")
	paused = false
	print("CAPTURE_DISCARDED_FRAMES ", capture.get_discarded_frames())
	check(capture.get_discarded_frames() == 0 and samples.size() > AudioServer.get_mix_rate() * 25, "capture contains the real mix without dropped buffers")
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 4)
	for i in range(samples.size()):
		bytes.encode_s16(i * 4, roundi(clampf(samples[i].x, -1, 1) * 32767))
		bytes.encode_s16(i * 4 + 2, roundi(clampf(samples[i].y, -1, 1) * 32767))
	var output := AudioStreamWAV.new()
	output.format = AudioStreamWAV.FORMAT_16_BITS
	output.mix_rate = roundi(AudioServer.get_mix_rate())
	output.stereo = true
	output.data = bytes
	var error := output.save_to_wav("res://docs/audio-preview.wav")
	check(error == OK, "audition recording saved")
	var report := FileAccess.open("res://docs/audio-mix.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"mix_rate": AudioServer.get_mix_rate(), "sections": sections}, "\t"))
	report.close()
	AudioServer.remove_bus_effect(0, AudioServer.get_bus_effect_count(0) - 1)
	game.queue_free()
	await process_frame
	OS.delay_msec(180)
	await process_frame
	print("AUDIO_MIX_RESULT ", checks - failures, "/", checks)
	quit(1 if failures else 0)
