extends SceneTree
const ANIMATION=preload("res://assets/ui/title/title-story.res")
func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://.work/motion-integration/")
	var spikes := []
	var worst := {"degrees":0.0,"time":0.0,"bone":""}
	for track in range(ANIMATION.get_track_count()):
		if ANIMATION.track_get_type(track)!=Animation.TYPE_ROTATION_3D: continue
		var previous := ANIMATION.rotation_track_interpolate(track,0)
		for frame in range(1,roundi(ANIMATION.length*120)+1):
			var t := float(frame)/120
			var q := ANIMATION.rotation_track_interpolate(track,t)
			var degrees := rad_to_deg(previous.angle_to(q))
			var row := {"degrees":degrees,"time":t,"bone":str(ANIMATION.track_get_path(track))}
			if degrees>worst.degrees: worst=row
			if degrees>6: spikes.append(row)
			previous=q
	spikes.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return a.degrees>b.degrees)
	print("MOTION_WORST ",worst)
	for row: Dictionary in spikes.slice(0,16): print("MOTION_SPIKE ",row)
	FileAccess.open("res://.work/motion-integration/continuity.json",FileAccess.WRITE).store_string(JSON.stringify({"worst":worst,"spikes":spikes},"  "))
	quit(0 if spikes.is_empty() else 1)
