extends RefCounted
## Authored source seconds, independent of gameplay attack speed.
const CLIPS = preload("res://assets/animations/retargeted/quaternius-combat.res")
const FAMILY_CLIPS = preload("res://assets/animations/retargeted/kaykit-family.res")

static func animation(name: String) -> Animation:
	if CLIPS.has_animation(name): return CLIPS.get_animation(name)
	if FAMILY_CLIPS.has_animation(name): return FAMILY_CLIPS.get_animation(name)
	return null

static func make_library() -> AnimationLibrary:
	# Players own their containers; the immutable baked tracks can be shared.
	var library := AnimationLibrary.new()
	for source in [CLIPS, FAMILY_CLIPS]:
		for name in source.get_animation_list(): library.add_animation(name, source.get_animation(name))
	return library

static func error_for(action: Dictionary) -> String:
	if not action.has("motion"): return ""
	var m: Dictionary = action.motion
	if m.has("recovery_clip") != m.has("recovery_end"): return "incomplete melee recovery markers"
	var clip := animation(str(m.get("clip", "")))
	if clip == null: return "unknown melee clip"
	var length: float = clip.length
	if not (0.0 < float(m.get("contact", 0)) and float(m.contact) < float(m.get("follow", 0)) and float(m.follow) <= float(m.get("end", 0)) and float(m.end) <= length + .001): return "unordered melee source markers"
	if m.has("recovery_clip"):
		var recovery := animation(str(m.recovery_clip))
		if recovery == null: return "unknown melee recovery clip"
		if float(m.get("recovery_end", 0)) <= 0 or float(m.recovery_end) > recovery.length + .001: return "invalid melee recovery marker"
	return ""

static func active_for(action: Dictionary) -> bool:
	return action.has("motion") and not action.get("dual_wield", false)

static func sample(action: Dictionary, phase: String, progress: float) -> Dictionary:
	var m: Dictionary = action.motion
	var p := clampf(progress, 0.0, 1.0)
	var clip: String = m.clip
	var time := 0.0
	match phase:
		"STARTUP": time = lerpf(0.0, m.contact, p)
		"ACTIVE": time = lerpf(m.contact, m.follow, p)
		_:
			if m.has("recovery_clip"):
				# Finish the authored follow-through before entering its matched return.
				if p < .25: time = lerpf(m.follow, m.end, p / .25)
				else:
					clip = m.recovery_clip
					time = (p - .25) / .75 * float(m.recovery_end)
			else: time = lerpf(m.follow, m.end, p)
	return {"clip": clip, "time": time}
