extends RefCounted
## One synchronous mutation per adventure. Runtime-only ownership has no object
## references and never enters the save. Hold through final observer callbacks;
## observers may read/save the fully committed state, but cannot begin another
## reward, trade, interaction or restore within that publication.
const KEY: StringName = &"adventure_mutation_owner"

static func busy(world: Object) -> bool:
	return is_instance_valid(world) and world.has_meta(KEY)

static func acquire(world: Object, owner: String) -> bool:
	if not is_instance_valid(world) or owner.is_empty() or busy(world):
		return false
	world.set_meta(KEY, owner)
	return true

static func release(world: Object, owner: String) -> void:
	if is_instance_valid(world) and world.get_meta(KEY, "") == owner:
		world.remove_meta(KEY)
