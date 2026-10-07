extends SceneTree
## Actual map queries, character motion and audio state; the PCM mix is checked separately.
var game: Node
var checks := 0
var failures: Array[String] = []
var contacts: Array[Dictionary] = []
var played: Array[Dictionary] = []
var sound: Node
const TEST_ORIGIN := Vector3(120, 5, 110)

func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await ticks(1)
	event.pressed = false
	Input.parse_input_event(event)
	await ticks(1)
func point(local: Vector3) -> Vector3: return game.reference_map.to_global(local)
func surface_at(local: Vector3) -> StringName: return sound.surfaces.surface_at(point(local))
func place(at: Vector3) -> void:
	game._release_actions()
	game.player.restore(at + Vector3.UP * .08)
	await ticks(16)
	contacts.clear()
func move(direction: Vector3) -> void:
	game._release_actions()
	var x: float = direction.dot(game.camera_right())
	var z: float = direction.dot(game.camera_forward())
	Input.action_press("move_right" if x >= 0 else "move_left", absf(x))
	Input.action_press("move_up" if z >= 0 else "move_down", absf(z))
func body(at: Vector3, size: Vector3) -> StaticBody3D:
	var collider := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	collider.add_child(shape)
	collider.position = at
	collider.set_meta(&"footstep_surface", &"stone")
	game.world.add_child(collider)
	return collider
func run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	sound = game.sound
	sound.footsteps.foot_contact.connect(func(s: StringName, landing: bool): contacts.append({"surface": s, "landing": landing}))
	sound.footstep_played.connect(func(s: StringName, variant: int, landing: bool): played.append({"surface": s, "variant": variant, "landing": landing}))
	await ticks(12)
	check(surface_at(Vector3(-6, 2.2, 5)) == &"grass", "bare garden turf selects grass")
	check(surface_at(Vector3(2.5, 2.2, 5)) == &"stone", "thin visible shrine slab selects stone over terrain collider")
	check(surface_at(Vector3(0, 2.2, -40)) == &"dirt", "village square selects exposed soil between the slabs")
	var flagstone: MeshInstance3D = game.reference_map.get_node("RoadFlagstones").get_child(0)
	var contact := flagstone.global_position + Vector3.UP * .07
	check(sound.surfaces.surface_at(contact) == &"stone", "separate road slabs select stone over the dirt beneath")
	check(surface_at(Vector3(31, 2.2, -1)) == &"dirt", "visible woodland path selects dirt")
	check(surface_at(Vector3(18, 2.2, 1.7)) == &"wood" and surface_at(Vector3(0, 2.2, -17)) == &"wood", "both bridge decks remain wood above water")
	check(surface_at(Vector3(2.5, .263, 10.8)) == &"water", "submerged shore contact selects splash")
	check(surface_at(Vector3(2.5, .74, 10.34)) == &"stone", "dry shore stair above water remains stone")
	check(sound.surfaces.water_distance(point(Vector3(18, 2.2, 1.7))) == 0 and sound.surfaces.water_distance(point(Vector3(0, 2.2, -40))) > 14, "shore probes hear water below bridge and fade inland")
	var query_only := true
	for node in game.reference_map.find_children("AudioFootprint", "StaticBody3D", true, false):
		query_only = query_only and node.collision_layer == 1024 and node.collision_mask == 0 and (game.player.collision_mask & node.collision_layer) == 0
	check(query_only and sound.surfaces.query_body_count > 0, "auditory footprints cannot block movement, projectiles or shadow rays")
	var streams_valid := true
	for streams: Array in sound.step_streams.values():
		for stream: AudioStream in streams:
			streams_valid = streams_valid and stream != null and stream.get_length() > .04 and stream.get_length() < 1.5
	check(streams_valid and sound.step_streams.size() == 5, "all five surface sample banks load")
	check(AudioServer.bus_count == 7 and not game.hud.visible, "separate mix buses; no new HUD")
	# Controlled floor/wall use real CharacterBody3D and the unchanged movement code.
	var floor_body := body(TEST_ORIGIN - Vector3.UP * .2, Vector3(24, .4, 40))
	var wall := body(TEST_ORIGIN + Vector3(3, 1, 0), Vector3(.4, 2, 12))
	await place(TEST_ORIGIN)
	await ticks(45)
	check(contacts.is_empty(), "idle and initial spawn are silent")
	move(Vector3.FORWARD)
	await ticks(120)
	var normal_count := contacts.size()
	check(normal_count >= 5 and normal_count <= 8, "distance cadence produces five to eight contacts over two seconds")
	game._release_actions()
	await ticks(12)
	contacts.clear()
	await ticks(45)
	check(contacts.is_empty(), "stopping leaves no scheduled extra steps")
	await place(TEST_ORIGIN)
	move(Vector3.FORWARD)
	await ticks(1)
	Input.action_press("sword")
	await ticks(120)
	print("CADENCE_CONTACTS normal=", normal_count, " charging=", contacts.size(), " held=",game.player.charge_kind)
	check(contacts.size() >= 2 and contacts.size() <= 4 and contacts.size() < normal_count, "charge slowdown naturally lowers footstep cadence")
	await place(TEST_ORIGIN)
	move(Vector3.RIGHT)
	await ticks(80)
	contacts.clear()
	await ticks(90)
	check(contacts.is_empty(), "holding movement against a wall emits no footsteps")
	await place(TEST_ORIGIN)
	Input.action_press("jump")
	await ticks(2)
	Input.action_release("jump")
	contacts.clear()
	await ticks(28)
	check(contacts.is_empty() and not game.player.is_on_floor(), "jump flight has no grounded footsteps")
	await ticks(50)
	check(contacts.size() == 1 and contacts[0].landing, "jump landing produces exactly one weighted contact")
	await place(TEST_ORIGIN)
	move(Vector3.FORWARD)
	Input.action_press("roll")
	await ticks(2)
	Input.action_release("roll")
	contacts.clear()
	await ticks(16)
	check(contacts.is_empty() and game.player.roll_left > 0, "roll uses cloth without running footsteps")
	await place(TEST_ORIGIN)
	game.player.aim = Vector3.FORWARD
	game.player.cast_skill("e")
	await ticks(8)
	check(contacts.is_empty(), "blink movement does not accumulate false steps")
	game.player.restore(TEST_ORIGIN + Vector3.UP * 2)
	await ticks(60)
	check(contacts.is_empty(), "respawn resets contact history and suppresses phantom landing")
	# A shallow band shorter than the stride must still produce an entry splash.
	await place(point(Vector3(2.5, .82, 10.20)))
	move(Vector3.BACK)
	await ticks(13)
	game._release_actions()
	check(contacts.any(func(c: Dictionary): return c.surface == &"water"), "walking down shore steps splashes on entering shallow water")
	# Playback selection, channel controls, time and area changes.
	await place(TEST_ORIGIN)
	sound.muted = false
	await ticks(5)
	played.clear()
	for i in range(18): sound.play_footstep(&"grass")
	var varied := played.size() == 18
	for i in range(1, played.size()): varied = varied and played[i].variant != played[i - 1].variant
	check(varied and sound.step_voices.size() == 6, "sample variants avoid adjacent repetition with a bounded voice pool")
	check(sound.step_voices[0].bus == &"Footsteps" and sound.voices[0].bus == &"Effects" and game.weather.ambience.wind_voice.bus == &"Weather", "all one-shots and weather use their intended buses")
	sound.play_tone("roll")
	check(sound.voices[(sound.cursor - 1) % 8].stream in sound.cloth, "roll uses recorded cloth foley")
	var world: Node = sound.world_audio
	await ticks(200)
	check(world.voices.exploration.playing and world.levels.exploration > .95 and world.levels.village == 0, "exploration BGM fades in and loops")
	var all_loops := true
	for voice: AudioStreamPlayer in world.voices.values(): all_loops = all_loops and voice.stream.loop
	check(all_loops, "all music and ambience are configured to loop")
	var music_id: int = world.voices.exploration.get_stream_playback().get_instance_id()
	await key(KEY_M)
	check(sound.muted and AudioServer.is_bus_mute(AudioServer.get_bus_index(&"Game")) and world.voices.exploration.playing, "M silences the entire mix while retaining the music playback")
	await key(KEY_M)
	check(not sound.muted and world.voices.exploration.get_stream_playback().get_instance_id() == music_id, "unmute keeps the same BGM stream rather than restarting")
	await key(KEY_ESCAPE)
	var frozen: float = world._fade_in
	check(world.voices.exploration.stream_paused and game.weather.ambience.wind_voice.stream_paused, "Esc pauses music and weather streams")
	await ticks(10)
	check(world._fade_in == frozen, "pause also freezes audio transitions")
	await key(KEY_ESCAPE)
	check(not world.voices.exploration.stream_paused, "resume unpauses the music")
	await place(point(Vector3(38, 2.2, 7)))
	await ticks(240)
	var day_birds: float = world.levels.birds
	game.weather.set_time(2, true)
	await ticks(240)
	check(world.levels.birds < day_birds * .02 and world.levels.crickets > .3 and world.levels.exploration < .75, "night fades birds into crickets and lowers music")
	game.weather.set_time(0, true)
	game.weather.set_weather(3, true)
	await ticks(240)
	check(world.levels.birds < day_birds * .03, "storm ducks wildlife instead of covering rain with loud birds")
	game.weather.set_weather(0, true)
	game.weather.set_wind(0, true)
	await ticks(240)
	var prior_music: float = world.levels.exploration
	game.weather.thunder_sounded.emit()
	await ticks(1)
	check(world.levels.exploration < prior_music * .7, "thunder briefly leaves room in the music mix")
	await place(point(Vector3(0, 2.2, -28)))
	await ticks(110)
	check(world.region == &"village" and world.levels.village > 0 and world.levels.exploration > 0, "village entrance crossfades both tracks")
	await ticks(260)
	check(world.levels.village > .95 and world.levels.exploration == 0 and not world.voices.exploration.playing, "village transition completes and releases silent track")
	await place(point(Vector3(0, 2.2, -25.5)))
	await ticks(120)
	check(world.region == &"village", "border hysteresis avoids repeatedly switching music")
	game.queue_free()
	await ticks(4)
	OS.delay_msec(160) # Allow the audio mix thread to retire its stopped playbacks.
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(5)
	check(AudioServer.bus_count == 7 and game.sound.world_audio.region == &"exploration", "reload has no duplicate buses or stale village state")
	game.queue_free()
	await ticks(4)
	OS.delay_msec(160)
	print("AUDIO_TEST_RESULT ", checks - failures.size(), "/", checks)
	quit(0 if failures.is_empty() else 1)
