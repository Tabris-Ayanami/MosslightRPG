extends SceneTree
const Visual = preload("res://combat/kirito_combat_visual.gd")
class Host extends Node3D:
	var combat = null
	var facing := Vector3.FORWARD
class Legacy extends "res://combat/kirito_combat_visual.gd":
	func _sample_clip(clip: String, time: float) -> void:
		skeletal_clip = clip
		skeletal_time = time
		skeleton.reset_bone_poses()
		animator.play(clip, 0)
		animator.seek(time, true)
		animator.pause()
		animator.advance(0)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var host := Host.new()
	root.add_child(host)
	var old := Legacy.new()
	var fast := Visual.new()
	host.add_child(old)
	host.add_child(fast)
	old.setup(true)
	fast.setup(true)
	var checks := 0
	var failures: Array[String] = []
	for clip in fast.animator.get_animation_list():
		var length: float = fast.animator.get_animation(clip).length
		for ratio in [0.0, .23, .67, 1.0, .11]:
			# Prior IK edits must not leak into either full-body clip sample.
			old.skeleton.set_bone_pose_rotation(10, Quaternion(Vector3.UP, .9))
			fast.skeleton.set_bone_pose_rotation(10, Quaternion(Vector3.UP, .9))
			old._sample_clip(clip, ratio * length)
			fast._sample_clip(clip, ratio * length)
			var same := true
			for i in range(old.skeleton.get_bone_count()):
				same = same and old.skeleton.get_bone_pose(i).is_equal_approx(fast.skeleton.get_bone_pose(i))
			checks += 1
			if not same: failures.append("%s at %.3f" % [clip, ratio])
	var timings: Array[float] = []
	for visual in [old, fast]:
		var start := Time.get_ticks_usec()
		for i in range(600): visual._sample_clip("SwordC", (i % 119) / 60.0)
		timings.append((Time.get_ticks_usec() - start) / 600.0)
	print("ANIMATION_SAMPLING ", JSON.stringify({"checks": checks, "failures": failures, "old_us": timings[0], "candidate_us": timings[1]}))
	host.queue_free()
	for i in range(4): await process_frame
	quit(0 if failures.is_empty() else 1)
