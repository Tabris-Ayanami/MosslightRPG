extends Node

const Art = preload("res://scripts/art.gd")
const PLAYER = preload("res://scenes/player.tscn")
const CombatWorld = preload("res://rpg/world_runtime.gd")
const CombatInputs = preload("res://combat/input_map.gd")
const WorldState = preload("res://rpg/world_state.gd")
const QuestService = preload("res://rpg/quest_service.gd")
const DialoguePanel = preload("res://rpg/dialogue_panel.gd")
const DialogueBridge = preload("res://rpg/dialogue_bridge.gd")
const NarrativeWorld = preload("res://rpg/narrative_world.gd")
const EconomyService = preload("res://rpg/economy_service.gd")
const WorldObjects = preload("res://rpg/world_objects.gd")
const ShopPanel = preload("res://scripts/frontend/shop_panel.gd")
const InteractionReadiness = preload("res://rpg/interaction_readiness.gd")
const MutationGuard = preload("res://rpg/mutation_guard.gd")
const EncounterService = preload("res://rpg/encounter_service.gd")
const ChapterService = preload("res://rpg/chapter_service.gd")
const WorldNavigation = preload("res://rpg/world_navigation.gd")
const ReturnGuidance = preload("res://rpg/return_guidance.gd")
const WORLD = preload("res://scenes/expanded_world.tscn")
const GARDEN_ORIGIN := Vector3(0, 0, 110)
const GARDEN_SPAWN := Vector3(1.6, 2.35, 4.8)
const DEFAULT_CAMERA_HEIGHT := 18.0
const DEFAULT_CAMERA_YAW := 0.3947911197 # atan2(10, 24)
const MIN_CAMERA_HEIGHT := 8.0
const MAX_CAMERA_HEIGHT := 32.0
const Hud = preload("res://scripts/hud.gd")
var viewport: SubViewport
var presentation: TextureRect
var pixel_material: ShaderMaterial
var world: Node3D
var camera: Camera3D
var combat_world: Node3D
var rpg: Node
var world_state := WorldState.new()
var quests := QuestService.new()
var chapter := ChapterService.new()
var _chapter_was_complete := false
var economy := EconomyService.new()
var world_objects := WorldObjects.new()
var interactions := preload("res://rpg/world_interactions.gd").new()
var world_ui: CanvasLayer
var encounters := EncounterService.new()
var world_navigation: Node3D
var rest_service: Node
var shop_panel: CanvasLayer
var _active_merchant: WeakRef
var dialogue_panel: CanvasLayer
var narrative_npcs: Array[Node3D] = []
var _dialogue_tree_was_paused := false
var _dialogue_pointer_was_blocked := false
var player: CharacterBody3D
var hud: Control
var sound: Node
var fx: Node3D
var smooth_target := Vector3(0, 0, 2)
var snap_offset := Vector2.ZERO
var checkpoint := GARDEN_ORIGIN + GARDEN_SPAWN
var encounter_origin := GARDEN_ORIGIN + GARDEN_SPAWN
var aim_position := Vector3.ZERO
var aim_override: Variant = null
var wave := 1
var wave_active := false
var defeated := 0
var wave_total := 0
var toast_text := ""
var toast_color := Color("d5ddbc")
var toast_time := 6.0
var show_help := false
var paused := false
var death_time := 0.0
var shake_amount := 0.0
var floaters: Array[Dictionary] = []
var visual_time := 0.0
var showcase := false
var compact_pixels := false
var last_interaction: Node3D
var ui_pointer_blocked := false
@export var show_interface := false
@export_range(10.0, 80.0, 0.1) var camera_pitch_degrees := 34.69515353
@export_range(8.0, 32.0, 0.5) var initial_camera_height := 18.0
@export_range(0.05, 1.0, 0.05) var orbit_sensitivity := 0.25
var camera_height := DEFAULT_CAMERA_HEIGHT
var target_camera_height := DEFAULT_CAMERA_HEIGHT
var camera_yaw := DEFAULT_CAMERA_YAW
var camera_dragging := false
var pointer_before_orbit := Vector2.ZERO
var mouse_mode_before_orbit := Input.MOUSE_MODE_VISIBLE
var reference_map: Node3D
var camera_offset := Vector3(10, 18, 24)
var post_material: ShaderMaterial
var garden_environment: Environment
var garden_sun: DirectionalLight3D
var reflection_viewport: SubViewport
var reflection_camera: Camera3D
var water_material: ShaderMaterial
var water_interactions: Node3D
var weather: Node

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_inputs()
	showcase = "--showcase" in OS.get_cmdline_user_args()
	viewport = SubViewport.new()
	viewport.name = "PixelWorld"
	viewport.size = Vector2i(484, 274)
	viewport.own_world_3d = true
	# Resolve thin leaf geometry before the final nearest-neighbor pixel upscale.
	viewport.msaa_3d = Viewport.MSAA_4X
	# Preserve thin imported geometry at the sides of an orthographic view.
	viewport.mesh_lod_threshold = 0.0
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	viewport.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(viewport)
	world = WORLD.instantiate()
	viewport.add_child(world)
	reference_map = world.get_node("WaterGarden")
	set_meta("static_prop_batches", preload("res://rpg/static_prop_batches.gd").build(reference_map))
	garden_environment = reference_map.get_node("GardenEnvironment").environment.duplicate()
	reference_map.get_node("GardenEnvironment").environment = garden_environment
	garden_sun = reference_map.get_node("GardenSun")
	camera_height = clampf(initial_camera_height, MIN_CAMERA_HEIGHT, MAX_CAMERA_HEIGHT)
	target_camera_height = camera_height
	camera_offset = _orbit_offset()
	smooth_target = checkpoint + _camera_lead()
	fx = Node3D.new()
	fx.name = "Effects"
	world.add_child(fx)
	combat_world = CombatWorld.new()
	combat_world.name = "CombatRuntime"
	combat_world.host = self
	combat_world.actor_parent = world
	combat_world.effects = fx
	world.add_child(combat_world)
	player = PLAYER.instantiate()
	player.position = checkpoint
	player.game = self
	world.add_child(player)
	rpg = player
	if not quests.setup(world_state, player):
		push_error("任务系统初始化失败：" + quests.last_error)
	if not economy.setup(world_state, player):
		push_error("经济系统初始化失败：" + economy.last_error)
	if not encounters.setup(world_state, combat_world.database):
		push_error("遭遇系统初始化失败：" + encounters.last_error)
	if not chapter.setup(quests, encounters, combat_world.database):
		push_error("章节初始化失败：" + chapter.last_error)
	quests.changed.connect(_chapter_quest_changed)
	combat_world.player = player
	camera = Camera3D.new()
	camera.name = "PixelCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = 23.0
	camera.near = 0.1
	camera.far = 170.0
	world.add_child(camera)
	camera.environment = garden_environment
	camera.look_at_from_position(smooth_target + camera_offset, smooth_target)
	camera.current = true
	combat_world.camera = camera
	var post := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	post.mesh = quad
	post.extra_cull_margin = 16384
	post.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	post.layers = 4
	post_material = ShaderMaterial.new()
	post_material.shader = preload("res://shaders/reference_outline.gdshader")
	post_material.render_priority = 127
	post.material_override = post_material
	camera.add_child(post)
	presentation = TextureRect.new()
	presentation.name = "PixelPresentation"
	presentation.texture = viewport.get_texture()
	presentation.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	presentation.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	presentation.mouse_filter = Control.MOUSE_FILTER_IGNORE
	presentation.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	pixel_material = ShaderMaterial.new()
	pixel_material.shader = preload("res://shaders/upscale.gdshader")
	presentation.material = pixel_material
	add_child(presentation)
	sound = get_node("Audio")
	combat_world.sound = sound
	sound.muted = showcase or DisplayServer.get_name() == "headless"
	hud = Hud.new()
	hud.game = self
	add_child(hud)
	hud.visible = show_interface
	_setup_reflection()
	weather = get_node("Weather")
	weather.setup(self)
	water_interactions=preload("res://scripts/water_interactions.gd").new()
	world.add_child(water_interactions)
	water_interactions.setup(self)
	sound.setup(self)
	var battle_overlay := preload("res://rpg/world_overlay.gd").new()
	battle_overlay.arena = combat_world
	add_child(battle_overlay)
	dialogue_panel = DialoguePanel.new()
	dialogue_panel.name = "DialoguePanel"
	dialogue_panel.setup(self)
	add_child(dialogue_panel)
	dialogue_panel.opened.connect(_dialogue_opened)
	dialogue_panel.closed.connect(_dialogue_closed)
	shop_panel = ShopPanel.new()
	shop_panel.name = "ShopPanel"
	shop_panel.setup(self)
	add_child(shop_panel)
	shop_panel.opened.connect(_dialogue_opened)
	shop_panel.closed.connect(_shop_closed)
	interactions.setup(self)
	world_ui = preload("res://rpg/world_interaction_ui.gd").new()
	world_ui.game = self
	add_child(world_ui)
	narrative_npcs = NarrativeWorld.populate(self)
	if world_objects.setup(self):
		world_objects.populate()
	else:
		push_error("世界交互初始化失败：" + world_objects.last_error)
	world_navigation = WorldNavigation.new()
	world_navigation.name = "WorldNavigation"
	world.add_child(world_navigation)
	if not world_navigation.setup(self):
		push_error("世界导航初始化失败")
	rest_service = preload("res://rpg/rest_service.gd").new()
	add_child(rest_service)
	rest_service.setup(self)
	get_viewport().size_changed.connect(_resize)
	get_window().focus_exited.connect(_focus_lost)
	_resize()
	if showcase:
		_capture_showcase()

func _setup_inputs() -> void:
	CombatInputs.install()
	var keys := {"pause_game": KEY_ESCAPE, "help": KEY_F1, "fullscreen": KEY_F11, "pixels": KEY_F2, "mute": KEY_M}
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		if InputMap.action_get_events(action).is_empty():
			var event := InputEventKey.new()
			event.physical_keycode = keys[action]
			InputMap.action_add_event(action, event)

func _unhandled_input(event: InputEvent) -> void:
	if world_modal_open():
		return
	if event.is_echo():
		return
	if _camera_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.alt_pressed and weather and weather.preview_input(event):
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause_game"):
		paused = not paused
		get_tree().paused = paused
		_end_camera_orbit()
		player.cancel_charge()
		_release_actions()
	if event.is_action_pressed("interact") and not paused:
		interact()
	if event.is_action_pressed("help"):
		show_help = not show_help
	if event.is_action_pressed("fullscreen"):
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
	if event.is_action_pressed("pixels"):
		compact_pixels = not compact_pixels
		_resize()
		notify("像素精度 · " + ("480 × 270" if compact_pixels else "640 × 360"))
	if event.is_action_pressed("mute"):
		sound.muted = not sound.muted
		notify("声音已静音" if sound.muted else "声音已开启")

func _camera_input(event: InputEvent) -> bool:
	if is_instance_valid(world_ui) and world_ui.handle_pointer(event): return true
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed and not paused:
				if not camera_dragging:
					pointer_before_orbit = get_viewport().get_mouse_position()
					mouse_mode_before_orbit = Input.mouse_mode
					camera_dragging = true
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else:
				_end_camera_orbit()
			return true
		if not paused and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var steps: float = event.factor if event.factor > 0.0 else 1.0
			var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			target_camera_height = clampf(target_camera_height * pow(0.9, steps * direction), MIN_CAMERA_HEIGHT, MAX_CAMERA_HEIGHT)
			return true
	if event is InputEventMouseMotion and camera_dragging and not paused:
		# Screen pixels keep sensitivity consistent in embedded F5 / fullscreen play.
		camera_yaw = wrapf(camera_yaw - deg_to_rad(event.screen_relative.x * orbit_sensitivity), -PI, PI)
		return true
	return false

func _end_camera_orbit(restore_pointer := true) -> void:
	if not camera_dragging:
		return
	camera_dragging = false
	Input.mouse_mode = mouse_mode_before_orbit
	if restore_pointer and get_window().has_focus():
		get_viewport().warp_mouse(pointer_before_orbit)

func _exit_tree() -> void:
	_end_camera_orbit(false)
	quests.dispose()
	economy.dispose()
	world_objects.dispose()

func dialogue_open() -> bool:
	return is_instance_valid(dialogue_panel) and dialogue_panel.is_open()

func _chapter_quest_changed() -> void:
	var complete := chapter.is_complete()
	if complete and not _chapter_was_complete:
		notify(chapter.title() + " 完成 · 与艾琳道别后可继续探索", Color("e8cc8e"))
	_chapter_was_complete = complete

func world_modal_open() -> bool:
	return dialogue_open() or (is_instance_valid(shop_panel) and shop_panel.is_open())

func close_world_modal() -> void:
	if dialogue_open():
		dialogue_panel.close()
	if is_instance_valid(shop_panel) and shop_panel.is_open():
		shop_panel.close()

func refresh_world_objects() -> void:
	world_objects.refresh()
	economy.refresh()
	interactions.refresh()

func begin_shop(merchant: Node3D) -> bool:
	if paused or world_modal_open() or MutationGuard.busy(world_state) or not is_instance_valid(merchant):
		return false
	if merchant not in narrative_npcs or merchant.hostile or merchant.dead or merchant.get_world_3d() != player.get_world_3d():
		return false
	_active_merchant = weakref(merchant)
	var shop_id := str(merchant.definition.get("shop_id", ""))
	var reason := can_trade(shop_id)
	if not reason.is_empty():
		_active_merchant = null
		notify(reason)
		return false
	if not shop_panel.start(shop_id, str(merchant.definition.get("name", "商人"))):
		_active_merchant = null
		return false
	return true

## Prices and quantities live in EconomyService; this only validates the world
## session. Pausing the world for the panel must not invalidate that session.
func can_trade(shop_id: String) -> String:
	if MutationGuard.busy(world_state):
		return "冒险状态更新中，请稍后再试"
	var merchant: Variant = _active_merchant.get_ref() if _active_merchant != null else null
	if not is_instance_valid(merchant) or merchant not in narrative_npcs or str(merchant.definition.get("shop_id", "")) != shop_id or economy.definition(shop_id).is_empty():
		return "请先与附近的商人交谈"
	var actor := controlled_actor()
	if actor != player:
		return "请先让意识回归本体，再与商人交易"
	if player.form.active:
		return "请先恢复原形，再与商人交易"
	if not player.is_human_controlled() or not InteractionReadiness.can_manage(player) or player.ladder.active:
		return "当前无法交易，请在安全站稳后重试"
	if merchant.get_world_3d() != actor.get_world_3d() or actor.global_position.distance_to(merchant.global_position) > 2.2:
		return "距离商人太远"
	return ""

func _shop_closed() -> void:
	_active_merchant = null
	_dialogue_closed()

func begin_dialogue(definition: Dictionary, source: Node3D = null) -> bool:
	var actor := controlled_actor()
	if paused or world_modal_open() or MutationGuard.busy(world_state) or not InteractionReadiness.can_manage(actor) or actor.ladder.active:
		return false
	# Definitions are authored game content, not arbitrary paths supplied by a save.
	var path := str(definition.get("dialogue", ""))
	if not path.begins_with("res://data/dialogue/") or not ResourceLoader.exists(path):
		return false
	var resource := load(path)
	var bridge := DialogueBridge.new()
	bridge.setup(self)
	if source == null:
		for npc in narrative_npcs:
			if str(npc.definition.id) == str(definition.get("id", "")): source = npc
	if is_instance_valid(source) and (source not in narrative_npcs or source.hostile or source.dead or actor.global_position.distance_to(source.global_position)>2.15): return false
	return dialogue_panel.start(resource, bridge, str(definition.get("title", "start")), source)

func _dialogue_opened() -> void:
	_dialogue_tree_was_paused = get_tree().paused
	_dialogue_pointer_was_blocked = ui_pointer_blocked
	paused = true
	ui_pointer_blocked = true
	_end_camera_orbit()
	player.cancel_charge()
	_release_actions()
	var actor := controlled_actor()
	actor.velocity = Vector3.ZERO
	actor.move_direction = Vector3.ZERO
	actor.animation.play_locomotion(false)
	actor.animation.update_pose(.15, actor.facing, "NORMAL", "NONE", 0.0)
	get_tree().paused = true

func _dialogue_closed() -> void:
	paused = _dialogue_tree_was_paused
	ui_pointer_blocked = _dialogue_pointer_was_blocked
	if is_instance_valid(player):
		player.cancel_charge()
	_release_actions()
	if is_inside_tree():
		get_tree().paused = _dialogue_tree_was_paused

func _orbit_offset() -> Vector3:
	var horizontal := camera_height / tan(deg_to_rad(camera_pitch_degrees))
	return Vector3(sin(camera_yaw) * horizontal, camera_height, cos(camera_yaw) * horizontal)

func _camera_lead() -> Vector3:
	# Rotate the framing offset too, so a full orbit keeps the player in view.
	return Vector3(0, 0, -4.5).rotated(Vector3.UP, camera_yaw - DEFAULT_CAMERA_YAW) * (camera_height / DEFAULT_CAMERA_HEIGHT)

func _update_camera_size() -> void:
	var h := 270 if compact_pixels else 360
	# Orthographic cameras also need a size change to make height act as zoom.
	camera.size = 23.0 * (camera_height / DEFAULT_CAMERA_HEIGHT) * float(viewport.size.y) / float(h)

func is_in_deep_water(at: Vector3) -> bool:
	var p := reference_map.to_local(at)
	var lake: MeshInstance3D = reference_map.get_node("Lake")
	var half_size: Vector2 = lake.mesh.size*.5
	return p.y < lake.position.y-.44 and absf(p.x-lake.position.x)<half_size.x and absf(p.z-lake.position.z)<half_size.y

func water_surface_at(at: Vector3) -> float:
	var lake: MeshInstance3D=reference_map.get_node("Lake")
	var p: Vector3=lake.to_local(at)
	var half_size: Vector2=lake.mesh.size*.5
	if absf(p.x)>=half_size.x or absf(p.z)>=half_size.y: return NAN
	var clock: float=weather.clock if is_instance_valid(weather) else 0.0
	var wind: float=weather.wind_strength if is_instance_valid(weather) else 1.0
	return lake.global_position.y+preload("res://scripts/water_surface.gd").field(Vector2(at.x,at.z),clock,wind).x

func water_ray_hit(ray_origin: Vector3, ray_direction: Vector3) -> Variant:
	var lake: MeshInstance3D = reference_map.get_node("Lake")
	var point: Variant = Plane(lake.global_basis.y.normalized(), lake.global_position).intersects_ray(ray_origin, ray_direction)
	if not point is Vector3 or absf(ray_direction.y)<.001: return null
	# Refine against the same height used by buoyancy and rendered long waves.
	for i in range(4):
		var height: float=water_surface_at(point)
		if not is_finite(height): return null
		var distance: float=(height-ray_origin.y)/ray_direction.y
		if distance<0.0: return null
		point=ray_origin+ray_direction*distance
	return point if is_finite(water_surface_at(point)) else null

func _setup_reflection() -> void:
	reflection_viewport = SubViewport.new()
	reflection_viewport.name = "LakeReflection"
	reflection_viewport.size = Vector2i(320, 180)
	# Empty sky must not lay an opaque grey film over otherwise clear water.
	reflection_viewport.transparent_bg = true
	reflection_viewport.msaa_3d = Viewport.MSAA_4X
	reflection_viewport.mesh_lod_threshold = 0.0
	reflection_viewport.world_3d = viewport.find_world_3d()
	reflection_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(reflection_viewport)
	reflection_camera = Camera3D.new()
	reflection_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	reflection_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	reflection_camera.cull_mask = 1
	reflection_camera.far = 170
	reflection_camera.environment = garden_environment
	reflection_viewport.add_child(reflection_camera)
	water_material = reference_map.get_node("Lake").material_override
	water_material.set_shader_parameter("surface_normals", preload("res://assets/water/surface_normals.tres"))
	water_material.set_shader_parameter("use_reflection", true)
	water_material.set_shader_parameter("reflection_tex", reflection_viewport.get_texture())

func _focus_lost() -> void:
	_end_camera_orbit(false)
	player.cancel_charge()
	_release_actions()

func _release_actions() -> void:
	CombatInputs.release_all()
	if is_instance_valid(player): player.cancel_charge()

func _resize() -> void:
	var size := get_viewport().get_visible_rect().size
	var h := 270 if compact_pixels else 360
	viewport.size = Vector2i(roundi(h * size.x / maxf(size.y, 1)), h) + Vector2i(4, 4)
	_update_camera_size()
	if reflection_viewport:
		# Match the scene's pixel grid so reflected leaves do not use larger,
		# unfiltered blocks that pop between samples during orthographic zoom.
		reflection_viewport.size = viewport.size
	presentation.size = size
	hud.size = size

func _process(delta: float) -> void:
	if player == null:
		return
	if paused:
		hud.queue_redraw()
		return
	visual_time += delta
	toast_time = maxf(0, toast_time - delta)
	shake_amount = move_toward(shake_amount, 0, delta * 1.7)
	camera_height = lerpf(camera_height, target_camera_height, 1.0 - exp(-delta * 12.0))
	_update_camera_size()
	var target: Vector3 = controlled_actor().global_position
	target.y = 2.2
	# Looking slightly ahead preserves space for the enemies and the ruins.
	target += _camera_lead()
	smooth_target = smooth_target.lerp(target, 1.0 - exp(-delta * 7))
	camera_offset = _orbit_offset()
	var desired := smooth_target + camera_offset
	camera.look_at_from_position(desired, smooth_target)
	if shake_amount > 0:
		desired += camera.global_basis.x * sin(visual_time * 97) * shake_amount
	var local := camera.global_basis.inverse() * desired
	var texel := camera.size / float(viewport.size.y)
	var snapped := local
	snapped.x = snappedf(local.x, texel)
	snapped.y = snappedf(local.y, texel)
	camera.global_position = camera.global_basis * snapped
	snap_offset = Vector2((local.x - snapped.x) / texel, -(local.y - snapped.y) / texel)
	pixel_material.set_shader_parameter("snap_offset", snap_offset)
	if reflection_camera:
		var reflected_pos := camera.global_position
		var water_y: float = reference_map.get_node("Lake").global_position.y
		reflected_pos.y = 2.0 * water_y - reflected_pos.y
		var reflected_direction := -camera.global_basis.z
		reflected_direction.y = -reflected_direction.y
		reflection_camera.size = camera.size
		reflection_camera.look_at_from_position(reflected_pos, reflected_pos + reflected_direction, Vector3.DOWN)
		water_material.set_shader_parameter("reflection_vp", reflection_camera.get_camera_projection() * Projection(reflection_camera.global_transform.affine_inverse()))
	if not camera_dragging:
		_update_aim()
	var grass_material: ShaderMaterial = reference_map.get_node("SculptableTerrain").grass_mesh.material
	grass_material.set_shader_parameter("player_position", controlled_actor().global_position)
	for i in range(floaters.size() - 1, -1, -1):
		floaters[i].life -= delta
		floaters[i].position.y += delta * 0.65
		if floaters[i].life <= 0:
			floaters.remove_at(i)
	if player.dead:
		death_time -= delta
		if death_time <= 0:
			respawn()
	hud.queue_redraw()

func _update_aim() -> void:
	aim_position = combat_world.refresh_aim()

func action_aim_direction() -> Vector3:
	# Sample the pointer when an action begins; idle cursor motion never turns the body.
	if not camera_dragging:
		_update_aim()
	var direction: Vector3 = aim_position - controlled_actor().global_position
	direction.y = 0
	if direction.length_squared() > 0.07:
		return direction.normalized()
	return controlled_actor().facing

func screen_to_viewport(point: Vector2) -> Vector2:
	var root_size := get_viewport().get_visible_rect().size
	return point / root_size * Vector2(viewport.size - Vector2i(4, 4)) + Vector2(2, 2) + snap_offset

func screen_to_world(point: Vector2, height: float) -> Variant:
	var p := screen_to_viewport(point)
	return Plane(Vector3.UP, height).intersects_ray(camera.project_ray_origin(p), camera.project_ray_normal(p))

func camera_right() -> Vector3:
	var right := camera.global_basis.x
	right.y = 0
	return right.normalized()

func camera_forward() -> Vector3:
	var forward := -camera.global_basis.z
	forward.y = 0
	return forward.normalized()

func world_to_screen(p: Vector3) -> Vector2:
	var pos := camera.unproject_position(p) - Vector2(2, 2) - snap_offset
	return pos / Vector2(viewport.size - Vector2i(4, 4)) * get_viewport().get_visible_rect().size

func controlled_actor() -> Node:
	return combat_world.controlled_actor()

func nearest_interactable() -> Node3D:
	var result: Node3D
	var distance := 2.15
	for prop in get_tree().get_nodes_in_group("interactables"):
		if not interactions.available(prop): continue
		if prop.get_world_3d() != controlled_actor().get_world_3d():
			continue
		var d: float = prop.interaction_distance(controlled_actor().global_position) if prop.has_method("interaction_distance") else prop.global_position.distance_to(controlled_actor().global_position)
		if d < distance:
			distance = d
			result = prop
	return result

func interact() -> void:
	if paused or controlled_actor().dead or not controlled_actor().is_human_controlled():
		return
	if controlled_actor().ladder.active:
		controlled_actor().ladder.detach("manual", true)
		return
	if is_instance_valid(world_ui) and world_ui.activate(): return
	var prop := nearest_interactable()
	if prop:
		var options: Array[Dictionary] = interactions.actions(prop)
		if not options.is_empty(): interactions.execute(prop, str(options[0].id))

func spawn_enemy(at: Vector3, elite: bool = false) -> CharacterBody3D:
	return combat_world.spawn_enemy("heavy_guard" if elite else "soldier", at)

func start_wave() -> void:
	if wave_active:
		return
	if player.loadout.level == 0:
		notify("请先在角色书页选择基础职业")
		return
	wave += 1
	defeated = 0
	wave_active = true
	wave_total = mini(3 + wave, 9)
	for i in range(wave_total):
		var a := i * TAU / wave_total
		var p := encounter_origin + Vector3(cos(a) * 4.5, 0.05, sin(a) * 3 - 1)
		var enemy := spawn_enemy(p, wave >= 2 and i % 3 == 0)
		enemy.set_meta("wave", wave)
		ring_fx(p, 0.8, Color("b8c896"), 0.4)
	notify("第 %d 轮试炼 · 红光抓取请闪避，微白光为精准格挡窗口" % wave, Color("e8cc8e"))

func enemy_defeated(enemy: Node3D) -> void:
	if not wave_active or enemy.get_meta("wave", -1) != wave:
		return
	defeated += 1
	if defeated >= wave_total:
		wave_active = false
		player.inventory.add_item("healing_potion", 2)
		player.inventory.add_item("magic_candy", 1)
		notify("试炼完成 · 生命药水 ×2 / 神奇糖果 ×1；符石可开启下一轮", Color("cde4ad"))

func notify(message: String, color: Color = Color("d8dec8")) -> void:
	toast_text = message
	toast_color = color
	toast_time = 4.5
	if is_instance_valid(world_ui): world_ui.feed.push(message, color)

func shake(amount: float) -> void:
	shake_amount = maxf(shake_amount, amount)

func float_text(at: Vector3, message: String, color: Color) -> void:
	floaters.append({"position": at, "text": message, "color": color, "life": 0.85})

func burst(at: Vector3, color: Color, count: int, power: float) -> void:
	for i in range(count):
		var bit := Art.box(fx, at, Vector3.ONE * randf_range(0.035, 0.095), color)
		var end := at + Vector3(randf_range(-1, 1), randf_range(0.2, 1.2), randf_range(-1, 1)) * power
		var t := bit.create_tween().set_parallel(true)
		t.tween_property(bit, "position", end, 0.36).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.tween_property(bit, "scale", Vector3.ONE * 0.01, 0.38)
		t.chain().tween_callback(bit.queue_free)

func ring_fx(at: Vector3, radius: float, color: Color, duration: float) -> void:
	var ring := Art.ring(fx, at, radius, 0.12, color)
	ring.scale = Vector3.ONE * 0.2
	var tween := ring.create_tween()
	tween.tween_property(ring, "scale", Vector3.ONE, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(ring.queue_free)

func slash_fx(at: Vector3, direction: Vector3, radius: float, heavy: bool) -> void:
	var angle := atan2(direction.x, direction.z)
	var slash := Art.ring(fx, at, radius, 0.17 if heavy else 0.10, Color("f2df9b") if heavy else Color("e2ecd3"), angle - 1.15, 2.3)
	var tween := slash.create_tween()
	tween.tween_property(slash, "scale", Vector3(1.12, 1, 1.12), 0.14)
	tween.tween_callback(slash.queue_free)

func line_fx(a: Vector3, b: Vector3, color: Color) -> void:
	var trail := Art.line(fx, a, b, 0.15, color)
	var tween := trail.create_tween()
	tween.tween_property(trail, "scale", Vector3(0.02, 0.02, 1), 0.30)
	tween.tween_callback(trail.queue_free)

func on_player_died() -> void:
	death_time = 2.5
	notify(ReturnGuidance.DEATH_NOTICE, Color("ecc2ad"))

func respawn() -> void:
	combat_world.clear_attacks()
	player.restore(checkpoint)
	if is_instance_valid(rest_service): rest_service.refresh()
	combat_world.reset_living_enemies()
	smooth_target = checkpoint + _camera_lead()
	notify(ReturnGuidance.describe(player).respawn_notice, Color("c5dfb4"))

func _capture_showcase() -> void:
	for i in range(180):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "res://docs/preview.png"
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOWCASE_SAVED " + ProjectSettings.globalize_path(path))
	print("RENDER_FPS ", Engine.get_frames_per_second(), " DRAW_CALLS ", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	get_tree().quit()
