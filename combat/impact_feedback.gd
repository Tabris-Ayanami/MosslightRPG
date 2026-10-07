extends RefCounted
class_name CombatImpactFeedback
## Local combat feedback. These switches are used by the developer comparison rig.
## Gameplay damage, poise and control are resolved before presentation is applied.
static var hitstop_enabled := true
static var reaction_enabled := true
static var trails_enabled := true
static var sound_enabled := true
static var shake_enabled := true

static func is_finisher(action: Dictionary, database) -> bool:
	if action.get("charged_release", false): return true
	if action.get("semantic", "") != "PRIMARY_TAP" or action.get("is_skill", false): return false
	var family: String = action.get("animation_family", "")
	var count := int(action.get("combo_count", database.get_combo_count(family)))
	return count > 1 and int(action.get("combo_index", 0)) == count - 1

static func deliver(victim: Node, source: Node, action: Dictionary, direction: Vector3, result: Dictionary, dot: bool) -> void:
	if dot or float(action.get("tick_interval", 0.0)) > 0.0 or action.get("attack_kind", "") == "GRAB": return
	var defended: bool = result.get("defense", "") in ["block", "parry", "counter", "guard_break"]
	if float(result.get("final", 0.0)) <= 0.0 and not defended: return
	var family: String = action.get("animation_family", action.get("weapon_snapshot", {}).get("animation_family", ""))
	var melee: bool = float(action.get("projectile_speed", 0.0)) <= 0.0 and family in ["SINGLE_BLADE", "SHORT_WEAPON", "HEAVY_2H", "POLEARM", "UNARMED"] and action.get("presentation_type", "") == "WEAPON_ACTION"
	var profile: Dictionary = victim.arena.database.combat_feel.get("impact", {})
	var finish := is_finisher(action, victim.arena.database)
	var stop := float(profile.get("light_stop", .045))
	if family == "SHORT_WEAPON" or family == "UNARMED": stop = float(profile.get("quick_stop", .03))
	elif family == "HEAVY_2H": stop = float(profile.get("heavy_stop", .10))
	elif finish: stop = float(profile.get("finish_stop", .085))
	if defended: stop = float(profile.get("guard_stop", .04))
	if action.get("dual_wield", false): stop *= .65
	var armored: bool = victim.combat.has_hyper_armor() or victim.is_boss
	if hitstop_enabled and melee and is_instance_valid(source) and source.global_position.distance_to(victim.global_position) < 5.0:
		source.combat.add_hitstop(stop)
		if not armored: victim.combat.add_hitstop(stop)
	if reaction_enabled and victim.combat.state != "DEAD":
		victim.animation.contact_reaction(direction, .35 if defended or armored else (1.25 if finish else .8), defended)
	if sound_enabled:
		victim.arena.sound.play_tone("impact_guard" if defended else ("impact_finish" if finish else "impact_flesh"))
	if shake_enabled and melee and is_instance_valid(victim.arena.host) and victim.arena.host.has_method("shake") and (victim.is_human_controlled() or is_instance_valid(source) and source.is_human_controlled()):
		victim.arena.host.shake(.055 if finish else .018)
