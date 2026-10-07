extends SceneTree

const Quests = preload("res://rpg/quest_service.gd")
const State = preload("res://rpg/world_state.gd")
const Database = preload("res://combat/combat_database.gd")
const Inventory = preload("res://rpg/inventory_component.gd")
const Progression = preload("res://rpg/progression_component.gd")
const Loadout = preload("res://combat/loadout_component.gd")
const Stats = preload("res://combat/stats_component.gd")
const Resources = preload("res://combat/resource_component.gd")

class FixtureCombat extends Node:
	var actor: Node
	var state := "NORMAL"
	var base_poise := 50.0
	var current_poise := 50.0
	func can_start() -> bool: return state == "NORMAL"
	func max_poise() -> float: return base_poise
	func reset() -> void: state = "NORMAL"
	func context() -> Dictionary:
		var values: Dictionary = {}
		for key in Stats.IDS + ["Armor"]:
			values[key] = actor.stats.get_final_stat(key)
		return {"stats": values, "level": actor.loadout.level, "proficiencies": actor.loadout.proficiencies}

class Fixture extends Node:
	var stats: Node
	var resources: Node
	var loadout: Node
	var combat: Node
	var inventory: Node
	var progression: Node

var checks := 0
var failures: Array[String] = []
var db: RefCounted

func _initialize() -> void:
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func create_actor(choose := true) -> Fixture:
	var actor := Fixture.new()
	root.add_child(actor)
	actor.stats = Stats.new()
	actor.resources = Resources.new()
	actor.loadout = Loadout.new()
	actor.combat = FixtureCombat.new()
	actor.combat.actor = actor
	actor.inventory = Inventory.new()
	actor.progression = Progression.new()
	for component in [actor.stats, actor.resources, actor.loadout, actor.combat, actor.inventory, actor.progression]:
		actor.add_child(component)
	actor.loadout.setup(actor, db)
	actor.inventory.setup(actor, db)
	actor.progression.setup(actor, db, actor.inventory)
	actor.loadout.configure_progression(actor.inventory, actor.progression)
	actor.stats.changed.connect(actor.loadout.refresh_resources)
	actor.loadout._rebuild(true)
	if choose: actor.progression.choose_career("warrior")
	return actor

func catalog(objectives: Array, rewards: Dictionary = {}) -> Dictionary:
	return {"test": {"id": "test", "title": "测试委托", "description": "验证真实背包与成长规则", "objectives": objectives, "rewards": rewards}}

func kill_objective(retroactive := false) -> Dictionary:
	return {"id": "kill", "label": "击败士兵", "type": "event", "event": "enemy_defeated", "subject": "soldier", "target": 1, "retroactive": retroactive}

func run() -> void:
	db = Database.new()
	verify(db.errors.is_empty(), "真实内容目录有效")
	_story_and_restore()
	_delivery()
	_prerequisites_and_retroactive()
	_first_patrol_guidance()
	_validation()
	_xp_boundaries()
	_capacity_and_observers()
	_lifecycle()
	print("QUEST_SERVICE_RESULT checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _story_and_restore() -> void:
	var actor := create_actor()
	var state := State.new()
	var quests := Quests.new()
	verify(quests.setup(state, actor), "内置序章目录绑定真实角色")
	verify(quests.status("missing") == "unknown", "未知任务可安全查询")
	verify(quests.status("village_patrol") == "available" and quests.status("forest_investigation") == "locked", "序章前置锁定")
	state.record_event("enemy_defeated", "soldier", 1, "before_accept")
	verify(quests.accept("village_patrol") and quests.status("village_patrol") == "ready", "首巡逻认可探索期间已经击败的士兵")
	verify(not quests.accept("village_patrol"), "不能重接以重置起点")
	state.record_event("enemy_defeated", "heavy_guard")
	verify(quests.objective_progress("village_patrol")[0].current == 1, "其他怪物不增加首巡逻士兵计数")
	state.record_event("enemy_defeated", "soldier", 1, "after_accept")
	verify(quests.status("village_patrol") == "ready", "接取后击杀完成目标")
	var copy: Array[Dictionary] = quests.entries()
	copy[0].rewards.items.healing_potion = 999
	verify(int(quests.definition("village_patrol").rewards.items.healing_potion) == 2, "UI目录快照不能污染真实奖励")
	var before: int = actor.inventory.count("healing_potion")
	verify(quests.claim("village_patrol"), "首个任务正常领奖")
	verify(actor.inventory.count("healing_potion") == before + 2 and actor.progression.experience == 60, "任务物品与经验进入真实组件")
	verify(quests.status("village_patrol") == "rewarded" and quests.status("forest_investigation") == "available", "领奖后才解锁下一任务")
	var inventory_snapshot: Dictionary = actor.inventory.export_state()
	verify(not quests.claim("village_patrol") and actor.inventory.export_state() == inventory_snapshot, "重复领奖无副作用")
	verify(quests.accept("forest_investigation"), "接取调查任务")
	verify(state.get_flag("journal.tracked_quest") == "forest_investigation", "首巡逻领奖后接取调查自动承接有效追踪")
	verify(quests.objective_progress("forest_investigation")[0].current == 0, "第二任务不能借用第一任务期间击杀")
	state.record_event("enemy_defeated", "heavy_guard")
	state.record_event("enemy_defeated", "ogre")
	var world_snapshot: Dictionary = JSON.parse_string(JSON.stringify(state.export_state()))
	var restored_state := State.new()
	verify(restored_state.import_state(world_snapshot), "世界进度可以经过JSON保存恢复")
	var restored_actor := create_actor(false)
	restored_actor.inventory.import_state(actor.inventory.export_state())
	restored_actor.progression.import_state(actor.progression.export_state())
	restored_actor.loadout.import_state(actor.loadout.export_state())
	var restored := Quests.new()
	verify(restored.setup(restored_state, restored_actor), "新服务实例绑定恢复冒险")
	verify(restored.status("village_patrol") == "rewarded" and restored.status("forest_investigation") == "ready", "领奖状态与目标起点一并恢复")
	verify(not restored.claim("village_patrol"), "读档不能再次领首任务奖励")
	verify(restored.claim("forest_investigation"), "读档后未领奖任务能正常完成")
	verify(restored_actor.loadout.level == 2 and restored_actor.progression.experience == 140, "任务XP使用真实等级曲线")
	var fresh := Quests.new()
	verify(fresh.setup(State.new(), create_actor()), "另一个冒险独立初始化")
	verify(fresh.status("village_patrol") == "available" and fresh.status("forest_investigation") == "locked", "任务进度不跨冒险泄漏")
	verify(quests.status("forest_investigation") == "ready", "恢复副本不修改源冒险")

func _first_patrol_guidance() -> void:
	var actor := create_actor()
	var state := State.new()
	var quests := Quests.new()
	verify(quests.setup(state, actor), "首巡逻追踪夹具绑定内置目录")
	var observed: Array[Dictionary] = []
	var attempts: Array[bool] = []
	var on_object := func(_id: String):
		observed.append(state.export_state())
		attempts.append(quests.accept("village_patrol"))
	var on_flag := func(_id: String, _value: Variant): observed.append(state.export_state())
	state.object_changed.connect(on_object)
	state.flag_changed.connect(on_flag)
	verify(quests.accept("village_patrol"), "首次接取成功")
	verify(state.get_flag("journal.tracked_quest") == "village_patrol", "首次接取自动追踪巡逻")
	verify(observed.size() == 2 and observed.all(func(snapshot: Dictionary): return snapshot.objects.has("quest.village_patrol") and snapshot.flags.get("journal.tracked_quest") == "village_patrol"), "任务与追踪观察者只看到完整提交")
	verify(attempts == [false], "接取通知内不能重入接取")
	var selected := State.new()
	var selected_quests := Quests.new()
	var selected_catalog := {"village_patrol":quests.definition("village_patrol"), "test":catalog([kill_objective()]).test}
	verify(selected_quests.setup(selected, actor, selected_catalog) and selected_quests.accept("test"), "已有选择夹具先接受另一项有效任务")
	selected.set_flag("journal.tracked_quest", "test")
	verify(selected_quests.accept("village_patrol"), "已有追踪的冒险仍可接取首巡逻")
	verify(selected.get_flag("journal.tracked_quest") == "test", "自动追踪保留玩家已有选择")
	var dangling := State.new()
	dangling.set_flag("journal.tracked_quest", "missing_quest")
	var dangling_quests := Quests.new()
	verify(dangling_quests.setup(dangling, actor) and dangling_quests.accept("village_patrol") and dangling.get_flag("journal.tracked_quest") == "village_patrol", "接取任务替换悬空追踪")
	var full := State.new()
	var full_snapshot: Dictionary = full.export_state()
	for i in range(State.MAX_FLAGS): full_snapshot.flags["filled.%d" % i] = true
	verify(full.import_state(full_snapshot), "追踪容量夹具填满标记")
	var full_quests := Quests.new()
	verify(full_quests.setup(full, actor) and not full_quests.accept("village_patrol"), "无法一起保存追踪时接取整体失败")
	verify(full.export_state() == full_snapshot, "接取失败不遗留半个任务或追踪")
	var old := State.new()
	old.record_event("enemy_defeated", "soldier")
	old.set_object("quest.village_patrol", {"status":"active", "baselines":{"clear_soldiers":1}})
	var old_quests := Quests.new()
	verify(old_quests.setup(old, actor) and old_quests.status("village_patrol") == "active", "旧巡逻非零起点仍可读取且保留接取时进度")
	old.record_event("enemy_defeated", "soldier")
	verify(old_quests.status("village_patrol") == "ready", "旧巡逻仍由其接受后的击杀完成")
	var other := State.new()
	other.record_event("enemy_defeated", "soldier")
	other.set_object("quest.test", {"status":"active", "baselines":{"kill":1}})
	var other_quests := Quests.new()
	verify(not other_quests.setup(other, actor, catalog([kill_objective(true)])), "首巡逻兼容例外不放宽其他追溯任务")
	state.object_changed.disconnect(on_object)
	state.flag_changed.disconnect(on_flag)
	for service in [quests, selected_quests, dangling_quests, full_quests, old_quests, other_quests]: service.dispose()

func _delivery() -> void:
	var actor := create_actor()
	var state := State.new()
	var quests := Quests.new()
	var objective := {"id": "sword", "type": "inventory", "item": "iron_longsword", "label": "交付长剑", "target": 1, "consume": true}
	verify(quests.setup(state, actor, catalog([objective], {"items": {"healing_potion": 1}})) and quests.accept("test"), "交付委托接取")
	verify(actor.inventory.equipped_count("iron_longsword") == 1 and quests.objective_progress("test")[0].current == 0, "装备中的长剑不计入可交付数量")
	var snapshot: Dictionary = actor.inventory.export_state()
	verify(not quests.claim("test") and snapshot == actor.inventory.export_state(), "不可交付装备不会被消费")
	actor.inventory.add_item("iron_longsword")
	verify(quests.status("test") == "ready" and quests.claim("test"), "多余同类物品可交付")
	verify(actor.inventory.count("iron_longsword") == 1 and actor.loadout.sets[0].weapon == "iron_longsword", "交付后装备及其所有权完整")
	var duplicate := objective.duplicate(true)
	duplicate.id = "sword2"
	verify(quests.setup(State.new(), actor, catalog([objective, duplicate], {"items": {"iron_longsword": 1}})) and quests.accept("test"), "多目标同物品委托接取")
	actor.inventory.add_item("iron_longsword")
	snapshot = actor.inventory.export_state()
	verify(not quests.can_claim("test").is_empty() and not quests.claim("test"), "合计交付数量必须足够，不能重复计算同一副本")
	verify(snapshot == actor.inventory.export_state() and quests.status("test") != "rewarded", "合计校验失败不消费或记已领奖")
	actor.inventory.add_item("iron_longsword")
	verify(quests.claim("test") and actor.inventory.count("iron_longsword") == 2, "同物品两份交付与一份奖励合并正确")

func _prerequisites_and_retroactive() -> void:
	var actor := create_actor()
	var state := State.new()
	var quests := Quests.new()
	var definitions := catalog([kill_objective(true)])
	definitions.test.prerequisites = {"flags": {"warden.introduced": true}}
	verify(quests.setup(state, actor, definitions) and quests.status("test") == "locked", "剧情标记缺失时锁定")
	verify(not quests.accept("test"), "不能绕过剧情前置")
	state.set_flag("warden.introduced", false)
	verify(quests.status("test") == "locked", "剧情前置进行值比较而非只看存在")
	state.set_flag("warden.introduced", true)
	state.record_event("enemy_defeated", "soldier")
	verify(quests.accept("test") and quests.status("test") == "ready", "显式追溯任务可以计入先前击杀")
	var flag_goal := {"id": "report", "type": "flag", "flag": "report.confirmed", "value": "yes", "label": "报告消息", "target": 1}
	state = State.new()
	verify(quests.setup(state, actor, catalog([flag_goal])) and quests.accept("test"), "剧情标记目标接取")
	state.set_flag("report.confirmed", "yes")
	verify(quests.status("test") == "ready", "剧情标记推进目标")
	state.set_flag("report.confirmed", "no")
	verify(quests.status("test") == "active" and not quests.claim("test"), "尚未领奖的动态目标按实时值校验")

func _validation() -> void:
	var actor := create_actor()
	var state := State.new()
	var quests := Quests.new()
	var good := catalog([kill_objective()])
	verify(quests.setup(state, actor, good), "有效自定义目录")
	var bad := good.duplicate(true)
	bad.test.rewards = {"items": {"imaginary_item": 1}}
	verify(not quests.setup(State.new(), actor, bad) and not quests.errors.is_empty(), "拒绝目录不存在的物品并提供诊断")
	verify(quests.accept("test") and state.get_object("quest.test").status == "active", "失败setup保留先前目录与世界绑定")
	bad = good.duplicate(true)
	bad.test.objectives[0].subject = "imaginary_enemy"
	verify(not quests.setup(State.new(), actor, bad), "拒绝不存在的敌人")
	bad = good.duplicate(true)
	bad.test.objectives[0].target = 1.5
	verify(not quests.setup(State.new(), actor, bad), "拒绝小数目标数量")
	bad = good.duplicate(true)
	bad.test.rewards = {"experience": -1}
	verify(not quests.setup(State.new(), actor, bad), "拒绝负经验")
	bad = good.duplicate(true)
	bad.test.rewards = {"script": "arbitrary()"}
	verify(not quests.setup(State.new(), actor, bad), "奖励只允许声明式白名单字段")
	bad = good.duplicate(true)
	bad["second"] = good.test.duplicate(true)
	bad.second.id = "second"
	bad.second.prerequisites = {"quests": ["test"]}
	bad.test.prerequisites = {"quests": ["second"]}
	verify(not quests.setup(State.new(), actor, bad), "拒绝循环任务前置")
	var saved: Dictionary = state.export_state()
	var poisoned := saved.duplicate(true)
	poisoned.objects["quest.test"].status = "complete_maybe"
	verify(not quests.validate_state(poisoned).is_empty(), "拒绝未知存档任务状态")
	poisoned = saved.duplicate(true)
	poisoned.objects["quest.test"].baselines.kill = -1
	verify(not quests.validate_state(poisoned).is_empty(), "拒绝负数事件起点")
	poisoned = saved.duplicate(true)
	poisoned.objects["quest.test"].baselines.other = 0
	verify(not quests.validate_state(poisoned).is_empty(), "拒绝未知目标起点")
	poisoned = saved.duplicate(true)
	poisoned.objects["quest.test"].baselines.erase("kill")
	verify(not quests.validate_state(poisoned).is_empty(), "拒绝缺失目标起点")
	poisoned = saved.duplicate(true)
	poisoned.objects["quest.test"].status = "rewarded"
	verify(not quests.validate_state(poisoned).is_empty(), "不能把没有完成事件的任务伪装成已领奖")
	poisoned = saved.duplicate(true)
	poisoned.objects["quest.unknown"] = {"status": "rewarded", "baselines": {}}
	verify(not quests.validate_state(poisoned).is_empty(), "未知历史任务必须先迁移")
	verify(quests.validate_state(saved).is_empty() and state.export_state() == saved, "读档预检完全不改变当前冒险")
	var corrupted := State.new()
	corrupted.import_state(poisoned)
	verify(not quests.setup(corrupted, actor, good), "setup也拒绝未知任务存档")

func _xp_boundaries() -> void:
	var actor := create_actor(false)
	var state := State.new()
	var quests := Quests.new()
	var definitions := catalog([kill_objective()], {"experience": 60, "items": {"healing_potion": 1}})
	verify(quests.setup(state, actor, definitions) and quests.accept("test"), "Lv0可接任务")
	state.record_event("enemy_defeated", "soldier")
	var before: Dictionary = actor.inventory.export_state()
	verify(not quests.claim("test") and actor.inventory.export_state() == before and quests.status("test") == "ready", "Lv0领取XP受阻且不丢失奖励")
	actor.progression.choose_career("warrior")
	verify(quests.claim("test") and actor.progression.experience == 60, "选职后可正常领奖")
	actor.loadout.level = actor.progression.max_level()
	actor.progression.experience = 0
	state = State.new()
	verify(quests.setup(state, actor, definitions) and quests.accept("test"), "满级冒险可接任务")
	state.record_event("enemy_defeated", "soldier")
	var potions: int = actor.inventory.count("healing_potion")
	verify(quests.claim("test") and actor.inventory.count("healing_potion") == potions + 1 and actor.progression.experience == 0, "满级不积累XP，物品奖励仍正常领取")
	actor.loadout.level = 9
	actor.progression.experience = 490
	state = State.new()
	quests.setup(state, actor, definitions)
	quests.accept("test")
	state.record_event("enemy_defeated", "soldier")
	verify(quests.claim("test") and actor.loadout.level == 10 and actor.progression.experience == 0, "跨越满级时清除溢出XP")

func _capacity_and_observers() -> void:
	var actor := create_actor()
	var state := State.new()
	var quests := Quests.new()
	var definitions := catalog([kill_objective()], {"experience": 120, "items": {"healing_potion": 1}})
	quests.setup(state, actor, definitions)
	quests.accept("test")
	state.record_event("enemy_defeated", "soldier")
	var saturated: Dictionary = state.export_state()
	for index in range(256): saturated.flags["pad" + str(index)] = "x".repeat(4000)
	var index := 0
	while State.MAX_STATE_BYTES - JSON.stringify(saturated).to_utf8_buffer().size() > 4020:
		saturated.flags["extra" + str(index)] = "x".repeat(4000)
		index += 1
	saturated.flags["tail"] = ""
	var remaining: int = State.MAX_STATE_BYTES - JSON.stringify(saturated).to_utf8_buffer().size()
	saturated.flags.tail = "x".repeat(remaining)
	verify(state.import_state(saturated), "准备恰好达到世界存档字节上限的真实状态")
	var inventory_before: Dictionary = actor.inventory.export_state()
	verify(not quests.can_claim("test").is_empty() and not quests.claim("test"), "领奖前校验状态增长所需存档容量")
	verify(actor.inventory.export_state() == inventory_before and actor.progression.experience == 0 and quests.status("test") == "ready", "容量不足既不发物品XP也不记已领奖")
	state = State.new()
	quests.setup(state, actor, definitions)
	quests.accept("test")
	state.record_event("enemy_defeated", "soldier")
	var potion_before: int = actor.inventory.count("healing_potion")
	var observations: Array[bool] = []
	actor.inventory.changed.connect(func():
		observations.append(quests.status("test") == "rewarded" and actor.inventory.count("healing_potion") == potion_before + 1 and actor.loadout.level == 2 and actor.progression.experience == 20)
		observations.append(not quests.claim("test")))
	verify(quests.claim("test"), "有效交易成功")
	verify(observations.size() == 2 and observations.all(func(value): return value), "同步观察者只看见完整奖励且不能重入领奖")
	var inventory_copy: Dictionary = actor.inventory.export_state()
	actor.inventory.stacks.healing_potion = Quests.MAX_QUANTITY
	state = State.new()
	quests.setup(state, actor, definitions)
	quests.accept("test")
	state.record_event("enemy_defeated", "soldier")
	verify(not quests.claim("test") and actor.inventory.count("healing_potion") == Quests.MAX_QUANTITY, "物品数量溢出在任何奖励修改之前拒绝")
	actor.inventory.stacks = inventory_copy.stacks

func _lifecycle() -> void:
	var actor := create_actor()
	var first := State.new()
	var second := State.new()
	var quests := Quests.new()
	quests.setup(first, actor)
	var notifications: Array[bool] = []
	quests.changed.connect(func(): notifications.append(true))
	quests.setup(second, actor)
	first.record_event("enemy_defeated", "soldier")
	verify(notifications.is_empty(), "重新绑定冒险后旧世界不再触发刷新")
	second.record_event("enemy_defeated", "soldier")
	verify(notifications.size() == 1, "重复setup不重复连接信号")
	quests.dispose()
	quests.dispose()
	second.record_event("enemy_defeated", "soldier")
	actor.inventory.add_item("healing_potion")
	verify(notifications.size() == 1 and quests.status("village_patrol") == "unknown", "dispose可重复调用并释放全部依赖连接")
