extends RefCounted
## Pure reward preflight. No assignment, signal, resource rebuild or error-state
## change is permitted here: the caller may combine this with a world-state plan.
const MAX_QUANTITY := 1000000
const MAX_EXPERIENCE := 2147483647
const MAX_RECEIPTS := 100000

static func build(growth: Node, enemy_id: String, reward_key: String) -> Dictionary:
	if not is_instance_valid(growth.actor) or not is_instance_valid(growth.actor.get("loadout")) or not is_instance_valid(growth.inventory) or not is_instance_valid(growth.database):
		return _failure("角色奖励组件尚未就绪")
	var data: RefCounted = growth.database
	if not data.enemies.has(enemy_id) or not data.progression.has(enemy_id):
		return _failure("没有此敌人的奖励配置")
	var rules: Variant = data.progression.get("rules", {})
	if not rules is Dictionary or not _integer(rules.get("max_level"), 1, MAX_QUANTITY) or not rules.get("xp_to_next", {}) is Dictionary:
		return _failure("等级规则无效")
	var ceiling: int = maxi(growth.level,mini(int(rules.max_level),growth.max_level()))
	var thresholds: Dictionary = rules.get("xp_to_next", {})
	var next_level: int = growth.level
	if next_level <= 0:
		return _failure("请先选择基础职业")
	if next_level > int(rules.max_level) or not _integer(growth.experience, 0, MAX_EXPERIENCE):
		return _failure("当前等级或经验无效")
	if reward_key.length() > 128:
		return _failure("奖励凭据过长")
	var receipts: Dictionary = growth.claimed_rewards.duplicate(true)
	if receipts.size() > MAX_RECEIPTS:
		return _failure("奖励凭据已达上限")
	for key in receipts:
		if not key is String or key.is_empty() or key.length() > 128 or not receipts[key] is bool or not receipts[key]:
			return _failure("奖励凭据无效")
	if not reward_key.is_empty():
		if receipts.has(reward_key):
			return _failure("此敌人的奖励已领取")
		if receipts.size() >= MAX_RECEIPTS:
			return _failure("奖励凭据已达上限")
		receipts[reward_key] = true
	var kills: Dictionary = growth.enemy_kills.duplicate(true)
	for id in kills:
		if not id is String or not data.enemies.has(id) or not _integer(kills[id], 0, MAX_QUANTITY):
			return _failure("敌人掉落轮换记录无效")
	var kill_count: int = int(kills.get(enemy_id, 0))
	if kill_count >= MAX_QUANTITY:
		return _failure("敌人击杀次数已达上限")
	var source: Variant = data.progression[enemy_id]
	if not source is Dictionary or source.get("id", "") != enemy_id:
		return _failure("敌人奖励配置无效")
	var reward: Dictionary = source.duplicate(true)
	if not _integer(reward.get("experience", 0), 0, MAX_EXPERIENCE) or not reward.get("drops", {}) is Dictionary or not reward.get("equipment_rotation", []) is Array:
		return _failure("敌人经验或掉落配置无效")
	var drops: Dictionary = reward.get("drops", {}).duplicate(true)
	for id in drops:
		if not id is String or growth.inventory.definition(id).is_empty() or not _integer(drops[id], 1, MAX_QUANTITY):
			return _failure("奖励物品或数量无效")
	var rotation: Array = reward.get("equipment_rotation", [])
	for id in rotation:
		if not id is String or growth.inventory.definition(id).is_empty():
			return _failure("轮换奖励物品无效")
	if not rotation.is_empty():
		var drop_id: String = rotation[kill_count % rotation.size()]
		if int(drops.get(drop_id, 0)) >= MAX_QUANTITY:
			return _failure("合计奖励数量已达上限")
		drops[drop_id] = int(drops.get(drop_id, 0)) + 1
	reward["drops"] = drops
	var stacks: Dictionary = growth.inventory.stacks.duplicate(true)
	for id in stacks:
		if not id is String or growth.inventory.definition(id).is_empty() or not _integer(stacks[id], 1, MAX_QUANTITY):
			return _failure("当前背包物品或数量无效")
	for id in drops:
		var amount: int = int(drops[id])
		if int(stacks.get(id, 0)) > MAX_QUANTITY - amount:
			return _failure("奖励物品数量已达上限")
		stacks[id] = int(stacks.get(id, 0)) + amount
	var xp: int = growth.experience
	if next_level < ceiling:
		var earned: int = int(reward.get("experience", 0))
		if xp > MAX_EXPERIENCE - earned:
			return _failure("经验值已达上限")
		xp += earned
		while next_level < ceiling:
			var threshold: Variant = thresholds.get(str(next_level), 100)
			if not _integer(threshold, 1, MAX_EXPERIENCE):
				return _failure("升级经验配置无效")
			if xp < int(threshold):
				break
			xp -= int(threshold)
			next_level += 1
		if next_level >= ceiling:
			xp = 0
	elif next_level >= int(rules.max_level) and xp != 0:
		return _failure("满级角色经验无效")
	kills[enemy_id] = kill_count + 1
	return {"ok": true, "error": "", "enemy_id": enemy_id, "stacks": stacks,
		"experience": xp, "level": next_level, "enemy_kills": kills,
		"claimed_rewards": receipts, "reward": reward}

static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and value >= minimum and value <= maximum

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
