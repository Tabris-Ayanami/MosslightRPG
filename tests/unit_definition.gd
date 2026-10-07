extends SceneTree
## Definition/loadout unit tests. Uses real stats, resources, inventory and
## progression components; the small combat port isolates scene/AI integration.
const Units = preload("res://combat/unit_definition.gd")
const Database = preload("res://combat/combat_database.gd")
const Races = preload("res://rpg/race_catalog.gd")
const Stats = preload("res://combat/stats_component.gd")
const Resources = preload("res://combat/resource_component.gd")
const Loadout = preload("res://combat/loadout_component.gd")
const Inventory = preload("res://rpg/inventory_component.gd")
const Progression = preload("res://rpg/progression_component.gd")
var checks := 0
var failures: Array[String] = []
var database := Database.new()

class CombatPort extends Node:
	var actor: Node
	var state := "NORMAL"
	var base_poise := 50.0
	var current_poise := 50.0
	func max_poise() -> float: return base_poise
	func can_start() -> bool: return true
	func reset() -> void: actor.resources.restore_all()
	func has_permission(_id: String) -> bool: return false
	func context() -> Dictionary:
		var values := {}
		for id in CombatStats.IDS + ["Armor"]: values[id] = actor.stats.get_final_stat(id)
		return {"stats": values, "careers": actor.loadout.career_ids, "level": actor.loadout.level,
			"proficiencies": actor.loadout.proficiencies, "state": "NORMAL", "hp_ratio": 1.0, "resources": {}}

class Fixture extends Node:
	var definition: Dictionary
	var resource_profile: Dictionary
	var stats: Node
	var resources: Node
	var combat: Node
	var loadout: Node
	var inventory: Node
	var progression: Node

func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func fixture(definition: Dictionary) -> Node:
	var actor := Fixture.new()
	root.add_child(actor)
	actor.definition = definition.duplicate(true)
	actor.resource_profile = definition.resource_profile.duplicate(true)
	actor.stats = Stats.new()
	actor.add_child(actor.stats)
	actor.stats.set_base(definition.stats)
	actor.resources = Resources.new()
	actor.add_child(actor.resources)
	actor.combat = CombatPort.new()
	actor.combat.actor = actor
	actor.add_child(actor.combat)
	actor.loadout = Loadout.new()
	actor.add_child(actor.loadout)
	actor.loadout.setup(actor, database)
	actor.loadout.level = int(definition.level)
	actor.inventory = Inventory.new()
	actor.add_child(actor.inventory)
	actor.inventory.setup(actor, database)
	actor.progression = Progression.new()
	actor.add_child(actor.progression)
	actor.progression.setup(actor, database, actor.inventory)
	actor.stats.changed.connect(actor.loadout.refresh_resources)
	actor.loadout._rebuild(true)
	return actor

func run() -> void:
	var hero := Units.for_player()
	var keys := hero.keys()
	keys.sort()
	check(hero.id == "hero" and hero.race_id == "human" and hero.faction_id == "heroes", "hero definition identifies human protagonist and heroes faction")
	check(hero.level == 0, "new hero definition starts at civilian level zero")
	check(hero.resource_profile.is_empty() and hero.stats.is_empty() and hero.innate_actions.is_empty(), "hero preserves civilian-to-career resource and weapon selection")
	check(hero.visual.kind == "kirito" and hero.body.radius == .27 and hero.body.height == 1.3 and hero.body.scale == Vector3.ONE, "hero definition preserves existing body and original model")
	check(Units.for_enemy(database, "missing_unit").is_empty(), "unknown unit definition is rejected rather than silently creating a soldier")
	for id in database.enemies:
		var raw: Dictionary = database.enemies[id]
		var unit := Units.for_enemy(database, id)
		var enemy_keys := unit.keys()
		enemy_keys.sort()
		check(enemy_keys == keys, id + ": enemy and hero share exactly one definition schema")
		check(unit.level == {"soldier": 1, "heavy_guard": 2, "fire_elemental": 3, "ogre": 5}[id], id + ": template preserves configured unit level")
		check(Races.is_valid(unit.race_id) and unit.faction_id == "hostiles" and unit.name == raw.name, id + ": valid race, hostile faction and unchanged display name")
		check(unit.resource_profile.HP == raw.hp and unit.resource_profile.Poise == raw.poise and unit.resource_profile.Stamina == 3 and unit.resource_profile.Energy == 0 and not unit.resource_profile.has("Qi") and not unit.resource_profile.has("SpellSlot"), id + ": native HP/poise and three canonical resource pools normalize without duplicate energy")
		check(unit.stats.Armor == raw.armor and CombatStats.IDS.all(func(stat: String) -> bool: return unit.stats[stat] == raw.stats[stat]), id + ": original six attributes and armor survive normalization")
		var expected_primary: Variant = raw.get("innate_actions", {}).get("PRIMARY_TAP", raw.action)
		check(unit.innate_actions.PRIMARY_TAP == expected_primary and unit.innate_actions.SECONDARY_TAP == raw.get("secondary_action", raw.action), id + ": natural mouse definitions preserve their explicit sequence and separate secondary action")
		check(unit.movement.speed == raw.move_speed and unit.ai.aggro_range == raw.aggro_range and unit.ai.attack_cooldown == raw.attack_cooldown and unit.ai.grab_every == raw.get("grab_every", 0), id + ": movement and AI timing remain unchanged")
		check(unit.combat.resistances == raw.resistance and unit.combat.is_boss == raw.is_boss and unit.combat.immune_to_launch == raw.immune_to_launch and unit.combat.immune_to_knockdown == raw.immune_to_knockdown and unit.combat.shield_id == raw.get("shield", ""), id + ": defenses, immunities and native shield remain explicit")
		var secondary_before: Dictionary = unit.innate_actions.SECONDARY_TAP.duplicate(true)
		var first: Dictionary = unit.innate_actions.PRIMARY_TAP[0] if unit.innate_actions.PRIMARY_TAP is Array else unit.innate_actions.PRIMARY_TAP
		first.formula.base = 999999
		unit.stats.STR = 999999
		unit.combat.resistances.FIRE = 999999
		var other := Units.for_enemy(database, id)
		check(other.innate_actions.PRIMARY_TAP == expected_primary and other.stats.STR == raw.stats.STR and other.combat.resistances == raw.resistance and unit.innate_actions.SECONDARY_TAP == secondary_before, id + ": primary/secondary, combo segments and successive definitions never share nested mutable data")
		var actor := fixture(other)
		check(actor.loadout.level == raw.level and actor.resources.max_value("HP") == raw.hp and actor.combat.base_poise == raw.poise and actor.resources.current("HP") == raw.hp, id + ": native-level loadout rebuild preserves full monster pools")
		actor.resources.change("HP", -123)
		actor.resources.change("Stamina", -1)
		actor.combat.current_poise -= 17
		actor.stats.add_modifier("equipment_probe", {"CON": 2, "STR": 1})
		check(actor.resources.max_value("HP") == raw.hp and actor.resources.current("HP") == raw.hp - 123 and actor.resources.current("Stamina") == 2 and actor.combat.current_poise == raw.poise - 17, id + ": attribute-triggered refresh neither overwrites native maxima nor heals wounded pools")
		check(actor.loadout.select_career("warrior") and actor.loadout.equip_weapon(0, "iron_longsword") and actor.loadout.assign_skill(0, 0, "warrior_thrust") and actor.resources.max_value("HP") == raw.hp and actor.combat.base_poise == raw.poise, id + ": same loadout can equip profession weapons/skills while keeping native resource profile")
		var empty := fixture(other)
		var exported: Dictionary = empty.loadout.export_state()
		actor.loadout.import_state(exported)
		check(actor.loadout.level == raw.level and actor.stats.base == other.stats and actor.resources.max_value("HP") == raw.hp, id + ": importing empty career retains native level and restores its six attributes")
		empty.loadout.configure_progression(empty.inventory, empty.progression)
		empty.resources.change("HP", -50)
		empty.inventory.add_item("magic_candy", 1)
		if raw.level < empty.progression.max_level():
			check(empty.progression.add_experience(empty.progression.to_next_level() + 3) and empty.loadout.level == raw.level + 1 and empty.progression.experience == 3 and empty.loadout.career_ids.is_empty(), id + ": profession-free native unit gains exactly one XP level and keeps excess experience")
			check(empty.inventory.use_item("magic_candy") and empty.loadout.level == raw.level + 2 and empty.inventory.count("magic_candy") == 0 and empty.resources.current("HP") == raw.hp - 50, id + ": candy adds one native level, consumes once and does not refill health")
			actor.loadout.import_state(empty.loadout.export_state())
			check(actor.loadout.level == raw.level + 2 and actor.loadout.career_ids.is_empty() and actor.stats.base == other.stats, id + ": profession-free upgraded level survives a real export/import roundtrip")
		else:
			check(not empty.progression.add_experience(9999) and not empty.inventory.use_item("magic_candy") and empty.loadout.level == empty.progression.max_level() and empty.inventory.count("magic_candy") == 1 and empty.resources.current("HP") == raw.hp - 50, id + ": level cap rejects XP and candy without consuming stock or healing")
		empty.free()
		actor.free()
	check(Units.for_enemy(database, "fire_elemental").race_id == "elemental" and Units.for_enemy(database, "ogre").race_id == "giant", "fire elemental and ogre use explicit elemental and giant identities")
	check(Units.for_enemy(database, "ogre").body.scale == Vector3(1.5, 1.3, 1.5) and Units.for_enemy(database, "ogre").visual.scale == 1.5, "ogre preserves the existing collider and visual scale independently")
	for id in ["soldier", "ogre"]:
		var sequence: Array = Units.for_enemy(database, id).innate_actions.PRIMARY_TAP
		check(sequence.size() == 3 and sequence[0].combo_index == 0 and sequence[1].combo_index == 1 and sequence[2].combo_index == 2 and sequence[0].id != sequence[1].id and sequence[1].id != sequence[2].id, id + ": three ordered native primary swings have separate action and animation identities")
		check(sequence[2].combo_window == 0 and sequence[2].recovery > sequence[0].recovery, id + ": finisher commits to a longer recovery without an early weapon chain")
	var ogre_unit := Units.for_enemy(database, "ogre")
	check(ogre_unit.innate_actions.SECONDARY_TAP.id != ogre_unit.innate_skills[0].id and ogre_unit.innate_actions.SECONDARY_TAP.get("attack_kind", "") != "GRAB" and ogre_unit.innate_skills[0].attack_kind == "GRAB", "ogre secondary heavy sweep and Q grab are different abilities")
	var old_race: String = database.enemies.soldier.race_id
	database.enemies.soldier.erase("race_id")
	check(Units.for_enemy(database, "soldier").race_id == "human", "legacy catalog without a race defaults to human")
	database.enemies.soldier.race_id = old_race
	var actor := fixture(hero)
	check(actor.resources.max_value("HP") == 100 and actor.resources.max_value("Stamina") == 3 and actor.resources.max_value("Energy") == 0 and actor.resources.pools.size() == 3, "empty hero profile preserves civilian defaults with one empty energy pool")
	actor.inventory.add_item("magic_candy", 1)
	check(not actor.progression.add_experience(9999) and not actor.inventory.use_item("magic_candy") and actor.loadout.level == 0 and actor.inventory.count("magic_candy") == 1, "civilian hero still needs a career before XP or candy can raise level")
	var invalid_civilian: Dictionary = actor.loadout.export_state()
	invalid_civilian.level = 7
	actor.loadout.import_state(invalid_civilian)
	check(actor.loadout.level == 0 and actor.loadout.career_ids.is_empty(), "career-free hero import cannot bypass civilian level zero")
	actor.loadout.select_career("warrior")
	check(actor.resources.max_value("HP") == 1070 and actor.resources.max_value("Energy") == 60 and actor.combat.base_poise == 99, "empty hero profile preserves warrior formula results at twenty energy per former point")
	actor.resource_profile = {"HP": 500}
	actor.loadout.refresh_resources(true)
	check(actor.resources.max_value("HP") == 500 and actor.resources.max_value("Energy") == 60 and actor.combat.base_poise == 99, "partial native profile overrides only explicitly supplied resource keys")
	actor.resource_profile = {"HP": "200 + CON * 10 + level", "Poise": "CON * 2"}
	actor.loadout.refresh_resources(true)
	check(actor.resources.max_value("HP") == 331 and actor.combat.base_poise == 26, "native resource profiles support trusted six-attribute/level formulas")
	actor.resources.change("HP", -100)
	actor.stats.add_modifier("equipment_formula", {"CON": 2})
	check(actor.resources.max_value("HP") == 351 and actor.resources.current("HP") == 231 and actor.combat.base_poise == 30, "native formulas react to equipment attributes without refilling current HP")
	actor.free()
	actor = fixture(Units.for_enemy(database, "soldier"))
	check(actor.loadout.sandbox_mode, "unit loadouts retain sandbox defaults independent of unit identity")
	actor.loadout.configure_progression(actor.inventory, actor.progression)
	actor.loadout._rebuild(false)
	check(not actor.loadout.sandbox_mode and actor.loadout.inventory == actor.inventory and actor.loadout.progression == actor.progression and actor.resources.max_value("HP") == database.enemies.soldier.hp, "normal progression binds the same inventory/progression API to a monster")
	check(actor.progression.choose_career("warrior") and actor.inventory.count("iron_longsword") == 1 and actor.resources.max_value("HP") == database.enemies.soldier.hp and actor.loadout.sets[0].skills == ["", "", ""], "normal monster progression uses owned starter gear and does not auto-learn career skills")
	check(actor.progression.learn_skill("warrior_thrust") and actor.loadout.assign_skill(0, 0, "warrior_thrust"), "normal monster can explicitly learn and prepare a profession skill")
	actor.free()
	actor = fixture(hero)
	actor.loadout.configure_progression(actor.inventory, actor.progression)
	actor.loadout._rebuild(false)
	check(actor.progression.choose_career("mage") and not actor.progression.can_learn("conjurer_dreamwalk").is_empty(), "normal mage cannot learn Dreamwalk before advancing to conjurer")
	check(actor.progression.level_up() and actor.progression.choose_career("conjurer"), "normal progression reaches the level-two conjurer through its real career chain")
	check("conjurer_dreamwalk" not in actor.loadout.unlocked_skills and not actor.loadout.assign_skill(0, 0, "conjurer_dreamwalk") and actor.loadout.sets[0].skills == ["", "", ""], "advancement neither learns nor prepares Dreamwalk and unlearned assignment is rejected")
	check(actor.progression.learn_skill("conjurer_dreamwalk") and actor.loadout.assign_skill(0, 0, "conjurer_dreamwalk") and actor.loadout.sets[0].skills[0] == "conjurer_dreamwalk", "Dreamwalk becomes assignable only after an explicit successful learning action")
	actor.free()
	print("UNIT_DEFINITION_RESULT checks=", checks, " failures=", failures.size())
	quit(1 if not failures.is_empty() else 0)
