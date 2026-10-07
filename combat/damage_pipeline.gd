extends RefCounted
class_name CombatDamage
## Pure damage resolution. Ratios are fractions (10% = 0.10).
## Shields, poise and statuses are applied by the receiver after this calculation.

const STATS := ["STR", "DEX", "CON", "INT", "PER", "CHA"]
const ELEMENTS := ["FIRE", "ICE", "LIGHTNING", "EARTH", "WIND"]

static func calculate(action: Dictionary, source: Dictionary, target: Dictionary, roll: float = -1.0) -> Dictionary:
	var formula: Dictionary = action.get("formula", {})
	var stats: Dictionary = source.get("stats", source)
	var raw := float(formula.get("base", formula.get("base_value", 0.0)))
	raw += float(source.get("weapon_scaling", 0.0)) * float(formula.get("weapon", formula.get("weapon_scaling_coeff", 0.0)))
	for stat in STATS:
		raw += float(stats.get(stat, 0.0)) * float(formula.get(stat, formula.get(stat + "_coeff", 0.0)))
	raw = maxf(0.0, raw)
	var damage_type := str(action.get("damage_type", "PHYSICAL")).to_upper()
	var result := {"raw": raw, "final": 0.0, "crit": false, "damage_type": damage_type, "effective_defense": 0.0, "blocked": false}
	if bool(target.get("invulnerable", false)):
		result.blocked = true
		return result
	var amount := raw * maxf(0.0, 1.0 + float(source.get("damage_bonus", 0.0)))
	var can_crit := bool(action.get("can_crit", not bool(action.get("is_dot", action.get("dot", false)))))
	if can_crit and raw > 0.0:
		var chance := clampf(float(source.get("crit_chance", 0.05)) + float(action.get("crit_chance_bonus", 0.0)), 0.0, 1.0)
		var forced := bool(action.get("forced_crit", false)) or bool(source.get("forced_crit", false))
		var sample := randf() if roll < 0.0 else clampf(roll, 0.0, 1.0)
		result.crit = forced or chance >= 1.0 or sample < chance
		if result.crit:
			amount *= maxf(1.0, float(source.get("crit_multiplier", 1.5)) + float(action.get("crit_multiplier_bonus", 0.0)))
	var vulnerability: Dictionary = target.get("vulnerability", {})
	amount *= maxf(0.0, 1.0 + float(vulnerability.get("ALL", 0.0)) + float(vulnerability.get(damage_type, 0.0)))
	amount *= maxf(0.0, 1.0 + float(target.get("damage_taken_bonus", 0.0)))
	if damage_type == "PHYSICAL":
		result.effective_defense = maxf(0.0, float(target.get("armor", 0.0)) - float(source.get("armor_penetration", 0.0)))
		amount *= 100.0 / (100.0 + float(result.effective_defense))
	elif damage_type in ELEMENTS:
		var resistance: Dictionary = target.get("resistance", {})
		var penetration: Variant = source.get("resistance_penetration", 0.0)
		var effective_penetration := float(penetration.get("ALL", 0.0)) + float(penetration.get(damage_type, 0.0)) if penetration is Dictionary else float(penetration)
		result.effective_defense = clampf(float(resistance.get(damage_type, 0.0)) - effective_penetration, -0.5, 0.75)
		amount *= 1.0 - float(result.effective_defense)
	result.final = maxf(0.0, amount)
	return result
