extends RefCounted
## Real-time encounter tuning. Spell ranks use an accelerating cost table; this is
## not D&D's daily spell-slot budget. Native creatures retain their own pools.
const STAMINA_DELAY := 0.65
const ENERGY_DELAY := 2.0
const SPELL_COSTS := [0, 10, 20, 35, 55, 80, 110, 145, 185, 230]

static func stamina_rate(actor: Node, fighting: bool) -> float:
	var level: int = maxi(1, actor.loadout.level)
	var constitution: float = maxf(0.0, _stat(actor, "CON") - 10.0)
	var growth := float(level - 1) / (level + 3.0)
	return (0.7 + 0.45 * growth + 0.3 * constitution / (constitution + 10.0)) * (1.0 if fighting else 2.0) * _body_scale(actor, "Stamina")

static func energy_rate(actor: Node, fighting: bool) -> float:
	if not fighting:
		return maxf(4.0, _canonical_max(actor, "Energy") * 0.06) * _body_scale(actor, "Energy")
	var level: int = maxi(1, actor.loadout.level)
	var growth := float(level - 1) / (level + 3.0)
	var caster: bool = not actor.loadout.career_ids.is_empty() and actor.loadout.career_ids[0] == "mage"
	if caster:
		var intellect: float = maxf(0.0, _stat(actor, "INT") - 10.0)
		return (0.6 + 0.6 * growth + 0.4 * intellect / (intellect + 10.0)) * _body_scale(actor, "Energy")
	var perception: float = maxf(0.0, _stat(actor, "PER") - 10.0)
	return (0.35 + 0.3 * growth + 0.2 * perception / (perception + 10.0)) * _body_scale(actor, "Energy")

static func _stat(actor: Node, id: String) -> float:
	return actor.form.canonical_final_stat(id) if actor.form != null and actor.form.active else actor.stats.get_final_stat(id)

static func _canonical_max(actor: Node, id: String) -> float:
	return float(actor.form.canonical_max_resources().get(id, 0.0)) if actor.form != null and actor.form.active else actor.resources.max_value(id)

static func _body_scale(actor: Node, id: String) -> float:
	if actor.form == null or not actor.form.active: return 1.0
	var maximum := _canonical_max(actor, id)
	return actor.resources.max_value(id) / maximum if maximum > 0.0 else 0.0

static func spell_error(action: Dictionary) -> String:
	if not action.has("spell_rank"):
		return ""
	var rank: Variant = action.spell_rank
	if not (rank is int or rank is float) or not is_finite(float(rank)) or rank != int(rank) or rank < 0 or rank > 9:
		return "法术环级必须是 0～9 的整数"
	if not is_equal_approx(float(action.get("costs", {}).get("Energy", 0)), float(SPELL_COSTS[int(rank)])):
		return "法术基础能量消耗必须符合环级成本表"
	return ""
