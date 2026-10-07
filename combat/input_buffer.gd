extends RefCounted
class_name CombatInputBuffer

var entries: Array[Dictionary] = []
var lifetime := 0.18

func push(kind: String, now: float, duration := -1.0) -> void:
	prune(now)
	# A weapon input reserves one next action, never a backlog of clicks.
	if kind.begins_with("PRIMARY_") or kind.begins_with("SECONDARY_"):
		entries = entries.filter(func(entry: Dictionary) -> bool: return not (str(entry.kind).begins_with("PRIMARY_") or str(entry.kind).begins_with("SECONDARY_")))
	entries.append({"kind": kind, "time": now, "expires": now + (lifetime if duration < 0.0 else duration)})

func prune(now: float) -> void:
	entries = entries.filter(func(entry: Dictionary) -> bool: return now <= float(entry.get("expires", float(entry.time) + lifetime)))

func consume(kind: String, now: float) -> bool:
	prune(now)
	for i in range(entries.size()):
		if entries[i].kind == kind:
			entries.remove_at(i)
			return true
	return false

func clear() -> void:
	entries.clear()
