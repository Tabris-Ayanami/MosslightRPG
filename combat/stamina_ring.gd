extends RefCounted
## Shared, non-interactive ground projection for both playable worlds.
const ResourcePips = preload("res://scripts/frontend/resource_pips.gd")
const DISPLAY_SCALE := 1.0 / 3.0
const COLOR := Color("7adac5")
const PIP_RADIUS := 7.2
const MIN_PIXEL_RADIUS := 3.6
const ARC_SAMPLES := 48
const ZOOM_RESPONSE := .25
const MAX_PIP_SPAN := deg_to_rad(168.0)
var pips = ResourcePips.new()
var centers: Array[Vector2] = []
var ground_points: Array[Vector3] = []
var arc := PackedVector2Array()
var arc_opacity := PackedFloat32Array()
var pip_arc := PackedVector2Array()
var visible := false
var radius_world := .65
var pip_radius := 3.0
var stroke_width := 1.45
var pip_span := 0.0
var recovery_progress := -1.0
var _layer: WeakRef
var _screen_origin := Vector2.ZERO
var _screen_near := Vector2.ZERO
var _screen_right := Vector2.ZERO
var _orthogonal := false
var _draw_key: Array = []
var _layout_key: Array = []
var _geometry_key: Array = []
var _center_offsets: Array[Vector2] = []
var _ground_offsets: Array[Vector3] = []
var _arc_offsets := PackedVector2Array()
var _pip_arc_offsets := PackedVector2Array()
var _cached_opacity := PackedFloat32Array()

class RetainedRing extends Node2D:
	var ring: RefCounted
	func _draw() -> void:
		draw_set_transform(-ring._screen_origin)
		ring._draw_geometry(self)

func attach(canvas: CanvasItem) -> void:
	# The child keeps Godot's draw commands while its transform follows the feet.
	# A weak back-reference leaves normal scene ownership responsible for cleanup.
	var layer := RetainedRing.new()
	layer.name = "StaminaRing"
	layer.ring = self
	canvas.add_child(layer)
	_layer = weakref(layer)

func update(arena: Node, delta: float, hidden: bool = false) -> void:
	_update_geometry(arena, delta, hidden)
	var layer: Node2D = _layer.get_ref() if _layer != null else null
	if layer == null: return
	layer.visible = visible
	if not visible: return
	layer.position = _screen_origin
	var key: Array = [pips.draw_revision, centers.size(), pip_radius, stroke_width, pip_span,
		(_screen_near * radius_world).snapped(Vector2(.001, .001)),
		(_screen_right * radius_world).snapped(Vector2(.001, .001))]
	# Perspective projections also depend on position; these worlds are orthogonal.
	if not _orthogonal or key != _draw_key:
		_draw_key = key
		layer.queue_redraw()

func _update_geometry(arena: Node, delta: float, hidden: bool) -> void:
	visible = false
	centers.clear()
	ground_points.clear()
	arc.clear()
	arc_opacity.clear()
	pip_arc.clear()
	if not is_instance_valid(arena) or not is_instance_valid(arena.player):
		pips.clear()
		return
	var player = arena.controlled_actor()
	var maximum: int = int(player.resources.max_value("Stamina"))
	var current: float = player.resources.current("Stamina")
	recovery_progress = player.combat.stamina_recovery_progress() if player.is_physics_processing() else -1.0
	pips.update(current, maximum, delta, recovery_progress)
	if hidden or maximum <= 0 or player.combat.state == "DEAD" or not is_instance_valid(arena.camera):
		return
	var camera: Camera3D = arena.camera
	var origin: Vector3 = player.global_position + Vector3.UP * .025
	# Main-world combat lives under PixelWorld's low-resolution SubViewport,
	# but world_to_screen and both overlay canvases use root canvas coordinates.
	var viewport_size: Vector2 = arena.get_tree().root.get_visible_rect().size
	var bounds := Rect2(Vector2.ZERO, viewport_size).grow(-6)
	_screen_origin = arena.world_to_screen(origin)
	if camera.is_position_behind(origin) or not bounds.has_point(_screen_origin):
		return
	# Camera-relative near/right vectors keep every point on the ground, on the
	# near side of the feet. The asymmetrical arc reads diagonally in projection.
	var near := Vector3(camera.global_basis.z.x, 0, camera.global_basis.z.z).normalized()
	var right := Vector3(camera.global_basis.x.x, 0, camera.global_basis.x.z).normalized()
	_orthogonal = camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	_screen_near = arena.world_to_screen(origin + near) - _screen_origin
	_screen_right = arena.world_to_screen(origin + right) - _screen_origin
	var window_size: Vector2 = arena.get_tree().root.size
	var pixel_scale := maxf(.01, minf(window_size.x / viewport_size.x, window_size.y / viewport_size.y))
	var ui_scale := viewport_size.y / 1080.0
	pip_radius = maxf(PIP_RADIUS * ui_scale, MIN_PIXEL_RADIUS / pixel_scale) * DISPLAY_SCALE
	stroke_width = maxf(1.45 * ui_scale, .85 / pixel_scale) * DISPLAY_SCALE
	var presenter: Node = arena.host if is_instance_valid(arena.host) else arena.get("renderer")
	var zoom_ratio := 1.0
	if is_instance_valid(presenter):
		zoom_ratio = maxf(.01, float(presenter.camera_height) / 18.0)
	var geometry_key: Array = [maximum, pip_radius, stroke_width, ui_scale, zoom_ratio, near, right,
		_screen_near.snapped(Vector2(.001, .001)), _screen_right.snapped(Vector2(.001, .001))]
	if _orthogonal and geometry_key == _geometry_key:
		for index in range(_center_offsets.size()):
			var center := _screen_origin + _center_offsets[index]
			if not bounds.grow(-pip_radius).has_point(center):
				centers.clear()
				ground_points.clear()
				return
			centers.append(center)
			ground_points.append(origin + _ground_offsets[index])
		for offset in _arc_offsets: arc.append(_screen_origin + offset)
		for offset in _pip_arc_offsets: pip_arc.append(_screen_origin + offset)
		arc_opacity = _cached_opacity.duplicate()
		visible = true
		return
	# Keep the default-distance footprint, but reduce the previous world-radius
	# zoom compensation to one quarter. Bean size remains in canvas pixels.
	var pixels_per_world_unit: float = _screen_right.length()
	radius_world = (44.0 + minf(maximum, 12) * 2.0) * ui_scale / maxf(.01, pixels_per_world_unit) * DISPLAY_SCALE
	var span_degrees := clampf(42.0 + float(maximum - 3) * 17.0, 42.0, 110.0)
	if maximum > 7: span_degrees = minf(128.0, 110.0 + float(maximum - 7) * 3.6)
	var span := deg_to_rad(span_degrees)
	var middle := deg_to_rad(24.0)
	var start := middle - span * .5
	var end := middle + span * .5
	var spacing := _project_centers(arena, origin, near, right, start, end, maximum)
	# This establishes the existing footprint at the default camera distance.
	var minimum_spacing := pip_radius * 2.6
	if spacing < minimum_spacing:
		radius_world *= minimum_spacing / maxf(.01, spacing)
	radius_world *= ZOOM_RESPONSE + (1.0 - ZOOM_RESPONSE) / zoom_ratio
	var layout_key: Array = [maximum, pip_radius,
		(_screen_near * radius_world).snapped(Vector2(.01, .01)),
		(_screen_right * radius_world).snapped(Vector2(.01, .01))]
	if layout_key != _layout_key:
		_layout_key = layout_key
		pip_span = _fit_pip_span(arena, origin, near, right, span, maximum, minimum_spacing)
	middle = _pip_middle(pip_span)
	start = middle - pip_span * .5
	end = middle + pip_span * .5
	# Expand the occupied angle first. Once the near-side arc is full, enlarge
	# the ring only as much as needed to preserve the same bean spacing.
	spacing = _project_centers(arena, origin, near, right, start, end, maximum)
	if spacing < minimum_spacing and is_equal_approx(pip_span, MAX_PIP_SPAN):
		radius_world *= minimum_spacing / maxf(.01, spacing)
		_project_centers(arena, origin, near, right, start, end, maximum)
	for center in centers:
		if not bounds.grow(-pip_radius).has_point(center):
			centers.clear()
			ground_points.clear()
			return
	for i in range(49):
		var angle := lerpf(end + .075, start + TAU - .075, i / 48.0)
		arc.append(_project(arena, origin, near, right, angle))
		arc_opacity.append(lerpf(.07, .22, (cos(angle) + 1.0) * .5))
	for i in range(33):
		var angle := lerpf(start - .075, end + .075, i / 32.0)
		pip_arc.append(_project(arena, origin, near, right, angle))
	visible = true
	if _orthogonal:
		_geometry_key = geometry_key
		_center_offsets.clear()
		_ground_offsets.clear()
		_arc_offsets.clear()
		_pip_arc_offsets.clear()
		for center in centers: _center_offsets.append(center - _screen_origin)
		for point in ground_points: _ground_offsets.append(point - origin)
		for point in arc: _arc_offsets.append(point - _screen_origin)
		for point in pip_arc: _pip_arc_offsets.append(point - _screen_origin)
		_cached_opacity = arc_opacity.duplicate()

func _pip_middle(span: float) -> float:
	# Wider arcs slide toward the front while both ends stay clear of the
	# far side, where the character would cover fixed-size beans.
	return minf(deg_to_rad(24.0), deg_to_rad(88.0) - span * .5)

func _fit_pip_span(arena: Node, origin: Vector3, near: Vector3, right: Vector3, base_span: float, maximum: int, preferred_spacing: float) -> float:
	var middle := _pip_middle(base_span)
	if _project_centers(arena, origin, near, right, middle - base_span * .5, middle + base_span * .5, maximum) >= preferred_spacing:
		return base_span
	middle = _pip_middle(MAX_PIP_SPAN)
	if _project_centers(arena, origin, near, right, middle - MAX_PIP_SPAN * .5, middle + MAX_PIP_SPAN * .5, maximum) < preferred_spacing:
		return MAX_PIP_SPAN
	var low := base_span
	var high := MAX_PIP_SPAN
	for _step in range(9):
		var span := (low + high) * .5
		middle = _pip_middle(span)
		if _project_centers(arena, origin, near, right, middle - span * .5, middle + span * .5, maximum) < preferred_spacing:
			low = span
		else:
			high = span
	return high

func _project(arena: Node, origin: Vector3, near: Vector3, right: Vector3, angle: float) -> Vector2:
	if _orthogonal:
		return _screen_origin + (_screen_near * cos(angle) + _screen_right * sin(angle)) * radius_world
	return arena.world_to_screen(origin + (near * cos(angle) + right * sin(angle)) * radius_world)

func _project_centers(arena: Node, origin: Vector3, near: Vector3, right: Vector3, start: float, end: float, maximum: int) -> float:
	ground_points.clear()
	centers.clear()
	# Equal projected arc lengths avoid crowded points at the foreshortened
	# end of the ellipse, without inflating the whole ring to fix one small gap.
	var lengths := PackedFloat32Array([0.0])
	var previous := _project(arena, origin, near, right, start)
	for sample in range(1, ARC_SAMPLES + 1):
		var angle := lerpf(start, end, float(sample) / ARC_SAMPLES)
		var projected := _project(arena, origin, near, right, angle)
		lengths.append(lengths[-1] + previous.distance_to(projected))
		previous = projected
	var segment := 1
	for index in range(maximum):
		var distance := lengths[-1] * (float(index) / (maximum - 1) if maximum > 1 else .5)
		while segment < ARC_SAMPLES and lengths[segment] < distance: segment += 1
		var fraction := (distance - lengths[segment - 1]) / maxf(.001, lengths[segment] - lengths[segment - 1])
		var angle := lerpf(start, end, (segment - 1 + fraction) / ARC_SAMPLES)
		var point := origin + (near * cos(angle) + right * sin(angle)) * radius_world
		ground_points.append(point)
		centers.append(_project(arena, origin, near, right, angle))
	var spacing := INF
	for index in range(1, centers.size()):
		spacing = minf(spacing, centers[index].distance_to(centers[index - 1]))
	return spacing

func draw(canvas: CanvasItem) -> void:
	if _layer != null and _layer.get_ref() != null: return
	_draw_geometry(canvas)

func _draw_geometry(canvas: CanvasItem) -> void:
	if not visible:
		return
	canvas.draw_polyline(arc, Color("10272b", .24), 2.0 * stroke_width, true)
	for i in range(1, arc.size()):
		canvas.draw_line(arc[i - 1], arc[i], Color(COLOR, arc_opacity[i]), stroke_width, true)
	canvas.draw_polyline(pip_arc, Color("10272b", .50), 2.0 * stroke_width, true)
	canvas.draw_polyline(pip_arc, Color(COLOR, .20), stroke_width, true)
	pips.draw(canvas, centers, pip_radius, COLOR, .90)
