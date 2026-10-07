extends RefCounted
## Presentation only. Availability always comes from current, never from a timer.
## A caller owns one instance per resource and calls update before draw each frame.

const OUTLINE_SECONDS := 0.32
const FILL_SECONDS := 0.12
const EPSILON := 0.000001

var _initialized := false
var _current := 0.0
var _maximum := 0
var _available_count := 0
var _slots: Array[Dictionary] = []
var draw_revision := 0

func clear() -> void:
	if _initialized: draw_revision += 1
	_initialized = false
	_current = 0.0
	_maximum = 0
	_available_count = 0
	_slots.clear()

func update(current: float, maximum: int, delta: float, recovery_progress: float = -1.0) -> void:
	var capacity := maxi(0, maximum)
	var amount := clampf(current if is_finite(current) else 0.0, 0.0, float(capacity))
	var available := clampi(int(floor(amount + EPSILON)), 0, capacity)
	var elapsed := maxf(0.0, delta) if is_finite(delta) else 0.0
	var predicted := is_finite(recovery_progress) and recovery_progress >= 0.0
	var progress := clampf(recovery_progress, 0.0, 1.0) if predicted else 0.0
	if capacity == 0:
		clear()
		return
	if not _initialized:
		draw_revision += 1
		_current = amount
		_maximum = capacity
		_available_count = available
		_slots.clear()
		for index in range(capacity):
			_slots.append(_new_slot("full" if index < available else "empty"))
		_initialized = true
	else:
		if capacity != _maximum or available != _available_count: draw_revision += 1
		# Advance only animations that existed before this sample. A newly gained
		# point starts at time zero regardless of the time since the last sample.
		for slot in _slots:
			_advance(slot, elapsed)
		while _slots.size() > capacity:
			_slots.pop_back()
		while _slots.size() < capacity:
			_slots.append(_new_slot("empty"))
		for index in range(capacity):
			if index >= available:
				# Spending cancels this point immediately, including an unfinished fill.
				if _slots[index].phase not in ["predict", "empty"]:
					_slots[index] = _new_slot("empty")
			elif index >= _available_count:
				# The real regeneration outline has already run. Do not run a second
				# ornamental outline after that point actually becomes available.
				_slots[index] = _new_slot("fill" if _slots[index].phase == "predict" else "outline")
		_current = amount
		_maximum = capacity
		_available_count = available
	# Exactly the next empty point may reflect the caller's real recovery timer.
	# Even progress == 1 leaves the centre empty until current really increases.
	for index in range(_slots.size()):
		if index == available and predicted and available < capacity:
			if _slots[index].phase != "predict":
				_slots[index] = _new_slot("predict")
				draw_revision += 1
			if _slots[index].outline != progress: draw_revision += 1
			_slots[index].outline = progress
		elif _slots[index].phase == "predict":
			_slots[index] = _new_slot("empty")
			draw_revision += 1

func _new_slot(phase: String) -> Dictionary:
	return {"phase": phase, "elapsed": 0.0,
		"outline": 1.0 if phase in ["full", "fill"] else 0.0,
		"fill": 1.0 if phase == "full" else 0.0}

func _advance(slot: Dictionary, delta: float) -> void:
	if slot.phase not in ["outline", "fill"]:
		return
	if delta > 0: draw_revision += 1
	slot.elapsed += delta
	if slot.phase == "outline":
		if float(slot.elapsed) + EPSILON < OUTLINE_SECONDS:
			slot.outline = clampf(float(slot.elapsed) / OUTLINE_SECONDS, 0.0, 1.0)
			return
		slot.elapsed = maxf(0.0, float(slot.elapsed) - OUTLINE_SECONDS)
		slot.phase = "fill"
		slot.outline = 1.0
	if float(slot.elapsed) + EPSILON >= FILL_SECONDS:
		slot.phase = "full"
		slot.elapsed = 0.0
		slot.fill = 1.0
	else:
		slot.fill = clampf(float(slot.elapsed) / FILL_SECONDS, 0.0, 1.0)

func debug_state() -> Dictionary:
	var slots: Array[Dictionary] = []
	for index in range(_slots.size()):
		var slot: Dictionary = _slots[index].duplicate(true)
		slot["available"] = index < _available_count
		slot["predicted"] = slot.phase == "predict"
		slots.append(slot)
	return {"initialized": _initialized, "current": _current, "maximum": _maximum,
		"available_count": _available_count, "slots": slots}

func is_animating() -> bool:
	for slot in _slots:
		if slot.phase in ["outline", "fill"] or slot.phase == "predict" and float(slot.outline) < 1.0:
			return true
	return false

func draw(c: CanvasItem, centers: Array[Vector2], radius: float, color: Color, alpha := 1.0) -> void:
	if not is_instance_valid(c) or radius <= 0.0 or alpha <= 0.0:
		return
	var opacity := clampf(alpha, 0.0, 1.0) * color.a
	var ring_radius := maxf(0.5, radius - 0.5)
	var line_width := clampf(radius * 0.18, 0.75, 1.5)
	for index in range(mini(centers.size(), _slots.size())):
		var center := centers[index]
		var slot: Dictionary = _slots[index]
		c.draw_circle(center, radius, Color(color.darkened(0.87), opacity * 0.45))
		c.draw_arc(center, ring_radius, -PI * 0.5, PI * 1.5, 40, Color(color, opacity * 0.28), line_width, true)
		var fill := float(slot.fill)
		if fill > 0.0:
			# A settled point stays quiet: no breathing, sparkle or brightness loop.
			var core_radius := maxf(0.5, radius * 0.82 * sqrt(fill))
			var core_color := color.lightened(0.14 * sin(PI * fill)) if slot.phase == "fill" else color
			c.draw_circle(center, core_radius, Color(core_color, opacity * lerpf(0.3, 0.88, fill)))
		if slot.phase == "full":
			c.draw_arc(center, ring_radius, -PI * 0.5, PI * 1.5, 40, Color(color, opacity * 0.58), line_width, true)
		elif float(slot.outline) > 0.0:
			var end := -PI * 0.5 + TAU * float(slot.outline)
			c.draw_arc(center, ring_radius, -PI * 0.5, end, 40, Color(color, opacity * 0.95), line_width + 0.35, true)
			if slot.phase in ["outline", "predict"] and float(slot.outline) < 1.0:
				c.draw_circle(center + Vector2(cos(end), sin(end)) * ring_radius, line_width * 0.7, Color(color, opacity))
