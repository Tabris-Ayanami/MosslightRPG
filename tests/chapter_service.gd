extends SceneTree
## Pure chapter policy against real authored catalogs; no user files or scenes.
const Chapter = preload("res://rpg/chapter_service.gd")
const Encounters = preload("res://rpg/encounter_service.gd")
const World = preload("res://rpg/world_state.gd")
const Database = preload("res://combat/combat_database.gd")
const SOLDIER := "encounter.forest.soldier_01"
const HEAVY := "encounter.forest.heavy_guard_01"
const FIRE := "encounter.forest.fire_elemental_01"
const OGRE := "encounter.forest.ogre_01"
class QuestFacts extends RefCounted:
	var definitions: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/quests.json"))
	var statuses: Dictionary = {"village_patrol": "available", "forest_investigation": "locked"}
	var done: Dictionary = {}
	func definition(id: String) -> Dictionary: return definitions.get(id, {}).duplicate(true)
	func status(id: String) -> String: return statuses.get(id, "unknown")
	func objective_progress(id: String) -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for objective: Dictionary in definitions.get(id, {}).get("objectives", []):
			result.append({"id": objective.id, "complete": statuses.get(id) == "rewarded" or done.get(objective.id, false)})
		return result
var checks := 0
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func run() -> void:
	var database := Database.new()
	var global_ogre: Dictionary = database.enemies.ogre.duplicate(true)
	var world := World.new()
	var encounters := Encounters.new()
	var quests := QuestFacts.new()
	var chapter := Chapter.new()
	check(encounters.setup(world, database) and chapter.setup(quests, encounters, database), "real chapter and encounter catalogs validate")
	var initial: Dictionary = world.export_state()
	check(chapter.phase() == "patrol_available" and not chapter.is_complete(), "new adventure begins before patrol")
	check(chapter.encounter_enabled(SOLDIER) and not chapter.encounter_enabled(HEAVY) and not chapter.encounter_enabled(FIRE) and not chapter.encounter_enabled(OGRE), "only introductory soldier is unlocked")
	quests.statuses.village_patrol = "active"
	check(chapter.phase() == "patrol_active" and not chapter.encounter_enabled(OGRE), "patrol cannot prematurely expose final challenge")
	quests.statuses.village_patrol = "ready"
	check(chapter.phase() == "patrol_report" and not chapter.encounter_enabled(FIRE), "finishing patrol combat still requires reporting")
	quests.statuses.village_patrol = "rewarded"
	quests.statuses.forest_investigation = "available"
	check(chapter.phase() == "investigation_available" and chapter.encounter_enabled(FIRE) and not chapter.encounter_enabled(HEAVY), "optional fire challenge opens after first claim, guard waits for acceptance")
	quests.statuses.forest_investigation = "active"
	check(chapter.phase() == "investigation_active" and chapter.encounter_enabled(HEAVY) and not chapter.encounter_enabled(OGRE), "accepted investigation opens guard first")
	quests.done.break_guard = true
	check(chapter.phase() == "final_challenge" and chapter.encounter_enabled(OGRE), "settled guard objective unlocks final boss")
	check(int(chapter.encounter_profile(OGRE).level) == 3 and database.enemies.ogre == global_ogre, "chapter level profile leaves shared laboratory ogre unchanged")
	quests.done.silence_ogre = true
	quests.statuses.forest_investigation = "ready"
	check(chapter.phase() == "final_report" and not chapter.is_complete() and not chapter.encounter_enabled(OGRE), "paid boss life cannot respawn while waiting for final report")
	quests.statuses.forest_investigation = "rewarded"
	check(chapter.phase() == "complete" and chapter.is_complete() and not chapter.encounter_enabled(OGRE), "existing quest reward is the sole durable chapter completion fact")
	check(chapter.encounter_enabled(SOLDIER) and chapter.encounter_enabled(HEAVY) and chapter.encounter_enabled(FIRE), "ordinary encounters remain available for post-chapter exploration")
	quests.statuses.forest_investigation = "active"
	quests.done.break_guard = false
	check(not chapter.encounter_enabled(OGRE) and chapter.encounter_enabled(HEAVY), "legacy save with ogre objective done first only needs its remaining guard")
	check(world.export_state() == initial, "all chapter queries leave world records and rewards untouched")
	var detached: Dictionary = chapter.definition()
	detached.encounters.clear()
	var profile: Dictionary = chapter.encounter_profile(OGRE)
	profile.level = 1
	check(chapter.definition().encounters.size() == 4 and chapter.encounter_profile(OGRE).level == 3, "definition and profiles are detached copies")
	check(not chapter.encounter_enabled("encounter.missing") and chapter.encounter_profile("encounter.missing").is_empty(), "unknown encounters cannot silently bypass the chapter")
	var good: Dictionary = chapter.definition()
	var invalid: Array[Dictionary] = []
	var candidate: Dictionary = good.duplicate(true)
	candidate.encounters.erase(OGRE)
	invalid.append(candidate)
	candidate = good.duplicate(true); candidate.completion_quest = "missing"; invalid.append(candidate)
	candidate = good.duplicate(true); candidate.encounters[OGRE].quest = "missing"; invalid.append(candidate)
	candidate = good.duplicate(true); candidate.encounters[OGRE].statuses = ["done"]; invalid.append(candidate)
	candidate = good.duplicate(true); candidate.encounters[OGRE].complete_objectives = ["missing"]; invalid.append(candidate)
	candidate = good.duplicate(true); candidate.encounters[OGRE].incomplete_objectives.append("break_guard"); invalid.append(candidate)
	candidate = good.duplicate(true); candidate.encounters[OGRE].profile = {"script": "bad"}; invalid.append(candidate)
	candidate = good.duplicate(true); candidate.encounters[OGRE].profile.level = 0; invalid.append(candidate)
	candidate = good.duplicate(true); candidate.encounters[OGRE].profile.level = 2.5; invalid.append(candidate)
	candidate = good.duplicate(true); candidate.encounters[SOLDIER].statuses = ["active"]; invalid.append(candidate)
	for bad in invalid:
		check(not chapter.setup(quests, encounters, database, bad) and not chapter.last_error.is_empty() and chapter.definition() == good, "invalid chapter preserves prior binding")
	check(not database.progression.starter.items.has("magic_candy") and "magic_candy" not in database.progression.starter.quickslots and not database.progression.ogre.drops.has("magic_candy"), "formal starting inventory and boss drops contain no debug levels")
	check(database.items.has("magic_candy"), "debug item definition remains available to explicit test fixtures")
	print("CHAPTER_SERVICE %d/%d passed" % [checks - failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
