extends Node
## Rest, time, room payments and encounter generations share one world commit.
signal rested(kind: String)
const Guard = preload("res://rpg/mutation_guard.gd")
const Readiness = preload("res://rpg/interaction_readiness.gd")
const Inn = preload("res://rpg/inn_room.gd")
const CLOCK := "rest.clock"
const LODGING := "rest.lodging"
const RENT := 15
var game: Node
var places: Dictionary = {}
var last_error := ""
var _seconds := 0.0
var _sleep := 0.0
var _was_inside := false
var _outdoor_zoom := 18.0
var _indoor_environment: Environment

func setup(host: Node) -> void:
	game = host
	places = Inn.build(game)
	_indoor_environment=game.garden_environment.duplicate()
	_indoor_environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	_indoor_environment.ambient_light_color=Color("c8b594")
	_indoor_environment.ambient_light_energy=.65
	game.weather.keyboard_preview = false
	game.weather.automatic_day_cycle = true
	refresh()

func clock() -> Dictionary:
	var value: Dictionary = game.world_state.get_object(CLOCK)
	return value if not value.is_empty() else {"version":1,"day":1,"minute":720}

func lodging() -> Dictionary:
	var value: Dictionary = game.world_state.get_object(LODGING)
	return value if not value.is_empty() else {"version":1,"paid_day":0}

func inside() -> bool:
	return game.player.global_position.distance_to(Inn.ROOM)<12.0

func date_text() -> String:
	var now := clock()
	var minute := int(now.minute)
	var phase := "白天" if minute>=360 and minute<1080 else ("黄昏" if minute>=1080 and minute<1200 else "夜晚")
	return "第 %d 日 · %s  %02d:%02d" % [now.day,phase,minute/60,minute%60]

func _process(delta: float) -> void:
	if not is_instance_valid(game) or game.paused or not game.player.is_physics_processing(): return
	if _sleep>0:
		_sleep=maxf(0,_sleep-delta)
		if _sleep==0: game.player.set_meta("rest_pose",""); game.player.set_meta("traversal_locked",false)
	else:
		_seconds += delta
		if _seconds>=1.0 and not Guard.busy(game.world_state):
			var minutes := floori(_seconds)
			_seconds -= minutes
			var now := clock()
			now.minute = int(now.minute)+minutes
			now.day = int(now.day)+int(now.minute/1440)
			now.minute = int(now.minute)%1440
			game.world_state.set_object(CLOCK,now)
			game.weather.hour = float(now.minute)/60.0
	if inside()!=_was_inside: refresh()

func refresh() -> void:
	_seconds=0
	_sleep=0
	game.player.set_meta("rest_pose","")
	game.player.set_meta("traversal_locked",false)
	var now_inside := inside()
	if now_inside and not _was_inside:
		_outdoor_zoom=game.target_camera_height
		game.target_camera_height=11.0
	elif not now_inside and _was_inside: game.target_camera_height=_outdoor_zoom
	_was_inside=now_inside
	places.room.visible=_was_inside
	game.camera.environment=_indoor_environment if _was_inside else game.garden_environment
	game.weather.effects.visible=not _was_inside
	game.weather.automatic_day_cycle=true
	game.weather.day_length_seconds=1440.0
	game.weather.hour=float(clock().minute)/60.0
	game.weather._apply_environment()

func actions(place: Node3D) -> Array[Dictionary]:
	var paid := int(lodging().paid_day)==int(clock().day)
	match place.rest_kind:
		"inn": return [{"id":"room_enter" if paid else "room_rent","label":"进入已租客房" if paid else "租客房 · 铜币 15"}]
		"exit": return [{"id":"room_exit","label":"返回风铃村"}]
		"bed":
			if not paid: return [{"id":"room_rent","label":"续租 · 铜币 15"}]
			return [{"id":"rest_long","label":"长休 · 次日全恢复"},{"id":"rest_short","label":"短休 · 恢复一半"}]
		"tree": return [{"id":"rest_short","label":"倚树短休 · 记录"}]
	return []

func execute(place: Node3D, action: String) -> bool:
	var actor: Node = game.player
	if Guard.busy(game.world_state) or _sleep>0: return _fail("正在休息，请稍候")
	if game.controlled_actor()!=actor or actor.form.active: return _fail("请回到自己的身体后再休息")
	if not Readiness.can_manage(actor) or not game.interactions.within_reach(place,actor): return _fail("请靠近休息地点并停下动作")
	var allowed := false
	for option in actions(place):
		if option.id==action: allowed=true
	if not allowed: return _fail("此休息选项当前不可用")
	if action!="room_exit":
		if actor.combat.in_combat: return _fail("战斗尚未结束，无法休息")
		for enemy in game.combat_world.targets_for(actor):
			if enemy.global_position.distance_to(actor.global_position)<12 or enemy.current_target==actor and enemy.combat.in_combat:
				return _fail("附近有敌人警戒，请先到安全处")
	var candidate: Dictionary = game.world_state.export_state()
	var now := clock()
	var next_position: Vector3 = actor.global_position
	if action=="room_rent":
		var wallet: Dictionary = candidate.objects.get("economy.wallet",{"version":1,"balance":0,"revision":0}).duplicate(true)
		if int(wallet.balance)<RENT: return _fail("租房需要 15 枚铜币")
		if int(wallet.revision)>=2147483647: return _fail("钱包记录已达上限")
		wallet.balance=int(wallet.balance)-RENT
		wallet.revision=int(wallet.revision)+1
		candidate.objects["economy.wallet"]=wallet
		candidate.objects[LODGING]={"version":1,"paid_day":int(now.day)}
	if action in ["room_enter","room_rent"]: next_position=Inn.ROOM+Vector3(0,.08,2.6)
	if action=="room_exit": next_position=Inn.DOOR+Vector3(1.2,.05,1.2)
	if action=="rest_long":
		now.day=int(now.day)+1
		now.minute=480
	elif action=="rest_short":
		if int(now.minute)<360: now.minute=480
		elif int(now.minute)<1080: now.minute=1080
		elif int(now.minute)<1200: now.minute=1320
		else: now.day=int(now.day)+1; now.minute=480
		var respawn: Dictionary = game.encounters.plan_short_rest(candidate)
		if not respawn.ok: return _fail(respawn.error)
		candidate=respawn.world
	candidate.objects[CLOCK]=now
	var error := validate_snapshot(candidate)
	if not error.is_empty(): return _fail(error)
	if not Guard.acquire(game.world_state,"rest"): return _fail("冒险状态正在更新")
	if not game.world_state.import_state(candidate):
		Guard.release(game.world_state,"rest")
		return _fail(game.world_state.last_error)
	actor.input_router.cancel()
	actor.attack_assist.leap.clear()
	actor.global_position=next_position
	actor.velocity=Vector3.ZERO
	game.smooth_target=next_position+game._camera_lead()
	refresh()
	if action in ["rest_short","rest_long"]:
		game.checkpoint=actor.global_position
		actor.spawn_point=game.checkpoint
		var blocked: bool = actor.resources.is_blocking_signals()
		actor.resources.set_block_signals(true)
		if action=="rest_long": actor.combat.reset()
		else:
			for id in ["HP","Energy"]: actor.resources.change(id,actor.resources.max_value(id)*.5)
			actor.resources.change("Stamina",actor.resources.max_value("Stamina"))
		actor.resources.set_block_signals(blocked)
		if action=="rest_short": game.combat_world.refresh_after_short_rest()
		_sleep=1.6
		actor.set_meta("traversal_locked",true)
		actor.set_meta("rest_pose","tree" if place.rest_kind=="tree" else "bed")
		for id in ["HP","Energy","Stamina"]: actor.resources.resource_changed.emit(id,actor.resources.current(id),actor.resources.max_value(id))
		game.notify(("长休结束 · 状态回满" if action=="rest_long" else "短休结束 · 回复一半生命与能量，野外重新出现敌人")+" · 记录点已保存")
	else:
		game.notify("返回风铃村" if action=="room_exit" else "风铃旅馆 · 客房内对床按 F，滚轮可选长休或短休")
	game.world_state.object_changed.emit(CLOCK)
	game.economy.changed.emit()
	Guard.release(game.world_state,"rest")
	if action in ["rest_short","rest_long"]: rested.emit(action)
	last_error=""
	return true

func _fail(message: String) -> bool:
	last_error=message
	game.notify(message)
	return false

static func validate_snapshot(snapshot: Dictionary) -> String:
	for id: String in snapshot.get("objects",{}):
		if not id.begins_with("rest."): continue
		var value: Dictionary = snapshot.objects[id]
		if id==CLOCK:
			if value.size()!=3 or value.get("version")!=1 or not _integer(value.get("day"),1,1000000) or not _integer(value.get("minute"),0,1439): return "游戏日期记录无效"
		elif id==LODGING:
			if value.size()!=2 or value.get("version")!=1 or not _integer(value.get("paid_day"),0,1000000): return "旅馆租住记录无效"
		else: return "未知休息记录"
	return ""

static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value)==floorf(float(value)) and value>=minimum and value<=maximum
