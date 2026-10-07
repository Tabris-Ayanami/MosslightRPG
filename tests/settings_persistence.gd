extends SceneTree
## Real disk, AudioServer, InputMap, and UI regression in a unique temporary folder.
const Preferences=preload("res://rpg/game_preferences.gd")
const Bindings=preload("res://scripts/frontend/journal_bindings.gd")
const Inputs=preload("res://combat/input_map.gd")
const Sound=preload("res://scripts/sound.gd")
const UI=preload("res://scripts/frontend/prototype_ui.gd")
var checks := 0
var failures: Array[String]=[]
var workspace := ""

func _initialize() -> void: call_deferred("run")

func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)

func key(code: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode=code
	event.keycode=code
	event.pressed=true
	return event

func volume(bus: String) -> float:
	return AudioServer.get_bus_volume_linear(AudioServer.get_bus_index(bus))

func ticks() -> void:
	await process_frame
	await process_frame

func child_check(path: String) -> void:
	Preferences.settings_path=path
	Inputs.install()
	var sound := Sound.new()
	sound.apply_mix()
	check(Preferences.get_audio_levels()==[31.0,42.0,53.0],"fresh process restores all three persisted audio sliders")
	check(is_equal_approx(volume("Master"),.31) and is_equal_approx(volume("Music"),db_to_linear(-12)*.42) and is_equal_approx(volume("Effects"),db_to_linear(-9)*.53),"fresh process applies saved levels over authored audio mix")
	check(Bindings.snapshot()=={"skill_q":KEY_4,"skill_e":KEY_R,"skill_r":KEY_E,"quick_item_1":KEY_1,"quick_item_2":KEY_2,"quick_item_3":KEY_3,"quick_item_4":KEY_Q},"fresh process restores both sides of skill/item and skill/skill swaps")
	check(not Preferences.get_damage_numbers(),"fresh process preserves damage number preference")
	check(Preferences.get_cast_mode("skill_q")=="precise" and Preferences.get_cast_mode("skill_e")=="quick" and Preferences.get_cast_mode("skill_r")=="precise","fresh process restores three independent cast modes beside remapped physical keys")
	check(Preferences.get_cast_mode("move_jump")=="precise" and Preferences.get_cast_mode("move_crouch")=="quick","fresh process independently restores Z/C movement cast modes")
	sound.free()
	quit(0 if failures.is_empty() else 1)

func run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size()==2 and arguments[0]=="--settings-child":
		child_check(arguments[1])
		return
	workspace=OS.get_temp_dir().path_join("mosslight-settings-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(workspace)
	var path := workspace.path_join("preferences.cfg")
	Preferences.settings_path=path
	Preferences.reload_preferences()
	check(Preferences.get_audio_levels()==Preferences.AUDIO_DEFAULTS and Preferences.get_damage_numbers(),"missing settings use audio and damage defaults")
	Inputs.install()
	check(Bindings.snapshot()==Preferences.BINDING_DEFAULTS,"missing settings install all seven default actions")
	check(Preferences.SKILL_ACTIONS.all(func(action: String) -> bool: return Preferences.get_cast_mode(action)=="quick"),"missing cast preferences default every skill slot to release casting")
	var sound := Sound.new()
	sound.apply_mix()
	check(is_equal_approx(volume("Master"),.72) and is_equal_approx(volume("Music"),db_to_linear(-12)*.58),"authored audio mix receives default slider scaling")
	var config := ConfigFile.new()
	config.set_value("unrelated","future_option",{"value":17})
	config.set_value("audio","future_bus",.27)
	config.set_value("bindings","future_action",123)
	config.set_value("casting","future_option","preserve")
	config.save(path)
	check(Preferences.set_damage_numbers(false)==OK,"damage setting writes successfully")
	check(Preferences.set_audio_level(0,31)==OK and Preferences.set_audio_level(1,42)==OK and Preferences.set_audio_level(2,53)==OK,"audio changes persist successfully")
	check(Preferences.set_cast_mode("skill_q","precise")==OK and Preferences.set_cast_mode("skill_r","precise")==OK and Preferences.get_cast_mode("skill_e")=="quick","changing Q and R cast modes leaves E independent")
	check(Preferences.set_cast_mode("move_jump","precise")==OK and Preferences.get_cast_mode("move_crouch")=="quick","Z can persist precise casting while C keeps its quick default")
	check(is_equal_approx(volume("Master"),.31) and is_equal_approx(volume("Music"),db_to_linear(-12)*.42),"master and music control actual corresponding buses")
	check(is_equal_approx(volume("Effects"),db_to_linear(-9)*.53) and is_equal_approx(volume("Ambience"),db_to_linear(-7)*.53) and is_equal_approx(volume("Footsteps"),db_to_linear(-2)*.53) and is_equal_approx(volume("Weather"),db_to_linear(2)*.53),"effects and environment scale together while preserving authored balance")
	Preferences.apply_audio_preferences()
	Preferences.apply_audio_preferences()
	check(is_equal_approx(volume("Music"),db_to_linear(-12)*.42),"reapplying preferences never compounds gain attenuation")
	sound.muted=true
	Preferences.set_audio_level(0,0)
	check(is_zero_approx(volume("Master")) and AudioServer.is_bus_mute(AudioServer.get_bus_index("Game")),"zero volume is silent without clearing Game mute")
	Preferences.set_audio_level(0,31)
	check(sound.muted and AudioServer.is_bus_mute(AudioServer.get_bus_index("Game")),"raising volume does not undo a manual Game mute")
	sound.muted=false
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"),true)
	Preferences.set_audio_level(1,42)
	check(AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")),"slider preserves unrelated bus mute flags")
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"),false)
	sound.apply_mix()
	check(is_equal_approx(volume("Music"),db_to_linear(-12)*.42) and not AudioServer.is_bus_mute(AudioServer.get_bus_index("Game")),"scene mix reconstruction reapplies preferences and preserves mute semantics")
	check(Bindings.assign(0,key(KEY_4)),"skill can take quick-item key")
	check(Bindings.snapshot().skill_q==KEY_4 and Bindings.snapshot().quick_item_4==KEY_Q,"conflicting quick-item receives previous skill physical key")
	check(Bindings.assign(1,key(KEY_R)),"skill can swap with another skill")
	var mapped := Bindings.snapshot()
	check(mapped.skill_e==KEY_R and mapped.skill_r==KEY_E,"skill swap updates both actions")
	check(Preferences.get_cast_mode("skill_q")=="precise" and Preferences.get_cast_mode("skill_e")=="quick" and Preferences.get_cast_mode("skill_r")=="precise","cast mode follows its logical skill slot after skill/item and skill/skill key swaps")
	config.load(path)
	check(config.get_value("bindings","skill_q")==KEY_4 and config.get_value("bindings","quick_item_4")==KEY_Q and config.get_value("bindings","skill_r")==KEY_E,"disk stores every affected physical key")
	check(config.get_value("unrelated","future_option")=={"value":17} and config.get_value("audio","future_bus")==.27 and config.get_value("bindings","future_action")==123 and not config.get_value("combat_ui","damage_numbers"),"audio and bindings preserve damage and unrelated future keys")
	check(config.get_value("casting","future_option")=="preserve" and config.get_value("casting","skill_q")=="precise" and config.get_value("casting","skill_r")=="precise","all settings writes preserve cast values and unknown future cast keys")
	for action in mapped: InputMap.action_erase_events(action)
	Inputs.install()
	check(Bindings.snapshot()==mapped,"input installation restores saved mapping after actions are recreated")
	Inputs.install()
	check(Bindings.snapshot()==mapped and InputMap.action_get_events("skill_q").size()==1,"repeated action installation neither resets nor duplicates saved keys")
	var fresh_output: Array=[]
	var exit_code := OS.execute(OS.get_executable_path(),PackedStringArray(["--headless","--path",ProjectSettings.globalize_path("res://"),"--script","res://tests/settings_persistence.gd","--","--settings-child",path]),fresh_output,true)
	check(exit_code==0,"separate Godot process confirms settings survive application restart")
	if exit_code!=0: print(fresh_output)
	var ui := UI.new()
	root.add_child(ui)
	ui.show_panel("settings")
	await ticks()
	check(ui.preview_levels==[31.0,42.0,53.0],"new settings UI starts with saved slider values")
	var sliders: Array=[]
	for node in ui.modal.get_children():
		if node is HSlider: sliders.append(node)
	check(sliders.size()==3 and sliders[0].value==31 and sliders[1].value==42 and sliders[2].value==53,"actual slider controls display restored values")
	sliders[0].value=29
	check(is_equal_approx(volume("Master"),.29) and Preferences.get_audio_levels()[0]==29,"real slider signal changes and persists live master volume")
	ui.settings_tab=1
	ui._build_modal()
	check(ui.modal.get_node("CastMode0").text=="精准施法" and ui.modal.get_node("CastMode1").text=="快速施法" and ui.modal.get_node("CastMode2").text=="精准施法","settings displays each slot's actual independent saved mode")
	check(ui.modal.get_node("CastMode3").text=="精准施法" and ui.modal.get_node("CastMode4").text=="快速施法","settings contains separate Z/C mode controls")
	ui.modal.get_node("CastMode4").pressed.emit()
	await ticks()
	check(Preferences.get_cast_mode("move_crouch")=="precise" and Preferences.get_cast_mode("move_jump")=="precise" and Preferences.get_cast_mode("skill_e")=="quick","actual C mode button persists only its own logical action")
	ui.modal.get_node("CastMode1").pressed.emit()
	await ticks()
	check(Preferences.get_cast_mode("skill_e")=="precise" and ui.modal.get_node("CastMode1").text=="精准施法" and Preferences.get_cast_mode("skill_q")=="precise","real mode button signal persists only its own slot and refreshes the displayed setting")
	ui._reset_settings_tab()
	check(Bindings.snapshot()==Preferences.BINDING_DEFAULTS,"reset controls restores both skills and all swapped quick-item keys")
	check(Preferences.SKILL_ACTIONS.all(func(action: String) -> bool: return Preferences.get_cast_mode(action)=="quick"),"controls-page reset restores release casting for all three slots")
	check(Preferences.CAST_ACTIONS.all(func(action: String) -> bool: return Preferences.get_cast_mode(action)=="quick"),"controls-page reset includes both Z and C modes")
	ui.settings_tab=0
	ui._reset_settings_tab()
	check(Preferences.get_audio_levels()==Preferences.AUDIO_DEFAULTS and is_equal_approx(volume("Master"),.72),"audio reset persists and applies the displayed defaults")
	ui.settings_tab=2
	ui._build_modal()
	var layout_disabled := 0
	for node in ui.modal.get_children():
		if node is Button and node.text in ["舒适","紧凑"] and node.disabled and node.tooltip_text.contains("尚未开放"):
			layout_disabled+=1
	check(layout_disabled==2,"unfinished layout options cannot falsely report a functional change")
	ui._reset_settings_tab()
	check(Preferences.get_damage_numbers(),"graphics reset restores working damage number setting")
	ui.queue_free()
	await ticks()
	check(Preferences.set_audio_level(0,-10)==OK and Preferences.get_audio_levels()[0]==0,"negative finite audio value clamps to zero")
	check(Preferences.set_audio_level(0,300)==OK and Preferences.get_audio_levels()[0]==100,"large finite audio value clamps to 100")
	var bytes_before := FileAccess.get_file_as_string(path)
	var values_before := Preferences.get_audio_levels()
	check(Preferences.set_audio_level(0,NAN)==ERR_INVALID_PARAMETER and Preferences.set_audio_level(0,INF)==ERR_INVALID_PARAMETER and Preferences.set_audio_level(3,50)==ERR_INVALID_PARAMETER,"invalid audio inputs rejected")
	check(Preferences.get_audio_levels()==values_before and FileAccess.get_file_as_string(path)==bytes_before,"invalid audio edits do not alter runtime or disk")
	check(Preferences.set_cast_mode("skill_q","invalid")==ERR_INVALID_PARAMETER and Preferences.set_cast_mode("attack_primary","precise")==ERR_INVALID_PARAMETER and FileAccess.get_file_as_string(path)==bytes_before,"invalid mode and non-skill slot edits cannot alter the settings file")
	check(not Bindings.assign(0,key(KEY_W)) and not Bindings.assign(0,key(KEY_M)) and not Bindings.assign(0,key(KEY_F1)),"movement, mute, and help bindings remain reserved")
	var modified := key(KEY_T)
	modified.ctrl_pressed=true
	check(not Bindings.assign(0,modified),"modifier chords cannot accidentally replace physical skill keys")
	InputMap.add_action("test_external")
	InputMap.action_add_event("test_external",key(KEY_T))
	check(not Bindings.assign(0,key(KEY_T)),"unrelated input action retains its occupied key")
	InputMap.erase_action("test_external")
	config.load(path)
	config.set_value("audio","master",-17.0)
	config.set_value("audio","music",150)
	config.set_value("audio","effects","loud")
	config.set_value("combat_ui","damage_numbers","false")
	config.set_value("bindings","skill_q",KEY_R)
	config.set_value("casting","skill_q",true)
	config.set_value("casting","skill_e","precise")
	config.set_value("casting","skill_r","precise")
	config.save(path)
	Preferences.reload_preferences()
	Bindings.restore_preferences()
	check(Preferences.get_audio_levels()==[0.0,100.0,80.0] and Preferences.get_damage_numbers(),"loaded out-of-range audio clamps and malformed values use typed defaults")
	check(Bindings.snapshot()==Preferences.BINDING_DEFAULTS,"duplicate saved physical keys fall back as one consistent seven-action set")
	check(Preferences.get_cast_mode("skill_q")=="quick" and Preferences.get_cast_mode("skill_e")=="precise" and Preferences.get_cast_mode("skill_r")=="precise","one malformed cast mode falls back independently without resetting other slots")
	config.set_value("bindings","skill_q",KEY_W)
	config.save(path)
	Preferences.reload_preferences()
	check(Preferences.get_bindings()==Preferences.BINDING_DEFAULTS,"reserved keys in config cannot steal movement after restart")
	config.set_value("bindings","skill_q",true)
	config.save(path)
	Preferences.reload_preferences()
	check(Preferences.get_bindings()==Preferences.BINDING_DEFAULTS,"non-integer physical key values use defaults")
	var invalid_codes := Preferences.BINDING_DEFAULTS.duplicate()
	invalid_codes.skill_q=KEY_W
	check(Preferences.set_bindings(invalid_codes)==ERR_INVALID_PARAMETER,"direct invalid binding snapshot rejected")
	var good_path := Preferences.settings_path
	Preferences.settings_path=workspace.path_join("missing_directory").path_join("preferences.cfg")
	Preferences.reload_preferences()
	Preferences.apply_audio_preferences()
	var prior_volume := volume("Master")
	var prior_bindings := Bindings.snapshot()
	check(Preferences.set_audio_level(0,1)!=OK and is_equal_approx(volume("Master"),prior_volume) and Preferences.get_audio_levels()==Preferences.AUDIO_DEFAULTS,"disk write failure leaves actual volume and saved-state cache unchanged")
	check(not Bindings.assign(0,key(KEY_T)) and Bindings.snapshot()==prior_bindings and Bindings.last_error.contains("保存失败"),"binding write failure keeps old live keys and explains failure")
	check(Preferences.set_damage_numbers(false)!=OK and Preferences.get_damage_numbers(),"damage write failure preserves displayed value")
	check(Preferences.set_cast_mode("skill_q","precise")!=OK and Preferences.get_cast_mode("skill_q")=="quick","cast-mode disk write failure keeps the live setting unchanged")
	Preferences.settings_path=good_path
	var corrupt_path := workspace.path_join("corrupt.cfg")
	var corrupt := FileAccess.open(corrupt_path,FileAccess.WRITE)
	corrupt.store_string("[broken\nvalue=")
	corrupt.close()
	Preferences.settings_path=corrupt_path
	Preferences.reload_preferences()
	check(Preferences.get_audio_levels()==Preferences.AUDIO_DEFAULTS and Preferences.get_bindings()==Preferences.BINDING_DEFAULTS,"unparseable config falls back safely")
	check(Preferences.set_audio_level(0,17)!=OK and FileAccess.get_file_as_string(corrupt_path)=="[broken\nvalue=","writes refuse to destroy an unparseable existing config")
	sound.free()
	Preferences.settings_path=Preferences.DEFAULT_PATH
	for file in [path,corrupt_path]: DirAccess.remove_absolute(file)
	DirAccess.remove_absolute(workspace)
	print("SETTINGS_PERSISTENCE: %d checks; %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
