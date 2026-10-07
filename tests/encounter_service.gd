extends SceneTree
## Pure state/catalog tests. No scenes, preferences, user:// or save repository.
const Service = preload("res://rpg/encounter_service.gd")
const State = preload("res://rpg/world_state.gd")
const Database = preload("res://combat/combat_database.gd")
const SOLDIER := "encounter.forest.soldier_01"
const OGRE := "encounter.forest.ogre_01"
var checks := 0
var failures: Array[String] = []
var notifications: Array = []

func _initialize() -> void: call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func fixture_record(phase: String, generation: int = 1, remaining: float = 0.0) -> Dictionary:
	return {"version": 1, "generation": generation, "phase": phase, "remaining": remaining}

func catalog(service: RefCounted) -> Dictionary:
	var result: Dictionary = {}
	for entry in service.entries(): result[entry.id] = service.definition(entry.id)
	return result

func reject_state(service: RefCounted, world: RefCounted, candidate: Dictionary, label: String) -> void:
	var before: Dictionary = world.export_state()
	verify(not service.validate_state(candidate).is_empty(), "state rejects " + label)
	var plan: Dictionary = service.plan_defeat(SOLDIER, 1, candidate)
	verify(not plan.ok and not plan.error.is_empty() and plan.world.is_empty() and world.export_state() == before, "invalid plan is nonmutating: " + label)

func run() -> void:
	var db := Database.new()
	var world := State.new()
	var service := Service.new()
	world.object_changed.connect(func(id: String): notifications.append(id))
	world.event_recorded.connect(func(event: Dictionary): notifications.append(event))
	verify(db.errors.is_empty() and service.setup(world, db), "real enemy catalog and authored encounter directory load")
	var empty: Dictionary = world.export_state()
	verify(service.entries().size() == 4 and service.validate_state(empty).is_empty(), "old empty world has four default encounter slots")
	verify(Service.validate_snapshot(empty, db).is_empty(), "repository validation accepts a legacy world without encounter records")
	verify(service.record(SOLDIER) == fixture_record("alive"), "missing old-save record means living generation one")
	verify(world.export_state() == empty and notifications.is_empty(), "reading defaults neither materializes state nor publishes events")
	var entries: Array = service.entries()
	var ids: Array[String] = []
	for entry in entries: ids.append(entry.id)
	var sorted := ids.duplicate()
	sorted.sort()
	verify(ids == sorted, "entries have stable ID order for pending reward settlement")
	var point: Array = service.definition(SOLDIER).position
	verify(Vector3(point[0], point[1], point[2]).is_equal_approx(Vector3(29, 2.4, -4)) and service.definition(SOLDIER).safe_distance == 12, "catalog preserves real woodland position and safety distance")
	entries[0].position[0] = 999
	entries[0].record.generation = 9
	var detached: Dictionary = service.definition(SOLDIER)
	detached.position[0] = 888
	verify(service.definition(SOLDIER).position[0] == 29 and service.record(ids[0]).generation == 1, "query results cannot mutate catalog or live records")
	var legacy_definitions: Dictionary = catalog(service)
	for id in legacy_definitions: legacy_definitions[id].erase("arrival_points")
	var legacy := Service.new()
	verify(legacy.setup(world, db, legacy_definitions), "legacy encounter definitions without entry points remain valid")
	var arrivals: Array = service.definition(SOLDIER).arrival_points
	arrivals[0][0] = 999
	verify(service.definition(SOLDIER).arrival_points[0][0] == 26, "entry points are detached from the catalog")
	verify(service.definition("encounter.missing").is_empty() and service.record("encounter.missing").is_empty(), "unknown queries cannot fabricate a living encounter")
	var candidate := empty.duplicate(true)
	candidate.flags["quest.side_story"] = true
	candidate.objects["economy.wallet"] = {"version": 1, "balance": 30, "revision": 1}
	var candidate_before := candidate.duplicate(true)
	var defeat: Dictionary = service.plan_defeat(SOLDIER, 1, candidate)
	verify(defeat.ok and defeat.world.objects[SOLDIER] == fixture_record("cooldown", 1, 45), "living defeat plans full cooldown on the same generation")
	verify(candidate == candidate_before and world.export_state() == empty and notifications.is_empty(), "death planning is pure and silent")
	verify(defeat.world.flags == candidate.flags and defeat.world.objects["economy.wallet"] == candidate.objects["economy.wallet"], "death plan preserves unrelated candidate reward and world changes")
	verify(not service.plan_defeat(SOLDIER, 2, empty).ok and not service.plan_defeat(SOLDIER, 0, empty).ok, "wrong or invalid generation cannot defeat the current life")
	verify(not service.plan_defeat(SOLDIER, 1, defeat.world).ok, "same completed life cannot be resolved twice")
	verify(world.import_state(defeat.world) and notifications.is_empty(), "owner can commit the prepared world silently")
	defeat.world.objects[SOLDIER].remaining = 2
	verify(service.record(SOLDIER).remaining == 45, "committed state is detached from retained plan")
	var cooldown_start: Dictionary = world.export_state()
	var tick: Dictionary = service.plan_tick(86400.0, [SOLDIER])
	verify(tick.ok and tick.world == cooldown_start and tick.spawn_ids.is_empty(), "elapsed playtime never advances defeated lives even at a safe location")
	verify(world.export_state() == cooldown_start, "planning remains pure")
	tick = service.plan_short_rest(cooldown_start)
	verify(tick.ok and tick.spawn_ids == [SOLDIER] and tick.world.objects[SOLDIER] == fixture_record("alive", 2), "short rest creates exactly one next generation")
	verify(world.export_state() == cooldown_start, "short-rest planning cannot publish before owner commits")
	world.import_state(tick.world)
	verify(not service.plan_defeat(SOLDIER, 1, world.export_state()).ok, "old corpse callback cannot resolve a newer spawned generation")
	verify(service.plan_tick(0.0, [SOLDIER]).spawn_ids.is_empty(), "living record is never spawned again by tick")
	verify(service.plan_defeat(SOLDIER, 2, world.export_state()).ok, "new generation remains independently rewardable")
	for delta in [-1.0, NAN, INF, -INF]:
		verify(not service.plan_tick(delta, []).ok, "invalid tick duration is rejected: " + str(delta))
	verify(not service.plan_tick(1.0, ["encounter.missing"]).ok, "unknown safety ID rejects the whole plan")
	var pending: Dictionary = service.plan_pending(SOLDIER, 2, world.export_state())
	verify(pending.ok and pending.world.objects[SOLDIER] == fixture_record("pending", 2), "capacity failure can persist an unpaid defeated life")
	verify(not service.plan_pending(SOLDIER, 2, pending.world).ok and not service.plan_pending(SOLDIER, 1, world.export_state()).ok, "duplicate or stale pending receipt is rejected")
	var loaded := State.new()
	verify(loaded.import_state(JSON.parse_string(JSON.stringify(pending.world))), "pending life survives a real JSON serialization roundtrip")
	var loaded_service := Service.new()
	verify(loaded_service.setup(loaded, db) and loaded_service.record(SOLDIER).phase == "pending", "new service reads persisted pending life without spawning or paying")
	tick = loaded_service.plan_tick(86400.0, [SOLDIER])
	verify(tick.ok and tick.world == loaded.export_state() and tick.spawn_ids.is_empty(), "pending life never counts down or respawns")
	var settled: Dictionary = loaded_service.plan_defeat(SOLDIER, 2, loaded.export_state())
	verify(settled.ok and settled.world.objects[SOLDIER] == fixture_record("cooldown", 2, 45), "pending life can settle once and starts cooldown at settlement")
	verify(not loaded_service.plan_defeat(SOLDIER, 2, settled.world).ok, "settled pending life cannot settle twice")
	verify(not loaded_service.plan_pending(SOLDIER, 2, settled.world).ok, "settled life cannot become pending again")
	var definitions := catalog(service)
	definitions[OGRE].respawn_seconds = 0
	var once_world := State.new()
	var once := Service.new()
	verify(once.setup(once_world, db, definitions), "custom authored slot can declare one-shot defeat")
	definitions[OGRE].respawn_seconds = 45
	verify(once.definition(OGRE).respawn_seconds == 0, "setup takes a detached copy of custom definitions")
	var cleared: Dictionary = once.plan_defeat(OGRE, 1, once_world.export_state())
	verify(cleared.ok and cleared.world.objects[OGRE] == fixture_record("cleared"), "one-shot death produces durable cleared state")
	once_world.import_state(cleared.world)
	tick = once.plan_tick(86400.0, [OGRE])
	verify(tick.ok and tick.spawn_ids.is_empty() and tick.world == once_world.export_state(), "one-shot encounter stays cleared through any elapsed time")
	verify(not once.plan_defeat(OGRE, 1, once_world.export_state()).ok, "cleared encounter cannot be defeated twice")
	var cap := empty.duplicate(true)
	cap.objects[SOLDIER] = fixture_record("cooldown", Service.MAX_GENERATION, 1)
	verify(world.import_state(cap), "maximum generation itself remains a valid save value")
	tick = service.plan_tick(1.0, [])
	verify(tick.ok and tick.world.objects[SOLDIER].generation == Service.MAX_GENERATION, "maximum generation can finish waiting without overflow")
	verify(not service.plan_short_rest(world.export_state()).ok and world.export_state() == cap, "maximum generation cannot wrap, clear itself, or partially commit")
	var full := empty.duplicate(true)
	for index in range(State.MAX_OBJECTS): full.objects["other.slot_%d" % index] = {}
	verify(world.import_state(full), "fixture fills real world object capacity")
	verify(not service.plan_defeat(SOLDIER, 1, full).ok and not service.plan_pending(SOLDIER, 1, full).ok, "full world refuses new death and pending records without losing state")
	verify(world.export_state() == full, "capacity failure leaves every existing object intact")
	full.objects.erase("other.slot_0")
	full.objects[SOLDIER] = fixture_record("alive")
	verify(service.plan_defeat(SOLDIER, 1, full).ok, "existing encounter record can be updated at maximum object capacity")
	world.import_state(empty)
	for entry in [
		{"field": "version", "value": 2}, {"field": "version", "value": true},
		{"field": "generation", "value": 0}, {"field": "generation", "value": 1.5},
		{"field": "generation", "value": Service.MAX_GENERATION + 1},
		{"field": "phase", "value": "sleeping"}, {"field": "phase", "value": 2},
		{"field": "remaining", "value": -1}, {"field": "remaining", "value": 46},
		{"field": "remaining", "value": NAN}, {"field": "remaining", "value": INF},
		{"field": "remaining", "value": true}, {"field": "remaining", "value": "1"},
		{"field": "unexpected", "value": 1}
	]:
		var invalid := empty.duplicate(true)
		invalid.objects[SOLDIER] = fixture_record("cooldown", 1, 15)
		invalid.objects[SOLDIER][entry.field] = entry.value
		reject_state(service, world, invalid, str(entry.field) + "=" + str(entry.value))
	for phase in ["alive", "pending", "cleared"]:
		var invalid := empty.duplicate(true)
		invalid.objects[SOLDIER] = fixture_record(phase, 1, 1)
		reject_state(service, world, invalid, phase + " with nonzero clock")
	var unknown := empty.duplicate(true)
	unknown.objects["encounter.unknown"] = fixture_record("alive")
	reject_state(service, world, unknown, "unknown stable encounter ID")
	verify(not Service.validate_snapshot(unknown, db).is_empty(), "repository validator rejects unknown encounter records")
	var wrong_policy := empty.duplicate(true)
	wrong_policy.objects[SOLDIER] = fixture_record("cleared")
	reject_state(service, world, wrong_policy, "repeatable slot marked permanently cleared")
	wrong_policy = empty.duplicate(true)
	wrong_policy.objects[OGRE] = fixture_record("cooldown")
	verify(not once.validate_state(wrong_policy).is_empty(), "one-shot slot cannot load a cooldown record")
	var missing := empty.duplicate(true)
	missing.objects[SOLDIER] = fixture_record("alive")
	missing.objects[SOLDIER].erase("generation")
	reject_state(service, world, missing, "missing generation field")
	for change in [
		{"field": "enemy_id", "value": "missing"}, {"field": "id", "value": "encounter.wrong"},
		{"field": "position", "value": [0, 0]}, {"field": "position", "value": [INF, 0, 0]},
		{"field": "respawn_seconds", "value": -1}, {"field": "respawn_seconds", "value": INF},
		{"field": "safe_distance", "value": -1}, {"field": "safe_distance", "value": true},
		{"field": "arrival_points", "value": {}}, {"field": "arrival_points", "value": [[0, 0]]},
		{"field": "arrival_points", "value": [[INF, 0, 0]]}, {"field": "arrival_points", "value": [[0, 0, 0], [0, 0, 0]]},
		{"field": "arrival_points", "value": [[29, 2.4, -4]]},
		{"field": "arrival_points", "value": [[0,0,0],[1,0,0],[2,0,0],[3,0,0],[4,0,0],[5,0,0],[6,0,0],[7,0,0],[8,0,0]]},
		{"field": "unexpected", "value": 0}
	]:
		var invalid := catalog(service)
		invalid[SOLDIER][change.field] = change.value
		verify(not service.setup(world, db, invalid) and service.definition(SOLDIER).enemy_id == "soldier", "bad catalog preserves existing binding: " + change.field + "=" + str(change.value))
	var too_many: Dictionary = {}
	for index in range(Service.MAX_ENCOUNTERS + 1):
		var id := "encounter.test_%d" % index
		too_many[id] = service.definition(SOLDIER)
		too_many[id].id = id
	verify(not service.setup(world, db, too_many), "encounter catalog count is bounded")
	verify(not service.setup(null, db) and not service.setup(world, null), "missing world or enemy database fails safely")
	verify(notifications.is_empty(), "all planning, queries and silent commits emitted no live events")
	print("ENCOUNTER_SERVICE_RESULT %d/%d passed" % [checks - failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
