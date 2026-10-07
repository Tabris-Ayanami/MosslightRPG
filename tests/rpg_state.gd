extends SceneTree

const Database = preload("res://combat/combat_database.gd")
const Inventory = preload("res://rpg/inventory_component.gd")
const Progression = preload("res://rpg/progression_component.gd")
const Loadout = preload("res://combat/loadout_component.gd")

class FixtureCombat extends Node:
	var actor: Node
	var state := "NORMAL"
	var base_poise := 50.0
	var current_poise := 50.0
	var last_condition_failed := ""
	var action_count := 0
	var block_action := false
	func can_start() -> bool:
		return state == "NORMAL"
	func context() -> Dictionary:
		var values: Dictionary = {}
		for key in CombatStats.IDS + ["Armor"]:
			values[key] = actor.stats.get_final_stat(key)
		return {"stats": values, "level": actor.loadout.level, "proficiencies": actor.loadout.proficiencies}
	func has_permission(_id: String) -> bool:
		return false
	func max_poise() -> float:
		return base_poise
	func reset() -> void:
		state = "NORMAL"
		actor.resources.restore_all()
	func action_failure(_action: Dictionary) -> String:
		return "动作被拒绝" if block_action else ""
	func use_action(action: Dictionary) -> bool:
		last_condition_failed = action_failure(action)
		if not last_condition_failed.is_empty():
			return false
		action_count += 1
		return true

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
	if not ok:
		failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func create_actor() -> Fixture:
	var actor := Fixture.new()
	root.add_child(actor)
	actor.stats = CombatStats.new()
	actor.resources = CombatResources.new()
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
	return actor

func run() -> void:
	db = Database.new()
	verify(db.errors.is_empty(), "所有战斗与RPG目录有效")
	verify(db.items.values().filter(func(item): return item.get("category", "") == "consumable").size() == 5 and db.progression.rules.max_level == 20 and db.progression.rules.first_map_max_level == 5, "五消耗品、首图Lv5与全局Lv20上限")
	var all_drops: Dictionary = {}
	for enemy in db.enemies:
		verify(db.progression.has(enemy), "敌人奖励已配置: " + enemy)
		for id in db.progression[enemy].equipment_rotation:
			all_drops[id] = true
	for id in db.weapons.keys() + db.equipment.keys():
		verify(all_drops.has(id), "已有装备可从击杀轮换获得: " + id)
	var actor := create_actor()
	verify(actor.loadout.level == 0 and actor.inventory.stacks.is_empty(), "正式角色Lv0且不提前领物资")
	verify(not actor.progression.level_up(), "Lv0糖果不能绕过选职")
	verify(actor.progression.career_options().size() == 4, "Lv0四基础职业")
	verify(actor.progression.choose_career("warrior"), "首次选战士成功")
	verify(actor.loadout.level == 1 and actor.progression.starter_granted, "选職Lv1并记首次发放")
	verify(actor.inventory.count("magic_candy") == 0 and actor.inventory.count("iron_longsword") == 1 and actor.inventory.count("hunter_dagger") == 1, "初始两武器入真实库存但不发调试糖果")
	verify(actor.loadout.equipment.head == "scout_hood" and actor.loadout.equipment.torso == "linen_tunic", "初始四部位自动穿戴")
	verify(actor.stats.get_final_stat("PER") == actor.stats.get_stat("PER") + 1 and actor.stats.get_final_stat("CHA") == actor.stats.get_stat("CHA") + 1, "装备实际修正六维属性")
	verify(actor.loadout.available_skills.size() == 4 and actor.loadout.unlocked_skills.is_empty(), "职业技能可学但未自动学会")
	verify(actor.loadout.sets[0].skills == ["", "", ""] and actor.loadout.sets[1].skills == ["", "", ""], "未学习不能保留推荐QER")
	var initial: Dictionary = actor.inventory.stacks.duplicate(true)
	verify(not actor.progression.choose_career("rogue") and not actor.loadout.select_career("warrior"), "基础职业本局锁定且不能重复选择")
	verify(actor.inventory.stacks == initial, "换职失败不复制或清空背包")
	verify(not actor.loadout.assign_skill(0, 0, "warrior_whirlwind"), "未学技能不可装备")
	verify(not actor.progression.learn_skill("mage_fireball"), "外职业技能不可学习")
	verify(actor.progression.learn_skill("warrior_whirlwind"), "职业技能免费手动学习")
	verify(not actor.progression.learn_skill("warrior_whirlwind"), "重复学习拒绝")
	verify(actor.loadout.assign_skill(0, 0, "warrior_whirlwind") and actor.loadout.assign_skill(1, 1, "warrior_whirlwind"), "已学技能可分别配置A/B")
	verify(not actor.loadout.can_equip_set_weapon(0, "azure_katana").is_empty(), "无所有权武器不能装备")
	verify(not actor.loadout.equip_item("ring1", "qi_ring"), "无所有权护具不能装备")
	verify(not actor.loadout.equip_weapon(1, "iron_longsword"), "同型号仅1件不能占两组")
	verify(actor.inventory.add_item("iron_longsword") and actor.loadout.equip_weapon(1, "iron_longsword"), "两件同型号可分别配置两组")
	verify(not actor.inventory.remove_item("iron_longsword"), "不能移除已装备数量")
	verify(actor.loadout.equip_weapon(1, "") and actor.inventory.remove_item("iron_longsword"), "卸装后可移除空闲武器")
	verify(actor.loadout.equip_weapon(1, "hunter_dagger"), "备用武器仍保有所有权")
	actor.inventory.add_item("hunter_ring", 2)
	verify(actor.loadout.equip_item("ring1", "hunter_ring") and actor.loadout.equip_item("ring2", "hunter_ring"), "两件同型号戒指按数量占两个槽")
	verify(actor.inventory.equipped_count("hunter_ring") == 2 and not actor.inventory.remove_item("hunter_ring"), "装备占用与库存数量一致")
	var potion_count: int = actor.inventory.count("healing_potion")
	verify(not actor.inventory.use_item("healing_potion") and actor.inventory.count("healing_potion") == potion_count, "满血药水拒绝且不扣")
	actor.resources.change("HP", -500)
	var hp: float = actor.resources.current("HP")
	var maximum: float = actor.resources.max_value("HP")
	verify(actor.inventory.use_item("healing_potion"), "受伤后药水成功")
	verify(is_equal_approx(actor.resources.current("HP"), minf(maximum, hp + maximum * .3)) and actor.inventory.count("healing_potion") == potion_count - 1, "药水恢复30%并只扣一件")
	verify(actor.inventory.assign_quick_slot(1, "healing_potion") and not actor.inventory.use_quick_slot(1), "同物品跨快捷栏共享冷却")
	verify(actor.inventory.count("healing_potion") == potion_count - 1, "冷却拒绝不扣物品")
	actor.inventory.tick(4.0)
	verify(actor.inventory.use_quick_slot(1), "冷却结束可再用快捷栏")
	verify(not actor.inventory.assign_quick_slot(4, "healing_potion") and not actor.inventory.assign_quick_slot(0, "iron_longsword"), "四快捷槽且仅可配消耗品")
	var energy_max: float = actor.resources.max_value("Energy")
	var small_potions: int = actor.inventory.count("spell_potion")
	actor.resources.configure("Energy", 0)
	verify(not actor.inventory.use_item("spell_potion") and actor.inventory.count("spell_potion") == small_potions, "无能量上限时药水拒绝且不消耗")
	actor.resources.configure("Energy", energy_max)
	actor.resources.change("Energy", -20)
	var large_potions: int = actor.inventory.count("qi_potion")
	verify(float(db.items.qi_potion.amount) == 40 and actor.inventory.use_item("qi_potion") and actor.resources.current("Energy") == energy_max and actor.inventory.count("qi_potion") == large_potions - 1, "大能量药恢复40并按上限截断且只消耗一瓶")
	actor.combat.block_action = true
	var bomb_count: int = actor.inventory.count("fire_bomb")
	verify(not actor.inventory.use_item("fire_bomb") and actor.inventory.count("fire_bomb") == bomb_count, "攻击物品前置失败不消费")
	actor.combat.block_action = false
	verify(actor.inventory.use_item("fire_bomb") and actor.combat.action_count == 1 and actor.inventory.count("fire_bomb") == bomb_count - 1, "攻击物品委托一次动作成功后消费")
	var equipment_before: Dictionary = actor.loadout.equipment.duplicate(true)
	var learned_before: Array = actor.loadout.learned_skills.duplicate()
	hp = actor.resources.current("HP")
	verify(actor.progression.add_experience(99) and actor.loadout.level == 1 and actor.progression.experience == 99, "经验未到阈值不升级")
	verify(actor.progression.add_experience(1) and actor.loadout.level == 2 and actor.progression.experience == 0, "100经验精确升Lv2")
	verify(actor.resources.current("HP") == hp and actor.loadout.equipment == equipment_before and actor.loadout.learned_skills == learned_before, "升级保留现有资源装备已学技能")
	verify(actor.loadout.sets[0].skills[0] == "warrior_whirlwind", "升级不清备战技能")
	verify(actor.progression.choose_career("swordsman"), "Lv2合法进阶剑士")
	verify(actor.loadout.level == 2 and actor.loadout.career_ids == ["warrior", "swordsman"] and actor.stats.get_stat("STR") == 13, "进阶保留基础属性和等级")
	verify(actor.progression.learn_skill("swordsman_fan_slash"), "进阶后新增技能可学")
	actor.progression.add_experience(350)
	verify(actor.loadout.level == 4 and actor.progression.experience == 0, "大额经验可跨多级且逐级扣阈值")
	verify(actor.inventory.add_item("magic_candy", 9), "升级道具测试显式注入九颗调试糖果")
	verify(actor.inventory.use_item("magic_candy") and actor.loadout.level == 5, "首图糖果只升至Lv5")
	var capped_count: int = actor.inventory.count("magic_candy")
	verify(not actor.inventory.use_item("magic_candy") and actor.inventory.count("magic_candy") == capped_count, "首图满级不消费糖果")
	# Isolate later-chapter progression to verify the preserved Lv10 career chain
	# and the global Lv20 cap without changing the authored first-map policy.
	db.progression.rules.first_map_max_level = 20
	actor.loadout.level = 4
	actor.loadout._rebuild(false)
	for i in range(5):
		verify(actor.inventory.use_item("magic_candy"), "糖果逐次加一级%d" % i)
	verify(actor.loadout.level == 9 and not actor.progression.choose_career("dual_swordsman"), "Lv9不能二刀流")
	actor.progression.add_experience(7)
	verify(actor.inventory.use_item("magic_candy") and actor.loadout.level == 10, "第六糖果到Lv10")
	verify(actor.progression.choose_career("dual_swordsman"), "Lv10二刀流链合法")
	verify(actor.inventory.count("azure_katana") == 1 and actor.loadout.sets[1].weapon == "azure_katana", "二刀流配对B剑作为一次职业奖励并装备")
	verify(actor.loadout.sets[0].skills[0] == "warrior_whirlwind" and "swordsman_fan_slash" in actor.loadout.learned_skills, "双持进阶保留A备战和学习")
	actor.loadout.level = 19
	actor.loadout._rebuild(false)
	verify(actor.inventory.use_item("magic_candy") and actor.loadout.level == 20, "后续章节遵守全局Lv20上限")
	var candy_count: int = actor.inventory.count("magic_candy")
	verify(not actor.inventory.use_item("magic_candy") and actor.inventory.count("magic_candy") == candy_count, "满级糖果不浪费")
	verify(not actor.progression.choose_career("dual_swordsman") and actor.inventory.count("azure_katana") == 1, "配对职业不能重复领奖")
	verify(actor.progression.to_next_level() == 0 and actor.progression.experience == 0, "Lv20不继续积累无内容等级")
	actor.loadout.set_level(1)
	verify(actor.loadout.level == 20, "正式角色不使用沙盒set_level降级")
	var reward: Dictionary = actor.progression.reward_enemy("soldier", "corpse-1")
	verify(reward.get("drops", {}).get("iron_longsword", 0) == 1 and reward.experience == 40, "满级仍获真实装备且返回本次掉落")
	var after_reward: Dictionary = actor.inventory.stacks.duplicate(true)
	verify(actor.progression.reward_enemy("soldier", "corpse-1").is_empty() and actor.inventory.stacks == after_reward, "同尸体奖励幂等")
	reward = actor.progression.reward_enemy("soldier", "corpse-2")
	verify(reward.drops.has("hunter_dagger") and actor.progression.enemy_kills.soldier == 2, "第二击杀按稳定轮换发装备")
	verify(actor.progression.reward_enemy("unknown").is_empty(), "未知敌人不发奖励")
	var saved_inventory: Dictionary = actor.inventory.export_state()
	var saved_progression: Dictionary = actor.progression.export_state()
	var saved_loadout: Dictionary = actor.loadout.export_state()
	var restored := create_actor()
	restored.inventory.import_state(saved_inventory)
	restored.progression.import_state(saved_progression)
	restored.loadout.import_state(saved_loadout)
	verify(restored.inventory.stacks == actor.inventory.stacks and restored.inventory.quickslots == actor.inventory.quickslots, "同局导入还原背包与四快捷槽")
	verify(restored.inventory.cooldowns == actor.inventory.cooldowns, "同局切场景不清物品冷却")
	verify(restored.loadout.level == 20 and restored.loadout.career_ids == actor.loadout.career_ids and restored.loadout.sets == actor.loadout.sets, "同局导入还原职业和A/B装备技能")
	verify(restored.loadout.learned_skills == actor.loadout.learned_skills and restored.loadout.equipment == actor.loadout.equipment, "同局导入还原学习与护具")
	verify(restored.stats.get_final_stat("PER") == actor.stats.get_final_stat("PER"), "导入重算装备六维")
	verify(restored.progression.starter_granted and restored.progression.reward_enemy("soldier", "corpse-1").is_empty(), "导入保留starter和尸体去重")
	verify(restored.progression.reward_enemy("soldier", "corpse-3").drops.has("shortbow"), "导入延续第三次掉落轮换")
	var soldier := create_actor()
	soldier.progression.choose_career("warrior")
	verify(soldier.inventory.add_item("magic_candy"), "士兵进阶测试显式注入一颗调试糖果")
	soldier.inventory.use_item("magic_candy")
	verify(soldier.progression.choose_career("soldier") and soldier.inventory.count("wooden_shield") == 1 and soldier.loadout.shield().id == "wooden_shield", "士兵进阶一次盾奖励及A剑B盾")
	var soldier_items: Dictionary = soldier.inventory.stacks.duplicate(true)
	verify(not soldier.progression.choose_career("soldier") and soldier.inventory.stacks == soldier_items, "士兵奖励不能重复")
	for career in ["rogue", "barbarian", "mage"]:
		var alternative := create_actor()
		verify(alternative.progression.choose_career(career), "其他基础职业实际初始化: " + career)
		verify(alternative.inventory.count(alternative.loadout.sets[0].weapon) > 0 and alternative.loadout.available_skills.size() == 4, "职业默认武器持有且四基础技能可学: " + career)
		alternative.queue_free()
	actor.queue_free()
	restored.queue_free()
	soldier.queue_free()
	await process_frame
	print("RPG_STATE_RESULT checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
