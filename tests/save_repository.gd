extends SceneTree
## Disk tests are isolated in a fresh OS temporary directory, never user://adventures.
const Repository = preload("res://rpg/save_repository.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
var checks := 0
var failures: Array[String] = []
var workspace := ""
var game: Node
var actor: Node

func _initialize() -> void:
	call_deferred("run")

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func replace_payload(path: String, snapshot: Dictionary) -> void:
	var payload := JSON.stringify(snapshot)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"format": "mosslight_adventure", "version": snapshot.version, "payload_json": payload, "sha256": payload.sha256_text()}))
	file.close()

func assert_invalid(repository: RefCounted, snapshot: Dictionary, label: String) -> void:
	var before: Dictionary = actor.inventory.export_state()
	var careers: Array = actor.loadout.career_ids.duplicate()
	var result: Dictionary = repository.restore(snapshot, actor, game)
	verify(not result.ok and not str(result.error).is_empty(), "reject unsafe snapshot: " + label)
	verify(actor.inventory.export_state() == before and actor.loadout.career_ids == careers, "rejection makes no destination mutation: " + label)

func clean_test_tree(path: String) -> void:
	# Only this invocation's random child of the OS temp directory can be removed.
	if not path.simplify_path().begins_with(workspace.simplify_path()):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		clean_test_tree(path.path_join(name))
	DirAccess.remove_absolute(path)

func run() -> void:
	workspace = OS.get_temp_dir().path_join("mosslight-save-test-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	Preferences.settings_path = workspace.path_join("preferences.cfg")
	var repository := Repository.new(workspace.path_join("primary"))
	verify(repository.list_slots().size() == 20, "list always contains exactly 20 slots")
	verify(repository.list_slots().all(func(entry: Dictionary): return not entry.occupied and not entry.valid), "fresh isolated repository is empty")
	for invalid in ["", "   ", ".", "..", "../escape", "bad:name", "bad\\path", "line\nbreak", "a".repeat(33)]:
		verify(not repository.create(invalid).ok, "invalid name rejected: " + invalid.replace("\n", "\\n"))
	var created: Dictionary = repository.create("  桐人 Alpha  ", 7)
	verify(created.ok and created.slot == 7 and created.snapshot.name == "桐人 Alpha", "trim display name and create in requested empty slot")
	verify(created.snapshot.name_key == "桐人 alpha", "identity normalized with trim and lowercase")
	verify(created.snapshot.loadout.level == 0 and created.snapshot.loadout.career_ids.is_empty(), "new civilian snapshot has valid Lv0 empty career")
	verify(created.snapshot.inventory.stacks.is_empty() and not created.snapshot.progression.starter_granted, "new save does not grant starter kit prematurely")
	verify(not repository.create("桐人 ALPHA").ok and not repository.validate_new_name(" 桐人 alpha ").is_empty(), "case and edge whitespace cannot bypass uniqueness")
	verify(not repository.create("占用槽", 7).ok and not repository.create("越界槽", 20).ok, "preferred slot rejects occupied and out of range")
	verify(repository.slot(7).valid and repository.slot(7).occupied and repository.slot(7).display_time.length() == 16, "slot metadata exposes valid occupancy and local wall-clock minutes")
	verify(absf(float(created.snapshot.saved_at_unix) - Time.get_unix_time_from_system()) < 3, "timestamp is actual system Unix time")
	verify(str(created.snapshot.saved_at_local).contains("T") and str(created.snapshot.saved_at_local).length() == 25, "local ISO timestamp includes timezone offset")
	var reopened := Repository.new(repository.directory)
	verify(reopened.load(7).ok and reopened.load_slot(7).snapshot.name == "桐人 Alpha", "new repository instance loads real persisted JSON")
	verify(not reopened.load_slot(-1).ok and not reopened.load_slot(20).ok and not reopened.load_slot(0).ok, "invalid and empty loads return errors without crashing")
	root.size = Vector2i(1280, 720)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(30)
	actor = game.player
	game.sound.muted = true
	game.combat_world.encounters_started = true
	verify(repository.restore(created.snapshot, actor, game).ok and actor.loadout.level == 0 and actor.resources.current("HP") == 100, "fresh save restores real main-world civilian with full safe resources")
	verify(actor.progression.choose_career("warrior"), "real saved character chooses warrior")
	verify(actor.inventory.count("magic_candy") == 0 and actor.inventory.add_item("magic_candy", 9), "save fixture explicitly grants debug candy after a candy-free starter")
	actor.inventory.use_item("magic_candy")
	verify(actor.progression.choose_career("swordsman"), "saved character advances legal career chain")
	actor.progression.add_experience(37)
	actor.progression.learn_skill("warrior_whirlwind")
	actor.progression.learn_skill("swordsman_fan_slash")
	actor.loadout.assign_skill(0, 0, "warrior_whirlwind")
	actor.loadout.assign_skill(1, 2, "swordsman_fan_slash")
	actor.inventory.add_item("hunter_ring")
	actor.loadout.equip_item("ring1", "hunter_ring")
	actor.inventory.assign_quick_slot(2, "fire_bomb")
	actor.inventory.cooldowns["healing_potion"] = 1.25
	actor.resources.change("HP", -123)
	actor.resources.change("Stamina", -1)
	actor.resources.change("Energy", -20)
	actor.combat.cooldowns["warrior_whirlwind"] = 2.25
	actor.combat.stamina_clock = .7
	actor.combat.energy_clock = 1.25
	actor.loadout.current_set = 1
	actor.progression.grant_trait("keen_edge", "存档回归祝福", "祝福")
	actor.progression.reward_enemy("soldier", "test-corpse-123")
	actor.global_position = Vector3(29, 3.1, 111)
	actor.facing = Vector3.RIGHT
	game.checkpoint = Vector3(2, 2.4, 115)
	game.encounter_origin = Vector3(3, 2.4, 116)
	var expected_inventory: Dictionary = actor.inventory.export_state()
	var expected_growth: Dictionary = actor.progression.export_state()
	var expected_loadout: Dictionary = actor.loadout.export_state()
	var expected_hp: float = actor.resources.current("HP")
	var expected_stamina: float = actor.resources.current("Stamina")
	var expected_qi: float = actor.resources.current("Energy")
	var expected_stats: Dictionary = {}
	for stat in CombatStats.IDS:
		expected_stats[stat] = actor.stats.get_final_stat(stat)
	var saved: Dictionary = repository.save(7, "桐人 Alpha", actor, game)
	verify(saved.ok, "actual inventory career equipment skills attributes resources and world save to disk: " + str(saved.error))
	if not saved.ok:
		game.queue_free()
		await ticks(1)
		clean_test_tree(workspace)
		print("SAVE_REPOSITORY_RESULT checks=%d failures=%d" % [checks, failures.size()])
		quit(1)
		return
	verify(saved.metadata.location == "低语森林", "location derived from existing map local coordinates")
	verify(FileAccess.file_exists(repository.directory.path_join("slot_08.json.bak")), "previous valid save retained as atomic-commit backup")
	verify(not repository.save(7, "不同冒险", actor, game).ok, "save cannot overwrite a different adventure identity")
	var loaded: Dictionary = Repository.new(repository.directory).load_slot(7)
	verify(loaded.ok and loaded.snapshot.version == Repository.VERSION, "versioned disk snapshot passes complete validation")
	actor.inventory.add_item("magic_candy", 20)
	actor.progression.experience = 0
	actor.loadout.equip_item("ring1", "")
	actor.loadout.assign_skill(0, 0, "")
	actor.loadout.current_set = 0
	actor.global_position = Vector3(4, 2.4, 114)
	actor.resources.restore_all()
	verify(repository.restore(loaded.snapshot, actor, game).ok, "persisted snapshot restores actual main-world actor")
	verify(actor.inventory.export_state() == expected_inventory, "restore exact real quantities quickslots and item cooldowns")
	verify(actor.progression.export_state() == expected_growth, "restore XP one-time rewards drops and acquired traits")
	verify(actor.loadout.export_state() == expected_loadout, "restore career level equipment learned skills A/B prepared groups")
	for stat in CombatStats.IDS:
		verify(is_equal_approx(actor.stats.get_final_stat(stat), expected_stats[stat]), "restore recomputed actual attribute " + stat)
	verify(is_equal_approx(actor.resources.current("HP"), expected_hp) and is_equal_approx(actor.resources.current("Stamina"), expected_stamina) and is_equal_approx(actor.resources.current("Energy"), expected_qi), "resource quantities are restored without free refills")
	verify(actor.global_position.distance_to(Vector3(29, 3.1, 111)) < .001 and actor.facing == Vector3.RIGHT, "world position and facing roundtrip")
	verify(game.checkpoint == Vector3(2, 2.4, 115) and game.encounter_origin == Vector3(3, 2.4, 116), "checkpoint and trial origin roundtrip")
	verify(actor.combat.cooldowns.get("warrior_whirlwind", 0) == 2.25 and actor.combat.stamina_clock == .7, "load does not reset action cooldown or regeneration progress")
	verify(actor.combat.energy_clock == 1.25, "load preserves the remaining mana recovery delay")
	var legacy_recovery: Dictionary = loaded.snapshot.duplicate(true)
	legacy_recovery.combat.erase("energy_clock")
	verify(repository.restore(legacy_recovery, actor, game).ok and actor.combat.energy_clock == 0.0, "older v5 recovery state loads with a fresh mana delay and no free refill")
	verify(not actor.progression.choose_career("warrior") and actor.inventory.count("magic_candy") == int(expected_inventory.stacks.magic_candy), "loading cannot duplicate starter kit")
	verify(actor.progression.reward_enemy("soldier", "test-corpse-123").is_empty(), "loading preserves reward deduplication")
	var bad: Dictionary = loaded.snapshot.duplicate(true)
	bad.version = 999
	assert_invalid(repository, bad, "future schema version")
	bad = loaded.snapshot.duplicate(true)
	bad.inventory.stacks["healing_potion"] = -1
	assert_invalid(repository, bad, "negative inventory")
	bad = loaded.snapshot.duplicate(true)
	bad.inventory.stacks["unknown_item"] = 1
	assert_invalid(repository, bad, "unknown inventory ID")
	bad = loaded.snapshot.duplicate(true)
	bad.loadout.level = 100
	assert_invalid(repository, bad, "level beyond content cap")
	bad = loaded.snapshot.duplicate(true)
	bad.loadout.career_ids = ["warrior", "conjurer"]
	assert_invalid(repository, bad, "invalid career chain")
	bad = loaded.snapshot.duplicate(true)
	bad.attributes.STR = 999
	assert_invalid(repository, bad, "forged attribute")
	bad = loaded.snapshot.duplicate(true)
	bad.loadout.sets[0].skills[1] = "mage_fireball"
	assert_invalid(repository, bad, "unlearned foreign skill")
	bad = loaded.snapshot.duplicate(true)
	bad.inventory.stacks.erase("iron_longsword")
	assert_invalid(repository, bad, "equipped but unowned weapon")
	bad = loaded.snapshot.duplicate(true)
	bad.loadout.sets[1].weapon = "iron_longsword"
	bad.inventory.stacks.iron_longsword = 1
	assert_invalid(repository, bad, "one owned copy equipped twice")
	bad = loaded.snapshot.duplicate(true)
	bad.loadout.equipment.head = "hunter_ring"
	assert_invalid(repository, bad, "wrong armor slot")
	bad = loaded.snapshot.duplicate(true)
	bad.resources.HP = 999999
	assert_invalid(repository, bad, "resource above calculated maximum")
	bad = loaded.snapshot.duplicate(true)
	bad.world.position = [0, NAN, 0]
	assert_invalid(repository, bad, "nonfinite position")
	bad = loaded.snapshot.duplicate(true)
	bad.world.checkpoint = [0, 0, 999999]
	assert_invalid(repository, bad, "unbounded checkpoint")
	bad = loaded.snapshot.duplicate(true)
	bad.inventory.quickslots = "wrong type"
	assert_invalid(repository, bad, "malformed nested type")
	bad = loaded.snapshot.duplicate(true)
	bad.progression.experience = 99999
	assert_invalid(repository, bad, "XP above next-level threshold")
	bad = loaded.snapshot.duplicate(true)
	bad["resource_path"] = "res://malicious.gd"
	assert_invalid(repository, bad, "unknown executable-looking field")
	# A valid checksum is not sufficient: semantic validation still rejects data.
	var semantic_dir := workspace.path_join("semantic")
	DirAccess.make_dir_recursive_absolute(semantic_dir)
	replace_payload(semantic_dir.path_join("slot_08.json"), bad)
	verify(not Repository.new(semantic_dir).load_slot(7).ok, "unsafe disk data is rejected even with matching checksum")
	actor.resources.change("HP", -actor.resources.current("HP"))
	verify(actor.combat.state == "DEAD", "real actor dies before death-safe save test")
	var dead_save: Dictionary = repository.save(7, "桐人 Alpha", actor, game)
	verify(dead_save.ok and dead_save.snapshot.resources.HP > 0 and dead_save.snapshot.world.position == dead_save.snapshot.world.checkpoint, "dead save stores safe checkpoint and living resource snapshot")
	verify(dead_save.ok and dead_save.metadata.location == "风息原野", "death-save location card follows restored checkpoint rather than forest death position")
	verify(repository.restore(dead_save.snapshot, actor, game).ok and actor.combat.state != "DEAD" and actor.resources.current("HP") > 0, "dead-save restore never replays death or grab")
	verify(actor.global_position == game.checkpoint and not actor.combat.runner.busy(), "load clears actions and safely restores checkpoint")
	var original_path := repository.directory.path_join("slot_08.json")
	var persisted_before := FileAccess.get_file_as_string(original_path)
	var file := FileAccess.open(original_path, FileAccess.WRITE)
	file.store_string("{truncated")
	file.close()
	verify(repository.slot(7).occupied and not repository.slot(7).valid and not repository.load_slot(7).ok, "corrupted primary remains occupied and visibly invalid")
	verify(not repository.create("桐人 ALPHA").ok, "valid backup reserves identity even when primary JSON is corrupt")
	verify(not repository.save(7, "桐人 Alpha", actor, game).ok and FileAccess.get_file_as_string(original_path) == "{truncated", "corrupt slot cannot be overwritten or silently replaced by backup")
	verify(not repository.create("New", 7).ok, "corrupt occupied slot cannot be reused by create")
	file = FileAccess.open(original_path, FileAccess.WRITE)
	file.store_string(persisted_before)
	file.close()
	verify(repository.load_slot(7).ok, "test restoration of original bytes remains valid")
	DirAccess.remove_absolute(original_path)
	verify(repository.load_slot(7).ok and repository.slot(7).occupied, "interrupted publish recovers verified backup when primary is missing")
	verify(repository.save(7, "桐人 Alpha", actor, game).ok, "backup recovery can safely publish a new primary")
	var full := Repository.new(workspace.path_join("capacity"))
	for index in range(20):
		verify(full.create("Adventure %02d" % index).ok, "capacity creates slot " + str(index))
	verify(not full.create("Overflow").ok and not full.validate_new_name("Overflow").is_empty(), "twenty-slot capacity cannot overflow")
	verify(full.list_slots().all(func(entry: Dictionary): return entry.valid and entry.occupied), "full listing preserves all twenty independent saves")
	verify(not full.create("adventure 00").ok, "uniqueness still enforced after reopening and capacity exhaustion")
	var isolated := Repository.new(workspace.path_join("other"))
	verify(isolated.create("桐人 Alpha").ok, "test repositories are isolated from each other and real user saves")
	game.queue_free()
	await ticks(2)
	clean_test_tree(workspace)
	verify(not DirAccess.dir_exists_absolute(workspace), "temporary test directory removed after verified scoped cleanup")
	print("SAVE_REPOSITORY_RESULT checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
