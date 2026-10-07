extends Node
## Presentation shell: title -> skeletal wake-up -> opaque clouds -> threaded world load
## -> camera descent -> prototype HUD. Existing gameplay remains its own scene.
const MEADOW=preload("res://scenes/frontend/title_meadow.tscn")
const MENU=preload("res://scripts/frontend/title_menu.gd")
const UI=preload("res://scripts/frontend/prototype_ui.gd")
const VISUAL=preload("res://scripts/kirito_visual.gd")
const SKY_CHOICE=preload("res://scripts/frontend/sky_choice.gd")
const SAVE_MIGRATION_PANEL=preload("res://scripts/frontend/save_migration_panel.gd")
const FLIGHT=preload("res://scripts/frontend/sky_flight.gd")
const SAVE_REPOSITORY=preload("res://rpg/save_repository.gd")
const GAME_PATH="res://scenes/main.tscn"
# Retiming the presentation cursor keeps body, sword and simulated cloth together.
# The authored cache duration in title_story.gd is intentionally unchanged.
const JOURNEY_SECONDS=6.0
const ASCENT_SECONDS=5.4
const DISSOLVE_SECONDS=1.3
const AUDIO_QUIT_TIMEOUT_MSEC=1000
enum Stage { TITLE, JOURNEY, CHOOSING, DISSOLVING, ASCENDING, RETURNING, LOADING, DESCENDING, WORLD_RETURN, PLAYING }
var stage := Stage.TITLE
var stage_time := 0.0
var total_time := 0.0
var title_view: SubViewport
var shadow_view: SubViewport
var shadow_camera: Camera3D
var title_image: TextureRect
var meadow: Node3D
var menu: Control
var ui: Control
var cloud: TextureRect
var cloud_view: SubViewport
var cloud_pass: ColorRect
var cloud_material: ShaderMaterial
var game: Node
var music: AudioStreamPlayer
var birds: AudioStreamPlayer
var portrait_view: SubViewport
var paper_doll_view: SubViewport
var load_requested := false
var load_failed := false
var region_check := 0.0
var active_region := ""
var camera_end := Transform3D.IDENTITY
var camera_end_size := 23.0
var ui_layer: CanvasLayer
var ui_pointer_capture := false
var choice: Control
var save_migration_panel: Control
var journey_cursor := 0.0
var ascent_cursor := 0.0
var return_delay := 0.0
var choice_kind := "continue"
var selected_name := ""
var selected_save := -1
var saves=SAVE_REPOSITORY.new()
var pending_snapshot: Dictionary={}
var paper_doll_hero: Node3D
var return_descent_cursor := 0.0
var _quitting := false

func _ready() -> void:
	process_mode=Node.PROCESS_MODE_ALWAYS
	get_tree().auto_accept_quit=false
	ui_layer=CanvasLayer.new()
	ui_layer.layer=10
	add_child(ui_layer)
	menu=MENU.new()
	ui_layer.add_child(menu)
	menu.start_pressed.connect(start_adventure)
	ui=UI.new()
	ui_layer.add_child(ui)
	menu.new_pressed.connect(new_adventure)
	menu.settings_pressed.connect(ui.show_panel.bind("settings"))
	menu.exit_pressed.connect(_quit_game)
	menu.combat_pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/demo/CombatTestArena.tscn"))
	choice=SKY_CHOICE.new()
	ui_layer.add_child(choice)
	choice.confirmed.connect(_confirm_choice)
	choice.cancelled.connect(cancel_journey)
	save_migration_panel=SAVE_MIGRATION_PANEL.new()
	ui_layer.add_child(save_migration_panel)
	save_migration_panel.closed.connect(_close_save_migration)
	save_migration_panel.copied.connect(_save_migration_copied)
	ui.begin_adventure.connect(start_adventure)
	ui.return_to_title.connect(show_title)
	ui.save_requested.connect(save_adventure)
	ui.modal_changed.connect(_on_modal)
	var cloud_layer := CanvasLayer.new()
	# Sky is part of the scenery, behind the native name field and save controls.
	cloud_layer.layer=5
	add_child(cloud_layer)
	cloud_view=SubViewport.new()
	cloud_view.name="CloudVolumePass"
	cloud_view.disable_3d=true
	cloud_view.transparent_bg=true
	cloud_view.render_target_update_mode=SubViewport.UPDATE_DISABLED
	add_child(cloud_view)
	cloud=TextureRect.new()
	cloud.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	cloud.texture=cloud_view.get_texture()
	cloud.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	cloud.mouse_filter=Control.MOUSE_FILTER_IGNORE
	var composite := CanvasItemMaterial.new()
	composite.blend_mode=CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	cloud.material=composite
	cloud_material=ShaderMaterial.new()
	cloud_material.shader=preload("res://shaders/frontend/clouds.gdshader")
	cloud_material.set_shader_parameter("density_noise",preload("res://assets/ui/sky/cloud-noise.res"))
	cloud_material.set_shader_parameter("cloud_radii",PackedVector3Array(FLIGHT.SIZES))
	cloud_material.set_shader_parameter("cloud_centers",FLIGHT.cloud_centers(0))
	cloud_material.set_shader_parameter("roof_center",FLIGHT.ROOF_CENTER)
	cloud_pass=ColorRect.new()
	cloud_pass.material=cloud_material
	cloud_view.add_child(cloud_pass)
	cloud_layer.add_child(cloud)
	cloud.visible=false
	_build_portrait()
	_build_paper_doll()
	music=_voice("res://assets/audio/music/exploration.ogg",-22,"Music")
	birds=_voice("res://assets/audio/ambience/birds.ogg",-24,"Ambience")
	get_viewport().size_changed.connect(_resize)
	show_title()
	_resize()

func _voice(path: String, db: float, bus: String) -> AudioStreamPlayer:
	var voice := AudioStreamPlayer.new()
	var stream: AudioStreamOggVorbis=load(path).duplicate()
	stream.loop=true
	voice.stream=stream
	voice.bus=bus
	voice.volume_db=db
	add_child(voice)
	return voice

func _build_portrait() -> void:
	portrait_view=preload("res://scripts/frontend/hud_portrait_studio.gd").new()
	add_child(portrait_view)
	ui.portrait_studio=portrait_view
	ui.portrait.texture=portrait_view.get_texture()

func _build_paper_doll() -> void:
	# An isolated, once-rendered studio: the book never reposes the playable actor.
	paper_doll_view=SubViewport.new()
	paper_doll_view.name="FieldGuideCharacterStudio"
	paper_doll_view.own_world_3d=true
	paper_doll_view.transparent_bg=true
	paper_doll_view.size=Vector2i(384,576)
	paper_doll_view.msaa_3d=Viewport.MSAA_4X
	paper_doll_view.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	add_child(paper_doll_view)
	var actor := Node3D.new()
	paper_doll_view.add_child(actor)
	var hero := VISUAL.new()
	hero.name="PerformanceHero"
	paper_doll_hero=hero
	actor.add_child(hero)
	hero.scale=Vector3.ONE*1.78
	hero.rotation.y=PI-.12
	hero.animator.stop()
	hero.animator.active=false
	hero.skeleton.reset_bone_poses()
	var pose := AnimationPlayer.new()
	actor.add_child(pose)
	pose.add_animation_library("",load("res://assets/animations/retargeted/quaternius-title.res"))
	pose.play("Idle")
	pose.seek(.3,true)
	pose.pause()
	var environment := WorldEnvironment.new()
	var studio := Environment.new()
	studio.background_mode=Environment.BG_COLOR
	studio.background_color=Color("f5edda")
	studio.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	studio.ambient_light_color=Color("f1edda")
	studio.ambient_light_energy=.72
	environment.environment=studio
	paper_doll_view.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-35,-30,0)
	sun.light_color=Color("fff1d7")
	sun.light_energy=1.05
	paper_doll_view.add_child(sun)
	var camera := Camera3D.new()
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=3.65
	paper_doll_view.add_child(camera)
	camera.look_at_from_position(Vector3(.35,1.72,6),Vector3(0,1.63,0))
	ui.paper_doll.texture=paper_doll_view.get_texture()
	_freeze_paper_doll.call_deferred()

func _freeze_paper_doll() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _quitting or not is_instance_valid(paper_doll_view): return
	paper_doll_view.render_target_update_mode=SubViewport.UPDATE_ONCE

func show_title() -> void:
	if _quitting: return
	if is_instance_valid(save_migration_panel): save_migration_panel.dismiss()
	if stage==Stage.PLAYING and is_instance_valid(game) and not save_adventure():
		ui.show_panel("settings")
		return
	get_tree().paused=false
	if ui.panel!="": ui.close_panel(true)
	ui.bind_rpg(null)
	if is_instance_valid(game):
		game.queue_free()
		game=null
	selected_save=-1
	selected_name=""
	pending_snapshot.clear()
	ui.save_note=""
	_release_title_set()
	RenderingServer.global_shader_parameter_set("weather_wetness",0.0)
	RenderingServer.global_shader_parameter_set("weather_snow",0.0)
	RenderingServer.global_shader_parameter_set("weather_rain",0.0)
	RenderingServer.global_shader_parameter_set("weather_cloud",0.0)
	RenderingServer.global_shader_parameter_set("weather_wind",Vector4(.86,.5,1,1))
	title_view=SubViewport.new()
	title_view.name="TitlePixelWorld"
	title_view.own_world_3d=true
	# Resolve foliage edges within the pixel viewport; presentation stays nearest.
	title_view.msaa_3d=Viewport.MSAA_4X
	title_view.mesh_lod_threshold=0
	title_view.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	add_child(title_view)
	meadow=MEADOW.instantiate()
	title_view.add_child(meadow)
	shadow_view=SubViewport.new()
	shadow_view.name="TypographyLightPass"
	shadow_view.world_3d=title_view.find_world_3d()
	shadow_view.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	add_child(shadow_view)
	shadow_camera=Camera3D.new()
	shadow_camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	shadow_camera.cull_mask=2
	shadow_camera.far=220
	shadow_view.add_child(shadow_camera)
	shadow_camera.current=true
	title_image=TextureRect.new()
	title_image.name="TitlePresentation"
	title_image.texture=title_view.get_texture()
	title_image.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	title_image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	title_image.mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(title_image)
	menu.set_meadow_texture(shadow_view.get_texture(),title_view.get_texture())
	menu.visible=true
	menu.modulate.a=1
	menu.set_enabled(true)
	menu.buttons[0].grab_focus()
	ui.set_game_mode(false)
	ui.hud_alpha=1
	ui.modulate.a=1
	stage=Stage.TITLE
	stage_time=0
	journey_cursor=0
	ascent_cursor=0
	choice.hide()
	load_requested=false
	load_failed=false
	ui_pointer_capture=false
	cloud.visible=false
	cloud_material.set_shader_parameter("cover",0.0)
	music.volume_db=-22
	birds.volume_db=-24
	if DisplayServer.get_name()!="headless":
		music.play()
		birds.play()
	_resize()

func start_adventure() -> void:
	_begin_journey("continue")

func new_adventure() -> void:
	_begin_journey("new")

func _quit_game() -> void:
	if stage==Stage.TITLE: _request_quit()

func _notification(what: int) -> void:
	if what==NOTIFICATION_WM_CLOSE_REQUEST:
		_request_quit()

func _request_quit() -> void:
	if _quitting: return
	if stage==Stage.PLAYING and not save_adventure():
		ui.show_panel("settings")
		return
	_quitting=true
	# Invalidate already queued dialogue fetches before yielding; disabling node
	# processing alone does not cancel deferred calls or awaited dialogue responses.
	if is_instance_valid(game): game.close_world_modal()
	var tree := get_tree()
	var playbacks := _stop_audio_for_quit()
	var deadline := Time.get_ticks_msec()+AUDIO_QUIT_TIMEOUT_MSEC
	# stop() retires the AudioServer reference on a later mix, then its main-thread
	# cleanup. Keep frames running until that happened; sleeping cannot drain movie audio.
	while not playbacks.is_empty():
		for index in range(playbacks.size()-1,-1,-1):
			if playbacks[index].get_ref()==null: playbacks.remove_at(index)
		if playbacks.is_empty(): break
		if Time.get_ticks_msec()>=deadline:
			push_warning("Audio shutdown timed out with %d playback reference(s); continuing exit." % playbacks.size())
			break
		await tree.process_frame
	tree.quit()

func _stop_audio_for_quit() -> Array[WeakRef]:
	var playbacks: Array[WeakRef]=[]
	var nodes: Array[Node]=[self]
	while not nodes.is_empty():
		var node: Node=nodes.pop_back()
		nodes.append_array(node.get_children())
		# Explicit ALWAYS/PAUSABLE children do not inherit a disabled parent's mode.
		# Freeze every producer so world/weather loops cannot restart during shutdown.
		node.process_mode=Node.PROCESS_MODE_DISABLED
		if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
			if node.has_stream_playback(): playbacks.append(weakref(node.get_stream_playback()))
			node.stop()
			node.stream=null
	return playbacks

func save_adventure() -> bool:
	# Direct scene/test entry has no named adventure and must not create real saves.
	if not is_instance_valid(game) or selected_save<0: return true
	var result: Dictionary=saves.save(selected_save,selected_name,game.rpg,game)
	if result.get("ok",false):
		ui.save_note="已保存 · "+str(result.get("metadata",{}).get("display_time",Time.get_datetime_string_from_system(false,true).left(16)))
	else:
		ui.save_note="保存失败："+str(result.get("error","请稍后重试"))
	ui._refresh()
	return result.get("ok",false)

func _sync_paper_doll() -> void:
	if not is_instance_valid(paper_doll_hero) or not is_instance_valid(game): return
	paper_doll_hero.apply_equipment(game.rpg.loadout.equipment)
	paper_doll_view.render_target_update_mode=SubViewport.UPDATE_ONCE

func _begin_journey(kind: String) -> void:
	if _quitting: return
	if stage!=Stage.TITLE: return
	if ui.panel!="": ui.close_panel(true)
	menu.set_enabled(false)
	choice_kind=kind
	choice.preferred_slot=-1
	choice.set_save_slots(saves.list_slots())
	stage=Stage.JOURNEY
	stage_time=0
	journey_cursor=0
	ascent_cursor=0

func _open_save_migration() -> void:
	if _quitting: return
	if stage!=Stage.CHOOSING or choice.kind!="continue" or save_migration_panel.visible: return
	choice.hide()
	save_migration_panel.open(saves)

func _close_save_migration() -> void:
	if _quitting: return
	if stage!=Stage.CHOOSING: return
	choice.show()
	if choice.selected_slot < choice.slot_buttons.size(): choice.slot_buttons[choice.selected_slot].grab_focus()

func _save_migration_copied(result: Dictionary) -> void:
	if _quitting: return
	if stage!=Stage.CHOOSING: return
	choice.set_save_slots(saves.list_slots())
	choice.selected_slot=int(result.slot)
	choice.present("continue")
	choice.show_notice("副本已保存，选中的旅途可以继续。原冒险仍可在旧版本中继续。")

func _confirm_choice(kind: String, value: String) -> void:
	if _quitting: return
	if stage!=Stage.CHOOSING: return
	if is_instance_valid(save_migration_panel) and save_migration_panel.visible: return
	var result: Dictionary
	if kind=="new":
		var error: String=saves.validate_new_name(value)
		if not error.is_empty():
			choice.show_error(error)
			return
		result=saves.create(value,choice.preferred_slot)
	else: result=saves.load_slot(int(value))
	if not result.get("ok",false):
		choice.show_error(str(result.get("error","旅途记录读取失败")))
		return
	selected_save=int(result.slot)
	selected_name=str(result.metadata.name)
	pending_snapshot=result.snapshot.duplicate(true)
	choice.dissolve()
	stage=Stage.DISSOLVING
	stage_time=0
	if not load_requested:
		var status := ResourceLoader.load_threaded_request(GAME_PATH,"PackedScene",false)
		load_requested=status==OK
		load_failed=status!=OK

func cancel_journey() -> void:
	if _quitting: return
	if is_instance_valid(save_migration_panel) and save_migration_panel.visible:
		save_migration_panel.request_close()
		return
	if stage==Stage.DESCENDING:
		return_descent_cursor=clampf(stage_time/4.0,0,1)
		stage=Stage.WORLD_RETURN
		stage_time=0
		return
	if stage not in [Stage.JOURNEY,Stage.CHOOSING,Stage.DISSOLVING,Stage.ASCENDING,Stage.LOADING]: return
	return_delay=DISSOLVE_SECONDS if choice.visible else 0.0
	if choice.visible and not choice.leaving: choice.dissolve()
	stage=Stage.RETURNING
	stage_time=0

func _sample_journey() -> void:
	meadow.set_journey(journey_cursor)
	cloud.visible=journey_cursor>0
	cloud_material.set_shader_parameter("deck_mode",false)
	cloud_material.set_shader_parameter("roof_enabled",false)
	cloud_material.set_shader_parameter("cloud_centers",FLIGHT.cloud_centers(0))
	cloud_material.set_shader_parameter("cover",0.0)
	_update_cloud_camera(meadow.camera)
	menu.modulate.a=1-smoothstep(0,.11,journey_cursor)
	music.volume_db=lerpf(-22,-25,journey_cursor)
	birds.volume_db=lerpf(-24,-34,journey_cursor)

func _sample_ascent() -> void:
	meadow.set_ascent(ascent_cursor)
	cloud.visible=true
	cloud_material.set_shader_parameter("deck_mode",false)
	cloud_material.set_shader_parameter("roof_enabled",ascent_cursor>.24)
	cloud_material.set_shader_parameter("cloud_centers",FLIGHT.cloud_centers(ascent_cursor))
	cloud_material.set_shader_parameter("cover",smoothstep(.94,1.0,ascent_cursor))
	_update_cloud_camera(meadow.camera)
	music.volume_db=lerpf(-25,-42,ascent_cursor)
	birds.volume_db=lerpf(-34,-50,ascent_cursor)

func _sample_descent(seconds: float) -> void:
	cloud.visible=true
	cloud_material.set_shader_parameter("deck_mode",true)
	var t := smoothstep(0,4.0,seconds)
	var target: Vector3=game.smooth_target
	var far_pos := target+Vector3(5,152,25)
	var from := Transform3D(Basis.IDENTITY,far_pos).looking_at(target)
	game.camera.global_transform=from.interpolate_with(camera_end,t)
	game.camera.size=lerpf(116,camera_end_size,t)
	_reflect_camera()
	cloud_material.set_shader_parameter("cover",1-smoothstep(.12,.8,seconds))
	_update_cloud_camera(game.camera)

func _update_cloud_camera(camera: Camera3D) -> void:
	cloud_view.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	cloud_material.set_shader_parameter("eye",camera.global_position)
	cloud_material.set_shader_parameter("camera_right",camera.global_basis.x)
	cloud_material.set_shader_parameter("camera_up",camera.global_basis.y)
	cloud_material.set_shader_parameter("camera_forward",-camera.global_basis.z)
	var ortho := camera.projection==Camera3D.PROJECTION_ORTHOGONAL
	cloud_material.set_shader_parameter("orthographic",ortho)
	cloud_material.set_shader_parameter("view_extent",camera.size*.5 if ortho else tan(deg_to_rad(camera.fov)*.5))

func _return_from_world() -> void:
	if _quitting: return
	ui.bind_rpg(null)
	game._release_actions()
	game.queue_free()
	game=null
	title_image.visible=true
	title_view.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	title_view.process_mode=Node.PROCESS_MODE_INHERIT
	shadow_view.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	menu.visible=true
	stage=Stage.RETURNING
	stage_time=0
	return_delay=.15
	_sample_ascent()
	load_requested=false
	load_failed=false
	if DisplayServer.get_name()!="headless":
		music.play()
		birds.play()

func _on_modal(open: bool) -> void:
	if _quitting: return
	if stage==Stage.TITLE:
		menu.set_enabled(not open)
	if stage==Stage.PLAYING and is_instance_valid(game):
		if game.world_modal_open():
			return
		game.paused=open
		game.ui_pointer_blocked=open
		ui_pointer_capture=false
		game.player.cancel_charge()
		game._release_actions()
		game._end_camera_orbit()
		get_tree().paused=open

func _input(event: InputEvent) -> void:
	if _quitting: return
	if is_instance_valid(save_migration_panel) and save_migration_panel.visible:
		save_migration_panel.handle_input(event)
		return
	if stage==Stage.PLAYING and ui.panel=="" and is_instance_valid(game) and event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_RIGHT:
		var controlled: Node=game.controlled_actor()
		if is_instance_valid(controlled) and controlled.input_router.cancel_cast_from_pointer():
			get_viewport().set_input_as_handled()
			return
	if stage==Stage.PLAYING and ui.panel=="" and is_instance_valid(game) and is_instance_valid(game.world_ui) and game.world_ui.handle_pointer(event): return
	if is_instance_valid(game) and game.world_modal_open():
		# World panels own their keys and pointer focus while gameplay is paused.
		return
	if event is InputEventMouseButton:
		var busy := stage not in [Stage.TITLE,Stage.PLAYING,Stage.CHOOSING]
		var over_ui: bool=ui.blocks_world_pointer(event.position)
		var weapon_button: bool=event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT]
		if event.pressed and over_ui and weapon_button: ui_pointer_capture=true
		if is_instance_valid(game): game.ui_pointer_blocked=busy or over_ui or ui_pointer_capture
		if is_instance_valid(game) and (busy or over_ui or ui_pointer_capture):
			Input.action_release("attack_primary")
			Input.action_release("attack_secondary")
			var controlled: Node=game.controlled_actor()
			if not controlled.input_router.selection_active() and not controlled.input_router.cast_pending(): controlled.input_router.cancel_pointer()
		if ui.panel!="map" and (busy or over_ui) and event.button_index in [MOUSE_BUTTON_MIDDLE,MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
			get_viewport().set_input_as_handled()
		if not event.pressed and weapon_button: ui_pointer_capture=false
	if event is InputEventKey and event.pressed and not event.echo:
		if ui.capture_binding(event):
			get_viewport().set_input_as_handled()
			return
		if stage not in [Stage.TITLE,Stage.PLAYING]:
			if event.keycode==KEY_ESCAPE:
				cancel_journey()
				get_viewport().set_input_as_handled()
			elif stage==Stage.CHOOSING:
				if choice.kind=="continue":
					if event.keycode in [KEY_LEFT,KEY_RIGHT,KEY_UP,KEY_DOWN]:
						var offset: int={KEY_LEFT:-1,KEY_RIGHT:1,KEY_UP:-4,KEY_DOWN:4}[event.keycode]
						choice._select(posmod(choice.selected_slot+offset,20))
						get_viewport().set_input_as_handled()
					elif event.keycode==KEY_ENTER:
						choice._confirm()
						get_viewport().set_input_as_handled()
				return
			get_viewport().set_input_as_handled()
			return
		if event.keycode==KEY_ESCAPE:
			if ui.panel!="": ui.request_escape()
			else: ui.show_panel("settings")
			get_viewport().set_input_as_handled()
		elif stage==Stage.PLAYING and event.keycode in [KEY_B,KEY_J,KEY_X,KEY_K,KEY_M]:
			var next: String={KEY_B:"bag",KEY_J:"journal",KEY_X:"journal",KEY_K:"skills",KEY_M:"map"}[event.keycode]
			if ui.panel==next: ui.close_panel()
			else: ui.show_panel(next)
			get_viewport().set_input_as_handled()

func _resize() -> void:
	var size := get_viewport().get_visible_rect().size
	if is_instance_valid(title_view): title_view.size=Vector2i(roundi(450.0*size.x/maxf(size.y,1)),450)
	if is_instance_valid(shadow_view): shadow_view.size=title_view.size
	if is_instance_valid(title_image): title_image.size=size
	if cloud: cloud.size=size
	if cloud_view:
		cloud_view.size=Vector2i(roundi(450.0*size.x/maxf(size.y,1)),450)
		cloud_pass.size=cloud_view.size
		cloud_material.set_shader_parameter("aspect",size.x/maxf(size.y,1))

func _process(delta: float) -> void:
	if _quitting: return
	total_time+=delta
	stage_time+=delta
	cloud_material.set_shader_parameter("drift",total_time)
	if not cloud.visible: cloud_view.render_target_update_mode=SubViewport.UPDATE_DISABLED
	if stage!=Stage.PLAYING and is_instance_valid(meadow):
		RenderingServer.global_shader_parameter_set("weather_clock",total_time)
		RenderingServer.global_shader_parameter_set("weather_wind_phase",total_time)
	match stage:
		Stage.JOURNEY:
			journey_cursor=minf(1,journey_cursor+delta/JOURNEY_SECONDS)
			_sample_journey()
			if journey_cursor>=1:
				stage=Stage.CHOOSING
				stage_time=0
				choice.present(choice_kind)
		Stage.DISSOLVING:
			# Walk and lift the camera while the text disperses, without a frozen beat.
			ascent_cursor=minf(1,ascent_cursor+delta/ASCENT_SECONDS)
			_sample_ascent()
			if stage_time>=DISSOLVE_SECONDS:
				choice.hide()
				stage=Stage.LOADING if ascent_cursor>=1 else Stage.ASCENDING
				stage_time=0
		Stage.RETURNING:
			# Text can finish dispersing over the reverse camera move as well.
			if stage_time>=return_delay: choice.hide()
			if ascent_cursor>0:
				ascent_cursor=maxf(0,ascent_cursor-delta/ASCENT_SECONDS)
				_sample_ascent()
			else:
				cloud.visible=false
				journey_cursor=maxf(0,journey_cursor-delta/JOURNEY_SECONDS)
				_sample_journey()
				if journey_cursor<=0:
					stage=Stage.TITLE
					stage_time=0
					menu.set_enabled(true)
					menu.buttons[1 if choice_kind=="new" else 0].grab_focus()
		Stage.ASCENDING:
			ascent_cursor=minf(1,ascent_cursor+delta/ASCENT_SECONDS)
			_sample_ascent()
			if ascent_cursor>=1:
				stage=Stage.LOADING
				stage_time=0
		Stage.LOADING:
			cloud_material.set_shader_parameter("cover",1.0)
			if load_failed:
				push_error("Could not load the adventure scene; returning to title.")
				show_title()
				return
			var status := ResourceLoader.load_threaded_get_status(GAME_PATH)
			if status==ResourceLoader.THREAD_LOAD_FAILED or status==ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				load_failed=true
			elif status==ResourceLoader.THREAD_LOAD_LOADED and stage_time>.3:
				_enter_world(ResourceLoader.load_threaded_get(GAME_PATH))
		Stage.DESCENDING:
			_sample_descent(stage_time)
			if stage_time>=4.0: _finish_arrival()
		Stage.WORLD_RETURN:
			return_descent_cursor=maxf(0,return_descent_cursor-delta/4.0)
			_sample_descent(return_descent_cursor*4)
			if return_descent_cursor<=0: _return_from_world()
		Stage.PLAYING:
			ui.modulate.a=move_toward(ui.modulate.a,1,delta*1.4)
			if not get_tree().paused:
				region_check-=delta
				if region_check<=0:
					region_check=.4
					_check_region()
	# The letters sample the grass/light pass during the first moving frames.
	# Update this camera after the cinematic camera, not one render frame behind it.
	if is_instance_valid(meadow) and is_instance_valid(shadow_camera):
		shadow_camera.global_transform=meadow.camera.global_transform
		shadow_camera.projection=meadow.camera.projection
		shadow_camera.fov=meadow.camera.fov
		shadow_camera.size=meadow.camera.size

func _enter_world(scene: PackedScene) -> void:
	if _quitting: return
	menu.visible=false
	game=scene.instantiate()
	add_child(game)
	if not pending_snapshot.is_empty():
		var restored: Dictionary=saves.restore(pending_snapshot,game.rpg,game)
		if not restored.get("ok",false):
			var error: String=str(restored.get("error","旅途数据不完整"))
			show_title()
			ui.save_note="读档失败："+error
			ui.show_panel("settings")
			return
		pending_snapshot.clear()
	game.rpg.display_name=selected_name if not selected_name.is_empty() else "桐人"
	game.rpg.loadout.changed.connect(_sync_paper_doll)
	game.rest_service.rested.connect(func(_kind: String) -> void: save_adventure())
	_sync_paper_doll()
	ui.bind_rpg(game.rpg,selected_name)
	ui.bind_map(game.reference_map,game.player)
	game.set_process(false)
	game.set_process_unhandled_input(false)
	game.player.set_physics_process(false)
	game._release_actions()
	game._process(0)
	camera_end=game.camera.global_transform
	camera_end_size=game.camera.size
	game.camera.far=240
	# Retire the menu set only after opaque clouds have covered a rendered frame.
	title_image.visible=false
	title_view.render_target_update_mode=SubViewport.UPDATE_DISABLED
	title_view.process_mode=Node.PROCESS_MODE_DISABLED
	shadow_view.render_target_update_mode=SubViewport.UPDATE_DISABLED
	music.stop()
	birds.stop()
	stage=Stage.DESCENDING
	stage_time=0

func _reflect_camera() -> void:
	var position: Vector3=game.camera.global_position
	position.y=1.2-position.y
	var direction: Vector3=-game.camera.global_basis.z
	direction.y=-direction.y
	game.reflection_camera.size=game.camera.size
	game.reflection_camera.far=240
	game.reflection_camera.look_at_from_position(position,position+direction,Vector3.DOWN)
	game.water_material.set_shader_parameter("reflection_vp",game.reflection_camera.get_camera_projection()*Projection(game.reflection_camera.global_transform.affine_inverse()))

func _finish_arrival() -> void:
	if _quitting: return
	stage=Stage.PLAYING
	stage_time=0
	game.camera.global_transform=camera_end
	game.camera.size=camera_end_size
	game.camera.far=170
	game.reflection_camera.far=170
	game.set_process(true)
	game.set_process_unhandled_input(true)
	game.player.set_physics_process(true)
	game._release_actions()
	cloud.visible=false
	ui.modulate.a=0
	ui.set_game_mode(true)
	if game.rpg.loadout.level==0:
		ui.career_picker=true
		ui.character_tab=1
		ui.show_panel("character")
	active_region=""
	_check_region()
	_release_title_set()

func _release_title_set() -> void:
	# Detach sampled viewport textures and the shared world before freeing either
	# viewport. Otherwise their render resources can retain one another at teardown.
	if is_instance_valid(menu): menu.release_meadow_textures()
	if is_instance_valid(title_image):
		title_image.texture=null
		title_image.queue_free()
	if is_instance_valid(shadow_view):
		shadow_view.world_3d=null
		shadow_view.queue_free()
	if is_instance_valid(title_view): title_view.queue_free()
	title_image=null
	shadow_view=null
	shadow_camera=null
	title_view=null
	meadow=null

func _check_region() -> void:
	var p: Vector3=game.reference_map.to_local(game.player.global_position)
	var next := "风铃村" if p.z<-29 else ("低语森林" if p.x>23 else "风息原野")
	if game.rest_service.inside(): next="风铃旅馆"
	if next==active_region: return
	active_region=next
	ui.show_region(next,{"风息原野":"风经过的地方，故事才刚刚开始","风铃村":"炊烟与钟声，欢迎每一个归来的旅人","低语森林":"放轻脚步，听树叶说话","风铃旅馆":"放下行囊，在温暖的客床稍作休息"}[next])

func _exit_tree() -> void:
	get_tree().auto_accept_quit=true
	if is_instance_valid(cloud): cloud.texture=null
	if is_instance_valid(cloud_pass): cloud_pass.material=null
	if is_instance_valid(music):
		music.stop()
		music.stream=null
	if is_instance_valid(birds):
		birds.stop()
		birds.stream=null
	if is_instance_valid(shadow_view): shadow_view.world_3d=null
	if is_instance_valid(menu): menu.release_meadow_textures()
	get_tree().paused=false
