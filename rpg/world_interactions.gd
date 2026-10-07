extends RefCounted
## Shared validation and atomic one-shot rewards for contextual actions.
const Guard = preload("res://rpg/mutation_guard.gd")
const Readiness = preload("res://rpg/interaction_readiness.gd")
const WorldState = preload("res://rpg/world_state.gd")
const LADDER_ID := "interaction.ladder.village_house_3"
const OWNER := "context_interaction"
const REACH := 2.15
var game: Node
var last_error := ""
var rng := RandomNumberGenerator.new()

func setup(host: Node) -> void:
	game=host
	rng.randomize()

func actions(prop: Node3D) -> Array[Dictionary]:
	if not is_instance_valid(prop): return []
	if prop.get("rest_kind") != null and is_instance_valid(game.rest_service): return game.rest_service.actions(prop)
	if prop.is_in_group("narrative_npcs"):
		if prop.hostile or prop.dead:
			# Essential villagers remain reachable through the same physical F
			# menu, including old saves that already recorded their defeat.
			if prop.has_method("is_essential") and prop.is_essential():
				return [{"id":"reconcile","label":"救助并致歉 · 免费" if prop.dead else "认错 · 保证不再偷窃"}]
			return []
		var result: Array[Dictionary]=[{"id":"talk","label":"交谈"}]
		if not str(prop.definition.get("shop_id","")).is_empty(): result.append({"id":"trade","label":"交易"})
		var spent: bool=game.world_state.get_object(prop.social_id()).get("attempted",false)
		result.append({"id":"steal","label":"已无可窃取之物" if spent else "偷窃","enabled":not spent})
		return result
	if prop.has_method("bottom_anchor"):
		if prop.dismantled: return []
		return [{"id":"climb","label":"攀爬"},{"id":"dismantle","label":"拆除 · 木材 ×3"}]
	var label: String={"chest":"打开宝箱","shrine":"休憩 · 记录","gate":"开启试炼","sign":"阅读"}.get(str(prop.get("kind")),"交互")
	return [{"id":"interact","label":label}]

func anchor(prop: Node3D) -> Vector3:
	if prop.has_method("bottom_anchor"):
		var actor: Node=game.controlled_actor()
		var point: Vector3=prop.top_anchor() if actor.global_position.distance_to(prop.top_exit())<actor.global_position.distance_to(prop.bottom_exit()) else prop.bottom_anchor()
		if actor.ladder.active: point=actor.global_position
		return point+Vector3.UP*1.05
	return prop.global_position+Vector3.UP*(1.45 if prop.is_in_group("narrative_npcs") else .95)

func available(prop: Node3D) -> bool:
	return is_instance_valid(prop) and prop.is_visible_in_tree() and not actions(prop).is_empty()

func within_reach(prop: Node3D, actor: Node3D) -> bool:
	if not available(prop) or not is_instance_valid(actor) or prop.get_world_3d()!=actor.get_world_3d(): return false
	var distance: float=prop.interaction_distance(actor.global_position) if prop.has_method("interaction_distance") else prop.global_position.distance_to(actor.global_position)
	return distance<=REACH

func _error(prop: Node3D) -> String:
	if not is_instance_valid(game) or not is_instance_valid(prop) or not prop.is_inside_tree(): return "目标已离开"
	if Guard.busy(game.world_state): return "冒险正在更新，请稍候"
	if game.paused or game.get_tree().paused: return "请先结束当前操作"
	var actor: Node=game.controlled_actor()
	if not Readiness.can_manage(actor) or not actor.is_human_controlled(): return "当前无法交互"
	if prop.get_world_3d()!=actor.get_world_3d(): return "目标不在附近"
	var distance: float=prop.interaction_distance(actor.global_position) if prop.has_method("interaction_distance") else prop.global_position.distance_to(actor.global_position)
	if distance>REACH: return "请靠近再交互"
	if not available(prop): return "当前无法与此目标交互"
	return ""

func execute(prop: Node3D, id: String) -> bool:
	if id=="leave_ladder":
		if is_instance_valid(prop) and not game.paused and game.controlled_actor().ladder.active_ladder==prop:
			game.controlled_actor().ladder.detach("manual",true)
			return true
		return false
	last_error=_error(prop)
	if not last_error.is_empty(): return _fail(last_error)
	var allowed:=false
	for action in actions(prop):
		if action.id==id and action.get("enabled",true): allowed=true
	if not allowed: return _fail("此操作已不可用")
	game.last_interaction=prop
	if prop.get("rest_kind") != null: return game.rest_service.execute(prop,id)
	match id:
		"talk": return game.begin_dialogue(prop.definition,prop)
		"trade": return game.begin_shop(prop)
		"climb": return game.controlled_actor().ladder.try_interact(prop)
		"steal": return _steal(prop)
		"reconcile": return _reconcile(prop)
		"dismantle": return _dismantle(prop)
		"interact":
			prop.interact(game)
			return true
	return false

func _steal(npc: Node3D) -> bool:
	if npc not in game.narrative_npcs or game.controlled_actor()!=game.player: return _fail("请先回到自己的身体")
	if game.player.combat.in_combat: return _fail("战斗中无法偷窃")
	var record: Dictionary=game.world_state.get_object(npc.social_id())
	if record.get("attempted",false): return _fail("已经没有可窃取的东西了")
	var caught:=rng.randf()<.42
	var items: Dictionary={} if caught else {"healing_potion":1}
	var next: Dictionary={"version":1,"kind":"npc","attempted":true,"hostile":caught,"defeated":false}
	if not _commit(npc.social_id(),next,items): return false
	if caught:
		game.notify("%s发现了你的手！ · 对方已敌对" % npc.display_name,Color("e7ad93"))
		npc.combat.engage()
		game.player.combat.engage()
	else: game.notify("悄悄取得 · 生命药水 ×1",Color("e8d6a3"))
	return true

func _reconcile(npc: Node3D) -> bool:
	var reason := _error(npc)
	if not reason.is_empty(): return _fail(reason)
	if npc not in game.narrative_npcs or not npc.has_method("is_essential") or not npc.is_essential():
		return _fail("这位村民无法通过此方式和解")
	if game.controlled_actor()!=game.player or game.player.form.active:
		return _fail("请先恢复自己的身体，再向村民致歉")
	var record: Dictionary=game.world_state.get_object(npc.social_id())
	if not record.get("hostile",false): return _fail("已经与这位村民和解")
	var was_defeated: bool=record.get("defeated",false) or npc.dead
	# No fee or required item: an empty inventory must never close the only
	# main-story/shop entrance. The spent theft opportunity stays spent.
	var next: Dictionary=record.duplicate(true)
	next.hostile=false
	next.defeated=false
	if not _commit(npc.social_id(),next,{}): return false
	game.notify(("你为%s包扎并致歉 · 对方已回到岗位，偷窃机会不会恢复" if was_defeated else "%s接受了你的保证 · 已回到岗位，偷窃机会不会恢复") % npc.display_name,Color("e8d6a3"))
	return true

func _dismantle(prop: Node3D) -> bool:
	if str(prop.get("persistent_id"))!=LADDER_ID: return _fail("这架梯子无法拆除")
	if game.controlled_actor()!=game.player: return _fail("请先回到自己的身体")
	for actor in game.combat_world.units():
		if actor.ladder.active and actor.ladder.active_ladder==prop: return _fail("有人正在攀爬，暂时不能拆除")
	if game.world_state.get_object(LADDER_ID).get("dismantled",false): return _fail("木梯已经拆除了")
	if not _commit(LADDER_ID,{"version":1,"kind":"ladder","dismantled":true},{"wood":3}): return false
	game.notify("拆下木梯 · 获得木材 ×3",Color("e8d6a3"))
	return true

func _commit(id: String, record: Dictionary, items: Dictionary) -> bool:
	var candidate: Dictionary=game.world_state.export_state()
	candidate.objects[id]=record
	var reason:=validate_snapshot(candidate)
	if not reason.is_empty(): return _fail(reason)
	var stacks: Dictionary=game.player.inventory.stacks.duplicate(true)
	for item in items:
		var count:=int(stacks.get(item,0))+int(items[item])
		if game.player.inventory.definition(item).is_empty() or count>1000000: return _fail("行囊已无法容纳这些物品")
		stacks[item]=count
	if not Guard.acquire(game.world_state,OWNER): return _fail("冒险正在更新")
	if not game.world_state.import_state(candidate):
		Guard.release(game.world_state,OWNER)
		return _fail(game.world_state.last_error)
	game.player.inventory.stacks=stacks
	refresh()
	if not items.is_empty(): game.player.inventory.changed.emit()
	game.world_state.object_changed.emit(id)
	Guard.release(game.world_state,OWNER)
	# Reentrant observers can set last_error while the successful transaction is
	# still publishing. The outer committed operation owns its final result.
	last_error=""
	return true

func npc_defeated(npc: Node3D) -> void:
	if not is_instance_valid(npc) or not npc.hostile: return
	var record: Dictionary=game.world_state.get_object(npc.social_id())
	if record.get("defeated",false): return
	record.defeated=true
	if _commit(npc.social_id(),record,{}): game.notify("%s已失去战斗能力" % npc.display_name)

func refresh() -> void:
	for npc in game.narrative_npcs:
		if is_instance_valid(npc): npc.apply_social_state(game.world_state.get_object(npc.social_id()))
	for prop in game.get_tree().get_nodes_in_group("village_ladders"):
		if prop.get_world_3d()==game.player.get_world_3d():
			prop.apply_dismantled(game.world_state.get_object(prop.persistent_id).get("dismantled",false))

static func validate_snapshot(snapshot: Dictionary) -> String:
	var reason: String=WorldState.new().validate_state(snapshot)
	if not reason.is_empty(): return reason
	var catalog: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/world/npcs.json"))
	for id: String in snapshot.objects:
		if not id.begins_with("interaction."): continue
		var record: Dictionary=snapshot.objects[id]
		if record.get("version")!=1: return "交互状态版本无效"
		if id==LADDER_ID:
			if record.size()!=3 or record.get("kind")!="ladder" or not record.get("dismantled") is bool: return "木梯状态无效"
		elif id.begins_with("interaction.npc.") and catalog.has(id.trim_prefix("interaction.npc.")):
			if record.size()!=5 or record.get("kind")!="npc": return "村民状态无效"
			for field in ["attempted","hostile","defeated"]:
				if not record.get(field) is bool: return "村民状态无效"
			if record.hostile and not record.attempted or record.defeated and not record.hostile: return "村民状态不一致"
		else: return "未知交互对象"
	return ""

func _fail(reason: String) -> bool:
	last_error=reason
	if is_instance_valid(game): game.notify(reason)
	return false
