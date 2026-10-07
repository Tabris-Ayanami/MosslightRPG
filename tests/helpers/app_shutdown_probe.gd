extends "res://scripts/frontend/app.gd"
## Controller-only fixture. Real quit/audio code is inherited; no real world is loaded.

class PanelProbe extends Control:
	var panel := ""
	var save_note := ""
	var opened: Array[String] = []
	func show_panel(value: String) -> void:
		panel = value
		opened.append(value)

class WorldProbe extends Node:
	var events: Array[String] = []
	var modal_open := true
	var close_calls := 0
	func close_world_modal() -> void:
		close_calls += 1
		modal_open = false
		events.append("close_modal")

class LoopProducer extends Node:
	var voices: Array[Node] = []
	var source: AudioStream
	var frames := 0
	var restarts := 0
	var restart_events: Array[Dictionary] = []
	var paused_inactive_observations: Dictionary = {}
	func _process(_delta: float) -> void:
		frames += 1
		for voice: Node in voices:
			# A deliberately paused loop is not a stopped loop to replenish. Keep
			# evidence of the old false-positive condition for the process runner.
			if voice.stream_paused:
				if not voice.playing:
					paused_inactive_observations[voice.name] = int(paused_inactive_observations.get(voice.name, 0)) + 1
				continue
			if not voice.playing:
				restarts += 1
				restart_events.append({"voice": str(voice.name), "frame": frames, "playing": voice.playing,
					"stream_paused": voice.stream_paused, "has_playback": voice.has_stream_playback()})
				voice.stream = source
				voice.play()

var save_success := true
var save_calls := 0
var events: Array[String] = []
var voices: Array[Node] = []
var producer: LoopProducer
var report_exit: Callable

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().auto_accept_quit = false
	# The presentation graph is deliberately absent. Tests exercise its controller
	# contracts with real players, rather than claiming a full gameplay/UI flow.
	set_process(false)
	set_process_input(false)
	ui = PanelProbe.new()
	ui.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(ui)
	game = WorldProbe.new()
	game.name = "ControllerWorldFixture"
	game.events = events
	add_child(game)
	producer = LoopProducer.new()
	producer.process_mode = Node.PROCESS_MODE_ALWAYS
	game.add_child(producer)

func add_audio() -> void:
	var wave := AudioStreamWAV.new()
	wave.format = AudioStreamWAV.FORMAT_8_BITS
	wave.mix_rate = 22050
	wave.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wave.loop_end = 4410
	var samples := PackedByteArray()
	samples.resize(4410)
	samples.fill(128)
	wave.data = samples
	producer.source = wave
	# The inactive fourth player catches stream references that were never played.
	voices = [AudioStreamPlayer.new(), AudioStreamPlayer2D.new(), AudioStreamPlayer3D.new(), AudioStreamPlayer.new()]
	for index in range(voices.size()):
		var voice: Node = voices[index]
		voice.name = "ShutdownVoice%d" % index
		voice.stream = wave
		voice.volume_db = -80.0
		producer.add_child(voice)
		if index < 3:
			producer.voices.append(voice)
			voice.play()
	music = voices[0] as AudioStreamPlayer

func save_adventure() -> bool:
	save_calls += 1
	events.append("save")
	return save_success

func audio_state() -> Array[Dictionary]:
	var state: Array[Dictionary] = []
	for voice: Node in voices:
		state.append({
			"voice": str(voice.name), "playing": voice.playing, "stream_paused": voice.stream_paused,
			"has_playback": voice.has_stream_playback(),
			"playback_id": voice.get_stream_playback().get_instance_id() if voice.has_stream_playback() else 0,
			"stream_id": voice.stream.get_instance_id() if voice.stream != null else 0,
		})
	return state

func _exit_tree() -> void:
	# Capture the state before the inherited emergency teardown can mask a missing
	# shutdown step. Children have exited the tree but remain valid during this hook.
	var streams_cleared := true
	var voices_stopped := true
	for voice: Node in voices:
		streams_cleared = streams_cleared and voice.stream == null
		voices_stopped = voices_stopped and not voice.playing
	var disabled := true
	var nodes: Array[Node] = [self]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		disabled = disabled and node.process_mode == Node.PROCESS_MODE_DISABLED
		nodes.append_array(node.get_children())
	var snapshot := {
		"quitting": _quitting, "save_calls": save_calls,
		"events": events.duplicate(), "stage": stage,
		"all_nodes_disabled": disabled,
		"streams_cleared": streams_cleared, "voices_stopped": voices_stopped,
		"producer_frames": producer.frames, "producer_restarts": producer.restarts,
		"restart_events": producer.restart_events.duplicate(true),
		"paused_inactive_observations": producer.paused_inactive_observations.duplicate(),
		"settings_requests": ui.opened.size(), "modal_close_calls": game.close_calls,
		"title_scene_absent": title_view == null,
	}
	super._exit_tree()
	snapshot["auto_accept_restored"] = get_tree().auto_accept_quit
	if report_exit.is_valid(): report_exit.call(snapshot)
