extends RefCounted
## Each conversation receives this adventure's bridge as an extra state object.
## Upstream Dialogue Manager resolves the script; mutations use checked RPG APIs.
var game: Node
var last_operation_ok := true
var last_error := ""

func setup(owner_game: Node) -> void:
	game = owner_game

func has_career() -> bool:
	return is_instance_valid(game) and is_instance_valid(game.player) and game.player.loadout.level > 0

func player_name() -> String:
	return game.player.display_name if is_instance_valid(game) and is_instance_valid(game.player) else "旅人"

func has_flag(id: String) -> bool:
	return is_instance_valid(game) and game.world_state.get_flag(id, false) == true

func quest_status(id: String) -> String:
	return game.quests.status(id) if is_instance_valid(game) and game.quests != null else "unknown"

func chapter_phase() -> String:
	return game.chapter.phase() if is_instance_valid(game) and game.chapter != null else "unavailable"

func chapter_title() -> String:
	return game.chapter.title() if is_instance_valid(game) and game.chapter != null else ""

func accept_quest(id: String) -> bool:
	if not is_instance_valid(game) or game.quests == null:
		return _unavailable()
	last_operation_ok = game.quests.accept(id)
	last_error = game.quests.last_error
	return last_operation_ok

func claim_quest(id: String) -> bool:
	if not is_instance_valid(game) or game.quests == null:
		return _unavailable()
	last_operation_ok = game.quests.claim(id)
	last_error = game.quests.last_error
	return last_operation_ok

func _unavailable() -> bool:
	last_operation_ok = false
	last_error = "当前冒险尚未就绪"
	return false
