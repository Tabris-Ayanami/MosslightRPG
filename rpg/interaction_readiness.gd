extends RefCounted
## Character-sheet operations require an idle, living actor, not permission to
## receive world combat input. Book pause and pointer capture are presentation.
## Operation-specific restrictions (including career changes while transformed)
## remain with the progression/loadout service that owns those rules.

static func can_manage(actor: Node) -> bool:
	if not is_instance_valid(actor) or actor.get("control_mode") == "none" or actor.get_meta("traversal_locked", false):
		return false
	var combat: Variant = actor.get("combat")
	var resources: Variant = actor.get("resources")
	if not is_instance_valid(combat) or not is_instance_valid(resources) or resources.current("HP") <= 0.0:
		return false
	if combat.get("state") not in ["NORMAL", "MOVE"]:
		return false
	var runner: Variant = combat.get("runner")
	if is_instance_valid(runner) and runner.busy():
		return false
	var switch_time: Variant = combat.get("switch_time")
	return switch_time == null or float(switch_time) <= 0.0
