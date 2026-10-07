extends RefCounted

var already_hit_targets: Dictionary = {}

func can_hit(target: Node, now: float, interval := 0.0) -> bool:
	var id := target.get_instance_id()
	if already_hit_targets.has(id) and (interval <= 0.0 or now - float(already_hit_targets[id]) < interval - .00001):
		return false
	already_hit_targets[id] = now
	return true
