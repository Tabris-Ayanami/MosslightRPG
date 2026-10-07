extends RefCounted
const NPC = preload("res://rpg/npc_actor.gd")
const PATH := "res://data/world/npcs.json"

static func populate(game: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(PATH)) != OK or not parser.data is Dictionary:
		push_error("NPC 目录无法读取")
		return result
	for id in parser.data:
		var data: Dictionary = parser.data[id]
		if data.get("id", "") != id or not data.get("position") is Array or data.position.size() != 3:
			push_error("NPC 定义无效：" + str(id))
			continue
		var shop_id := str(data.get("shop_id", ""))
		if not shop_id.is_empty():
			if game.economy.definition(shop_id).is_empty():
				push_error("NPC 引用未知商店：" + str(id))
				continue
		elif not str(data.get("dialogue", "")).begins_with("res://data/dialogue/") or not ResourceLoader.exists(data.dialogue):
			push_error("NPC 缺少已导入的对话：" + str(id))
			continue
		var npc := NPC.new()
		npc.name = str(id)
		npc.configure(game, data)
		npc.position = game.GARDEN_ORIGIN + Vector3(data.position[0], data.position[1], data.position[2])
		game.world.add_child(npc)
		result.append(npc)
	return result
