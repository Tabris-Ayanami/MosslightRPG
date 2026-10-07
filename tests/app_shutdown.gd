extends SceneTree
## Run one case per real process. APP_SHUTDOWN_RESULT is emitted during teardown.
## This is a controller/audio contract fixture, not a gameplay persistence test.
const Probe = preload("res://tests/helpers/app_shutdown_probe.gd")
const Repository = preload("res://rpg/save_repository.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
const CASES := ["save_failure", "title", "playing", "paused", "silent", "timeout", "loading"]
var case_name := ""
var directory := ""
var app: Node
var checks := 0
var failures: Array[String] = []
var playback_refs: Array[WeakRef] = []
var held_playbacks: Array[AudioStreamPlayback] = []
var request_started_usec := 0
var request_frame := 0
var producer_frames_at_request := 0
var producer_restarts_at_request := 0
var initial_stage := 0
var expected_save_calls := 0
var forced_exit := false
var observed_exit := false
var completed_failure_checks := false
var temp_created_here := false
var audio_observations: Dictionary = {}
var loading_callbacks_checked := false

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--case="): case_name = arg.trim_prefix("--case=")
		if arg.begins_with("--directory="): directory = arg.trim_prefix("--directory=")
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func frames(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame

func run() -> void:
	if case_name not in CASES:
		printerr("FAIL supply --case=" + "|".join(CASES))
		quit(80)
		return
	var temp_root := OS.get_temp_dir().replace("\\", "/").simplify_path()
	if directory.is_empty():
		directory = temp_root.path_join("mosslight-shutdown-%s-%d-%d" % [case_name, OS.get_process_id(), Time.get_ticks_usec()])
		temp_created_here = true
	directory = directory.replace("\\", "/").simplify_path()
	# Caller-provided locations must also stay in this test's OS-temp namespace.
	if not directory.to_lower().begins_with((temp_root + "/mosslight-shutdown-").to_lower()):
		printerr("FAIL shutdown fixture requires its own OS-temp directory")
		quit(81)
		return
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		printerr("FAIL cannot create shutdown fixture directory")
		quit(82)
		return
	Preferences.settings_path = directory.path_join("preferences.cfg")
	app = Probe.new()
	app.saves = Repository.new(directory.path_join("adventures"))
	app.report_exit = _on_app_exit
	app.save_success = case_name != "save_failure"
	root.add_child(app)
	current_scene = app
	app.stage = app.Stage.TITLE if case_name in ["title", "silent"] else app.Stage.PLAYING
	if case_name == "loading": app.stage = app.Stage.LOADING
	initial_stage = app.stage
	expected_save_calls = 1 if initial_stage == app.Stage.PLAYING else 0
	if case_name != "silent": app.add_audio()
	await frames(4)
	check(not auto_accept_quit, "controller owns the OS close request")
	check(app.producer.frames > 0, "explicit ALWAYS producer actually runs before shutdown")
	if case_name != "silent":
		for index in range(3):
			var voice: Node = app.voices[index]
			check(voice.has_stream_playback(), "real player %d has an active playback" % index)
			if voice.has_stream_playback(): playback_refs.append(weakref(voice.get_stream_playback()))
		app.voices[2].stream_paused = true
		check(app.voices[2].stream_paused, "3D voice is independently paused before shutdown")
	if case_name in ["timeout", "loading"] and app.voices[0].has_stream_playback():
		# Loading releases this after one frame and its late callbacks; timeout
		# deliberately retains it until teardown to exercise the bounded fallback.
		held_playbacks.append(app.voices[0].get_stream_playback())
	if case_name == "paused":
		paused = true
		var before: int = app.producer.frames
		await frames(2)
		check(paused and app.producer.frames > before, "ALWAYS producer runs even while SceneTree is paused")
	# Title's exit button must have no effect outside TITLE.
	if initial_stage != app.Stage.TITLE:
		app._quit_game()
		check(not app._quitting and app.save_calls == 0, "title exit action is ignored outside TITLE")
	if not failures.is_empty():
		forced_exit = true
		quit(83)
		return
	producer_frames_at_request = app.producer.frames
	producer_restarts_at_request = app.producer.restarts
	audio_observations["before_request"] = app.audio_state()
	print("APP_SHUTDOWN_AUDIO before_request " + JSON.stringify(audio_observations.before_request))
	request_started_usec = Time.get_ticks_usec()
	request_frame = Engine.get_process_frames()
	_watchdog()
	if case_name in ["title", "silent"]: app._quit_game()
	else: root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	if case_name == "save_failure":
		await _verify_save_failure()
		return
	check(app._quitting, "successful request locks controller immediately")
	check(app.process_mode == Node.PROCESS_MODE_DISABLED and app.producer.process_mode == Node.PROCESS_MODE_DISABLED,
		"shutdown disables the controller and explicit ALWAYS producer before yielding")
	for voice: Node in app.voices:
		check(not voice.playing and voice.stream == null, "shutdown stops and detaches " + voice.name)
	# Directly delivered callbacks can still run on disabled nodes. Repeated close,
	# title and journey callbacks therefore need their own controller guards.
	root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	app._quit_game()
	app.show_title()
	app.start_adventure()
	app.new_adventure()
	check(app.stage == initial_stage and app.title_view == null,
		"repeated close, title and journey callbacks cannot resurrect presentation")
	check(app.save_calls == expected_save_calls, "accepted shutdown saves at most once and only during PLAYING")
	if case_name == "loading": await _verify_loading_callbacks()

func _verify_loading_callbacks() -> void:
	var original_game: Node = app.game
	var original_children: int = app.get_child_count()
	# Keep one playback alive for this frame so these are deterministically late
	# callbacks during the inherited drain, not just calls after quit was queued.
	await process_frame
	check(app._quitting and held_playbacks.size() == 1 and _live_playbacks() > 0,
		"loading callbacks are delivered while a real playback is still draining")
	app._enter_world(PackedScene.new())
	app._finish_arrival()
	app._confirm_choice("new", "Late loading fixture")
	check(app.stage == app.Stage.LOADING and app.game == original_game and not original_game.is_queued_for_deletion()
		and app.get_child_count() == original_children,
		"late world-load and arrival callbacks neither replace the controller fixture nor add a world")
	check(app.save_calls == 0 and app.selected_save == -1 and app.pending_snapshot.is_empty(),
		"LOADING close and late choice callback do not save or create an adventure")
	check(app.producer.frames == producer_frames_at_request and app.producer.restarts == producer_restarts_at_request,
		"late loading callbacks cannot reactivate the ALWAYS audio producer")
	loading_callbacks_checked = true
	held_playbacks.clear()

func _verify_save_failure() -> void:
	audio_observations["failure_immediate"] = app.audio_state()
	print("APP_SHUTDOWN_AUDIO failure_immediate " + JSON.stringify(audio_observations.failure_immediate))
	check(not app._quitting, "failed save does not enter quitting state")
	check(app.stage == app.Stage.PLAYING and app.game.modal_open and app.game.close_calls == 0,
		"failed save preserves the world and its modal")
	check(app.ui.panel == "settings" and app.ui.opened.size() == 1, "failed save requests the settings panel")
	check(app.process_mode == Node.PROCESS_MODE_ALWAYS and app.ui.process_mode == Node.PROCESS_MODE_ALWAYS,
		"failed save leaves controller and UI processing enabled")
	for voice: Node in app.voices:
		check(voice.stream != null, "failed save keeps stream on " + voice.name)
	check(app.voices[0].playing and app.voices[1].playing, "failed save leaves existing active audio playing")
	await frames(4)
	audio_observations["failure_after_frames"] = app.audio_state()
	print("APP_SHUTDOWN_AUDIO failure_after_frames " + JSON.stringify(audio_observations.failure_after_frames))
	check(app.producer.frames > producer_frames_at_request and app.producer.restarts == producer_restarts_at_request,
		"failed save leaves the explicit ALWAYS producer active without restarting audio")
	for index in range(3):
		var before: Dictionary = audio_observations.before_request[index]
		var after: Dictionary = audio_observations.failure_after_frames[index]
		check(after.has_playback and after.playback_id == before.playback_id and after.stream_id == before.stream_id,
			"failed save preserves original playback and stream identity for " + after.voice)
	check(app.voices[2].stream_paused, "failed save preserves the independently paused 3D loop")
	check(app.save_calls == 1 and app.events == ["save"], "failed save stops before modal closure or teardown")
	completed_failure_checks = true
	# End this intentionally non-quitting case through fixture cleanup. Do not
	# invoke the production success path or turn this into a second-save test.
	app.producer.set_process(false)
	for voice: Node in app.voices:
		voice.stop()
		voice.stream = null
	var deadline := Time.get_ticks_msec() + 1500
	while _live_playbacks() > 0 and Time.get_ticks_msec() < deadline: await process_frame
	quit(0 if failures.is_empty() else 1)

func _live_playbacks() -> int:
	var count := 0
	for reference: WeakRef in playback_refs:
		if reference.get_ref() != null: count += 1
	return count

func _watchdog() -> void:
	await create_timer(4.0, true, false, true).timeout
	if observed_exit: return
	forced_exit = true
	check(false, "real process quit completes within four seconds")
	quit(84)

func _on_app_exit(snapshot: Dictionary) -> void:
	observed_exit = true
	var elapsed_ms := (Time.get_ticks_usec() - request_started_usec) / 1000.0 if request_started_usec > 0 else 0.0
	var live_playbacks := _live_playbacks()
	check(not forced_exit, "controller reached real SceneTree teardown without watchdog intervention")
	if case_name == "save_failure":
		check(completed_failure_checks and not snapshot.quitting and snapshot.save_calls == 1,
			"failed-save fixture survived to its own explicit completion")
	else:
		check(snapshot.quitting and snapshot.all_nodes_disabled, "every descendant stays disabled through actual teardown")
		check(snapshot.streams_cleared and snapshot.voices_stopped, "all player kinds remain stopped with streams detached")
		check(snapshot.producer_frames == producer_frames_at_request and snapshot.producer_restarts == producer_restarts_at_request,
			"ALWAYS producer performs no frame or restart during audio drain")
		check(snapshot.stage == initial_stage and snapshot.title_scene_absent, "presentation remains retired through process exit")
		check(snapshot.modal_close_calls == 1 and snapshot.save_calls == expected_save_calls,
			"repeated requests perform one modal close and at most one save")
		var expected_events: Array = ["save", "close_modal"] if expected_save_calls == 1 else ["close_modal"]
		check(snapshot.events == expected_events, "successful save precedes modal invalidation")
		if case_name == "loading": check(loading_callbacks_checked, "loading late-callback assertions complete before actual teardown")
		if case_name == "timeout":
			check(held_playbacks.size() == 1 and live_playbacks == 1, "timeout case deliberately retains exactly one playback")
			check(elapsed_ms >= 950.0 and elapsed_ms < 3500.0, "retained playback observes the one-second bounded timeout")
		else:
			check(live_playbacks == 0, "all original playback weak references expire before real teardown")
			if case_name == "silent": check(elapsed_ms < 500.0, "silent controller exits promptly without a fixed audio delay")
	check(snapshot.auto_accept_restored, "teardown restores SceneTree automatic close behavior")
	held_playbacks.clear()
	var report := {
		"fixture": "controller_contract", "case": case_name,
		"checks": checks, "failures": failures, "snapshot": snapshot,
		"audio_observations": audio_observations,
		"loading_callbacks_checked": loading_callbacks_checked,
		"elapsed_ms": elapsed_ms, "live_playbacks_at_exit": live_playbacks,
		"process_frames_to_exit": Engine.get_process_frames() - request_frame,
		"timeout_warning_expected": case_name == "timeout", "forced_exit": forced_exit,
	}
	print("APP_SHUTDOWN_RESULT " + JSON.stringify(report))
	# The enclosing runner must assert this marker and failures array in addition
	# to the exit code: a quit requested earlier may already have committed code 0.
	var marker := FileAccess.open(directory.path_join("app_shutdown_result.json"), FileAccess.WRITE)
	if marker != null:
		marker.store_string(JSON.stringify(report))
		marker.close()
	if temp_created_here:
		DirAccess.remove_absolute(directory.path_join("app_shutdown_result.json"))
		DirAccess.remove_absolute(directory)
