extends Node
class_name RPGProgression

const InteractionReadiness = preload("res://rpg/interaction_readiness.gd")
const EnemyRewardPlan = preload("res://rpg/enemy_reward_plan.gd")
const MutationGuard = preload("res://rpg/mutation_guard.gd")

signal changed
signal leveled_up(level: int)
signal reward_received(enemy_id: String, reward: Dictionary)

var actor: Node
var database: RefCounted
var inventory: Node
var experience := 0
var starter_granted := false
var career_rewards: Array[String] = []
var claimed_rewards: Dictionary = {}
var enemy_kills: Dictionary = {}
var acquired_traits: Dictionary = {}
var last_error := ""
var _enemy_reward_busy := false
var _career_busy := false
var level: int:
	get:
		return actor.loadout.level if is_instance_valid(actor) else 0

func setup(owner_actor: Node, data: RefCounted, items: Node) -> void:
	actor = owner_actor
	database = data
	inventory = items

func max_level() -> int:
	var rules: Dictionary = database.progression.get("rules", {})
	var global_cap := int(rules.get("max_level",20))
	return global_cap if actor.loadout.sandbox_mode else mini(global_cap,int(rules.get("first_map_max_level",5)))

func to_next_level() -> int:
	if level <= 0 or level >= max_level():
		return 0
	return int(database.progression.get("rules", {}).get("xp_to_next", {}).get(str(level), 100))

func can_choose_career(id: String) -> String:
	if _career_busy or MutationGuard.busy(_reward_world()):
		return "职业更新中"
	var form: Variant = actor.get("form")
	if form != null and form.active:
		return "恢复原形后才能选择职业"
	if not database.careers.has(id):
		return "职业不存在"
	if not InteractionReadiness.can_manage(actor):
		return "动作结束后才能选择职业"
	var career: Dictionary = database.careers[id]
	if actor.loadout.career_ids.is_empty():
		return "" if int(career.get("required_level", 1)) == 1 else "请先选择基础职业"
	if id in actor.loadout.career_ids:
		return "已选择此职业"
	if int(career.get("required_level", 1)) <= 1:
		return "请先遗忘当前职业"
	var current: Dictionary = database.careers[actor.loadout.career_ids.back()]
	if id not in current.get("next_careers", []):
		return "当前职业无法进阶到此职业"
	if level < int(career.get("required_level", 1)):
		return "需要达到 Lv%d" % int(career.get("required_level", 1))
	return ""

func career_options() -> Array[Dictionary]:
	var ids: Array = []
	if actor.loadout.career_ids.is_empty():
		for id in database.careers:
			if int(database.careers[id].get("required_level", 1)) == 1:
				ids.append(id)
	else:
		ids = database.careers[actor.loadout.career_ids.back()].get("next_careers", [])
	var result: Array[Dictionary] = []
	for id in ids:
		var option: Dictionary = database.careers[id].duplicate(true)
		option["reason"] = can_choose_career(id)
		result.append(option)
	return result

func choose_career(id: String) -> bool:
	last_error = can_choose_career(id)
	if not last_error.is_empty():
		return false
	var first: bool = actor.loadout.career_ids.is_empty()
	var initial := first and not starter_granted
	var career: Dictionary = database.careers[id]
	if initial:
		starter_granted = true
		var starter: Dictionary = database.progression.get("starter", {})
		for item in starter.get("items", {}):
			inventory.add_item(item, int(starter.items[item]))
		for group in career.get("default_sets", []):
			inventory.add_item(str(group.get("weapon", "")))
		for index in range(mini(4, starter.get("quickslots", []).size())):
			inventory.assign_quick_slot(index, starter.quickslots[index])
	elif not first and id not in career_rewards:
		# A paired career grants its required B weapon once; all equipment still
		# passes the same ownership checks and can never appear by normalization.
		if career.get("loadout_rule", "") in ["sword_shield_pair", "dual_sword_pair"]:
			var presets: Array = career.get("default_sets", [])
			if presets.size() == 2:
				if actor.loadout.weapon_at(0).get("weapon_type", "") not in ["Sword", "Katana"]:
					var sword_id: String = presets[0].get("weapon", "")
					if inventory.count(sword_id) < 1:
						inventory.add_item(sword_id)
				var reward_id: String = presets[1].get("weapon", "")
				var needed := 2 if actor.loadout.sets[0].get("weapon", "") == reward_id else 1
				if inventory.count(reward_id) < needed:
					inventory.add_item(reward_id, needed - inventory.count(reward_id))
		career_rewards.append(id)
	actor.loadout.apply_progression_career(id, first)
	if initial:
		var equipped: Dictionary = database.progression.get("starter", {}).get("equipment", {})
		for slot in equipped:
			actor.loadout.equip_item(slot, equipped[slot])
		actor.resources.restore_all()
	changed.emit()
	return true

func can_forget_career() -> String:
	if _career_busy or MutationGuard.busy(_reward_world()):
		return "职业更新中"
	if actor.loadout.career_ids.is_empty():
		return "当前已经是平民"
	var form: Variant = actor.get("form")
	if form != null and form.active:
		return "恢复原形后才能遗忘职业"
	if not InteractionReadiness.can_manage(actor):
		return "动作结束后才能遗忘职业"
	return ""

func forget_career() -> bool:
	last_error = can_forget_career()
	if not last_error.is_empty():
		return false
	var world: Object = _reward_world()
	var owner := "career_reset:%d" % get_instance_id()
	if is_instance_valid(world) and not MutationGuard.acquire(world, owner):
		last_error = "职业更新中"
		return false
	_career_busy = true
	# Publish only after the entire civilian build is coherent. No inventory,
	# experience, reward receipts, acquired traits or world progress is erased.
	var blocked: Dictionary = {}
	for component in [actor.stats, actor.loadout, actor.resources]:
		blocked[component] = component.is_blocking_signals()
		component.set_block_signals(true)
	actor.input_router.cancel()
	actor.combat.combo = 0
	actor.combat.combo_timeout = 0.0
	actor.loadout.career_ids.clear()
	actor.loadout.learned_skills.clear()
	actor.loadout.sets.assign([{"weapon": "", "skills": ["", "", ""]}, {"weapon": "", "skills": ["", "", ""]}])
	actor.loadout.current_set = 0
	actor.stats.set_base(actor.definition.get("stats", {}))
	actor.stats.modifiers.erase("passive_runtime")
	actor.loadout._rebuild(false)
	var modifiers: Dictionary = actor.combat.passives.actor_modifiers("stat_update")
	var attributes: Dictionary = {}
	for stat in CombatStats.CONTEXT_IDS:
		if modifiers.has(stat): attributes[stat] = modifiers[stat]
	actor.stats.modifiers["passive_runtime"] = attributes
	for component in blocked:
		component.set_block_signals(blocked[component])
	actor.stats.changed.emit()
	actor.loadout.changed.emit()
	inventory.changed.emit()
	changed.emit()
	_career_busy = false
	MutationGuard.release(world, owner)
	last_error = ""
	return true

func can_level_up() -> String:
	if _career_busy:
		return "职业更新中"
	if level <= 0:
		return "请先选择基础职业"
	if level >= max_level():
		return "已达到当前内容上限 Lv%d" % max_level()
	return ""

func level_up() -> bool:
	last_error = can_level_up()
	if not last_error.is_empty():
		return false
	actor.loadout.level += 1
	actor.loadout._rebuild(false)
	if level >= max_level():
		experience = 0
	leveled_up.emit(level)
	changed.emit()
	return true

func add_experience(amount: int) -> bool:
	if amount <= 0 or level <= 0 or level >= max_level():
		last_error = "当前不能获得经验"
		return false
	experience += amount
	while level < max_level() and experience >= to_next_level():
		experience -= to_next_level()
		if not level_up(): break
	last_error = ""
	changed.emit()
	return true

func reward_enemy(enemy_id: String, reward_key := "") -> Dictionary:
	var world: Object = _reward_world()
	if _enemy_reward_busy or MutationGuard.busy(world):
		last_error = "奖励更新中"
		return {}
	var plan: Dictionary = plan_enemy_reward(enemy_id, reward_key)
	if not plan.ok:
		last_error = plan.error
		return {}
	var owner := "enemy_reward:%d" % get_instance_id()
	if is_instance_valid(world) and not MutationGuard.acquire(world, owner):
		last_error = "奖励更新中"
		return {}
	_enemy_reward_busy = true
	var previous_level := level
	commit_enemy_reward(plan, false)
	publish_enemy_reward(plan, previous_level)
	_enemy_reward_busy = false
	MutationGuard.release(world, owner)
	last_error = ""
	return plan.reward.duplicate(true)

## Pure preflight, including last_error. The world runtime may hold the shared
## guard while combining this plan with encounter and quest event persistence.
func plan_enemy_reward(enemy_id: String, reward_key := "") -> Dictionary:
	return EnemyRewardPlan.build(self, enemy_id, reward_key)

## A plan is for immediate synchronous use after preflight. The world runtime
## owns the shared guard when publish is false and publishes after its own commit.
func commit_enemy_reward(plan: Dictionary, publish := true) -> void:
	if not plan.get("ok", false):
		return
	var world: Object = _reward_world()
	var owner := "enemy_reward_commit:%d" % get_instance_id()
	if publish and (_enemy_reward_busy or (is_instance_valid(world) and not MutationGuard.acquire(world, owner))):
		last_error = "奖励更新中"
		return
	var previous_level := level
	inventory.stacks = plan.stacks.duplicate(true)
	experience = int(plan.experience)
	actor.loadout.level = int(plan.level)
	enemy_kills = plan.enemy_kills.duplicate(true)
	claimed_rewards = plan.claimed_rewards.duplicate(true)
	last_error = ""
	if publish:
		publish_enemy_reward(plan, previous_level)
		MutationGuard.release(world, owner)
		last_error = ""

## All persistent world + character fields must already be committed. Derived
## resource/loadout observers and final signals may now inspect one whole reward.
func publish_enemy_reward(plan: Dictionary, previous_level: int) -> void:
	if not plan.get("ok", false):
		return
	var was_busy := _enemy_reward_busy
	_enemy_reward_busy = true
	if level != previous_level:
		actor.loadout._rebuild(false)
		for reached_level in range(previous_level + 1, level + 1):
			leveled_up.emit(reached_level)
	inventory.changed.emit()
	reward_received.emit(str(plan.enemy_id), plan.reward.duplicate(true))
	changed.emit()
	_enemy_reward_busy = was_busy
	last_error = ""

func _reward_world() -> Object:
	if not is_instance_valid(actor):
		return null
	var arena: Variant = actor.get("arena")
	if not is_instance_valid(arena):
		return null
	var host: Variant = arena.get("host")
	return host.get("world_state") if is_instance_valid(host) else null

func can_learn(id: String) -> String:
	if id not in actor.loadout.available_skills:
		return "职业或等级条件不满足"
	if id in actor.loadout.learned_skills:
		return "已经学会此技能"
	if not InteractionReadiness.can_manage(actor):
		return "动作结束后才能学习技能"
	return ""

func learn_skill(id: String) -> bool:
	last_error = can_learn(id)
	if not last_error.is_empty():
		return false
	actor.loadout.learned_skills.append(id)
	actor.loadout._rebuild(false)
	changed.emit()
	return true

## Acquisition is explicit; art fixtures never grant gameplay effects.
func grant_trait(id: String, source: String, kind := "祝福") -> bool:
	if not database.passives.has(id) or source.strip_edges().is_empty():
		last_error="无效的特性或来源"
		return false
	if acquired_traits.has(id): return false
	acquired_traits[id]={"source":source,"kind":kind}
	last_error=""
	changed.emit()
	return true

func revoke_trait(id: String) -> void:
	if acquired_traits.erase(id): changed.emit()

func export_state() -> Dictionary:
	return {"acquired_traits": acquired_traits.duplicate(true), "experience": experience, "starter_granted": starter_granted, "career_rewards": career_rewards.duplicate(), "claimed_rewards": claimed_rewards.duplicate(true), "enemy_kills": enemy_kills.duplicate(true)}

func import_state(state: Dictionary) -> void:
	acquired_traits.clear()
	var incoming: Variant=state.get("acquired_traits",{})
	if incoming is Dictionary:
		for id in incoming:
			if not database.passives.has(id) or not incoming[id] is Dictionary: continue
			var source: String=str(incoming[id].get("source","")).strip_edges()
			if not source.is_empty(): acquired_traits[id]={"source":source,"kind":str(incoming[id].get("kind","祝福"))}
	experience = maxi(0, int(state.get("experience", 0)))
	starter_granted = bool(state.get("starter_granted", false))
	career_rewards.clear()
	for id in state.get("career_rewards", []):
		if database.careers.has(str(id)) and str(id) not in career_rewards:
			career_rewards.append(str(id))
	claimed_rewards = state.get("claimed_rewards", {}).duplicate(true)
	enemy_kills.clear()
	for id in state.get("enemy_kills", {}):
		if database.enemies.has(id):
			enemy_kills[id] = maxi(0, int(state.enemy_kills[id]))
	last_error = ""
	changed.emit()
