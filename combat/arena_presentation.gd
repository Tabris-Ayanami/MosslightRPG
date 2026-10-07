extends Node
## Arena presentation follows the unchanged main-world pixel camera contract.
const DEFAULT_CAMERA_HEIGHT := 18.0
const DEFAULT_CAMERA_YAW := 0.3947911197
const MIN_CAMERA_HEIGHT := 8.0
const MAX_CAMERA_HEIGHT := 32.0
var camera_pitch_degrees := 34.69515353
var orbit_sensitivity := .25
var camera_height := DEFAULT_CAMERA_HEIGHT
var target_camera_height := DEFAULT_CAMERA_HEIGHT
var camera_yaw := DEFAULT_CAMERA_YAW
var camera_dragging := false
var pointer_before_orbit := Vector2.ZERO
var mouse_mode_before_orbit := Input.MOUSE_MODE_VISIBLE
var paused := false
var compact_pixels := false
var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var presentation: TextureRect
var pixel_material: ShaderMaterial
var post_material: ShaderMaterial
var snap_offset := Vector2.ZERO
var smooth_target := Vector3.ZERO
var player: Node3D

func _ready() -> void:
	viewport = SubViewport.new()
	viewport.name = "PixelWorld"
	viewport.own_world_3d = true
	viewport.mesh_lod_threshold = 0.0
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = .1
	camera.far = 170
	world.add_child(camera)
	camera.current = true
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
	presentation.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	presentation.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	presentation.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pixel_material = ShaderMaterial.new()
	pixel_material.shader = preload("res://shaders/upscale.gdshader")
	presentation.material = pixel_material
	add_child(presentation)
	get_viewport().size_changed.connect(_resize)
	get_window().focus_exited.connect(func(): _end_camera_orbit(false))
	_resize()

func follow(actor: Node3D) -> void:
	player = actor
	smooth_target = player.global_position + _camera_lead()
	_process(0)

func _resize() -> void:
	var size := get_viewport().get_visible_rect().size
	var h := 270 if compact_pixels else 360
	viewport.size = Vector2i(roundi(h * size.x / maxf(size.y, 1)), h) + Vector2i(4, 4)
	_update_camera_size()
	presentation.size = size

func _process(delta: float) -> void:
	if not is_instance_valid(player):
		return
	camera_height = lerpf(camera_height, target_camera_height, 1.0 - exp(-delta * 12.0))
	_update_camera_size()
	var target := player.global_position
	target.y = 0.0
	target += _camera_lead()
	smooth_target = smooth_target.lerp(target, 1.0 - exp(-delta * 7))
	var desired := smooth_target + _orbit_offset()
	camera.look_at_from_position(desired, smooth_target)
	var local := camera.global_basis.inverse() * desired
	var texel := camera.size / float(viewport.size.y)
	var snapped := local
	snapped.x = snappedf(local.x, texel)
	snapped.y = snappedf(local.y, texel)
	camera.global_position = camera.global_basis * snapped
	snap_offset = Vector2((local.x - snapped.x) / texel, -(local.y - snapped.y) / texel)
	pixel_material.set_shader_parameter("snap_offset", snap_offset)

func _camera_input(event: InputEvent) -> bool:
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
