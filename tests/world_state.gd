extends SceneTree
## Pure state tests: no scene assets, save slots, or user profile files are touched.
const State = preload("res://rpg/world_state.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
	print("PASS " if ok else "FAIL ", label)

func invalid_import(state: RefCounted, candidate: Dictionary, label: String) -> void:
	var before: Dictionary = state.export_state()
	verify(not state.validate_state(candidate).is_empty(), "validation rejects " + label)
	verify(not state.import_state(candidate) and not state.last_error.is_empty(), "import rejects " + label)
	verify(state.export_state() == before, "failed import is atomic: " + label)

func run() -> void:
	var state := State.new()
	var flag_events: Array = []
	var object_events: Array = []
	var live_events: Array = []
	state.flag_changed.connect(func(id: String, value: Variant): flag_events.append({"id": id, "value": value}))
	state.object_changed.connect(func(id: String): object_events.append(id))
	state.event_recorded.connect(func(event: Dictionary): live_events.append(event))
	verify(state.validate_state(state.export_state()).is_empty(), "new adventure has valid explicit schema")
	verify(state.export_state().version == 1 and state.get_flag("absent") == null and state.get_object("absent").is_empty(), "empty defaults are predictable")
	var default_value := {"list": [1]}
	var returned_default: Dictionary = state.get_flag("absent", default_value)
	returned_default.list.append(2)
	verify(default_value.list == [1], "caller default is copied")
	verify(state.get_flag("absent", RefCounted.new()) == null, "non-JSON defaults cannot expose object references")
	var flag_value := {"list": [true, null, 3.25, "风铃村"]}
	verify(state.set_flag("chapter.1/started", flag_value), "nested JSON flag accepted")
	flag_value.list.append("caller mutation")
	var returned_flag: Dictionary = state.get_flag("chapter.1/started")
	returned_flag.list.append("getter mutation")
	flag_events[0].value.list.append("listener mutation")
	verify(state.get_flag("chapter.1/started").list.size() == 4, "flag input, output, and emitted payload cannot mutate storage")
	verify(not state.set_flag("chapter.1/started", state.get_flag("chapter.1/started")) and flag_events.size() == 1, "equal flag is a silent no-op")
	verify(state.set_flag("nullable", null) and not state.set_flag("nullable", null), "explicit null is distinguishable from absence for writes")
	var object_value := {"opened": true, "reward": {"items": ["healing_potion"]}}
	verify(state.set_object("village/chest:001", object_value), "stable scene-independent object ID accepted")
	object_value.reward.items.append("external")
	var returned_object: Dictionary = state.get_object("village/chest:001")
	returned_object.reward.items.append("external")
	verify(state.get_object("village/chest:001").reward.items.size() == 1, "object getters and setters deep copy")
	verify(not state.set_object("village/chest:001", state.get_object("village/chest:001")) and object_events.size() == 1, "equal object is a silent no-op")
	verify(state.record_event("enemy_defeated", "soldier", 2, "encounter:001/soldier:1"), "subject event records amount and occurrence ID")
	var before_duplicate: Dictionary = state.export_state()
	verify(not state.record_event("enemy_defeated", "soldier", 2, "encounter:001/soldier:1") and state.export_state() == before_duplicate and live_events.size() == 1, "same occurrence cannot grant event credit twice")
	verify(not state.record_event("different_event", "", 1, "encounter:001/soldier:1"), "deduplication IDs are global across event types")
	verify(state.record_event("enemy_defeated", "ogre", 3) and state.record_event("enemy_defeated"), "repeatable and subjectless events supported")
	verify(state.get_event_count("enemy_defeated") == 6 and state.get_event_count("enemy_defeated", "soldier") == 2 and state.get_event_count("enemy_defeated", "ogre") == 3, "aggregate includes each event once and subjects retain separate counts")
	verify(state.get_event_count("missing") == 0 and state.get_event_count("enemy_defeated", "missing") == 0, "unknown event queries return zero")
	verify(live_events[0] == {"type": "enemy_defeated", "subject": "soldier", "amount": 2, "source_id": "encounter:001/soldier:1", "total": 2, "subject_total": 2}, "event payload exposes committed totals")
	live_events[0].amount = 100
	verify(state.get_event_count("enemy_defeated", "soldier") == 2, "event payload is detached")
	var exported: Dictionary = state.export_state()
	exported.objects["village/chest:001"].opened = false
	exported.counters.enemy_defeated[""] = 100
	verify(state.get_object("village/chest:001").opened and state.get_event_count("enemy_defeated") == 6, "export is a fully detached snapshot")
	var encoded := JSON.stringify(state.export_state())
	var decoded: Dictionary = JSON.parse_string(encoded)
	var loaded := State.new()
	var import_signals: Array = []
	loaded.event_recorded.connect(func(event: Dictionary): import_signals.append(event))
	loaded.flag_changed.connect(func(id: String, value: Variant): import_signals.append([id, value]))
	loaded.object_changed.connect(func(id: String): import_signals.append(id))
	verify(loaded.import_state(decoded) and loaded.export_state() == state.export_state(), "real JSON roundtrip preserves flags, objects, counters, and deduplication")
	verify(import_signals.is_empty(), "loading never replays reward or gameplay signals")
	decoded.flags.nullable = "changed"
	verify(loaded.get_flag("nullable") == null, "imported input cannot mutate storage afterward")
	verify(not loaded.record_event("enemy_defeated", "soldier", 2, "encounter:001/soldier:1"), "deduplication survives save/load")
	var second_adventure := State.new()
	verify(second_adventure.record_event("enemy_defeated", "soldier", 2, "encounter:001/soldier:1"), "deduplication is isolated per adventure")
	var reordered: Dictionary = {"version": 1, "seen_events": {"z": true, "a": true}, "counters": {}, "objects": {}, "flags": {"z": {"y": 1, "a": 2}, "a": true}}
	var canonical := State.new()
	verify(canonical.import_state(reordered), "unordered valid input accepted")
	verify(JSON.stringify(canonical.export_state()) == '{"counters":{},"flags":{"a":true,"z":{"a":2,"y":1}},"objects":{},"seen_events":{"a":true,"z":true},"version":1}', "export serializes keys in deterministic recursive order")
	var before_invalid: Dictionary = state.export_state()
	var signal_count := flag_events.size() + object_events.size() + live_events.size()
	for id in ["", "white space", "line\nbreak", "中文", "a".repeat(State.MAX_ID_LENGTH + 1)]:
		verify(not state.set_flag(id, true) and not state.set_object(id, {}) and not state.record_event(id), "invalid IDs rejected: " + id.substr(0, 14).replace("\n", "\\n"))
	for value in [Vector3.ZERO, Color.WHITE, RefCounted.new(), NAN, INF, -INF, 9007199254740992, {1: "numeric key"}, PackedStringArray(["not JSON"]), "x".repeat(State.MAX_STRING_LENGTH + 1)]:
		verify(not state.set_flag("invalid", value), "reject non-JSON or unbounded flag type " + str(typeof(value)))
	verify(not state.set_object("invalid", {"nested": [RefCounted.new()]}), "nested executable objects rejected")
	verify(not state.record_event("kill", "", 0) and not state.record_event("kill", "", -1) and not state.record_event("kill", "bad id") and not state.record_event("kill", "", 1, "bad id"), "invalid event inputs rejected")
	verify(state.export_state() == before_invalid and flag_events.size() + object_events.size() + live_events.size() == signal_count, "failed live mutations preserve state and emit no signals")
	var excessive_depth: Array = []
	var cursor := excessive_depth
	for index in range(State.MAX_JSON_DEPTH + 1):
		var child: Array = []
		cursor.append(child)
		cursor = child
	verify(not state.set_flag("too_deep", excessive_depth), "excessive nesting rejected without recursion failure")
	var cyclic: Dictionary = {}
	cyclic["self"] = cyclic
	verify(not state.set_flag("cycle", cyclic) and state.get_flag("absent", cyclic) == null, "cyclic data rejected before copying or serializing")
	cyclic.clear()
	var too_many: Array = []
	too_many.resize(State.MAX_CONTAINER_SIZE + 1)
	verify(not state.set_object("wide", {"entries": too_many}), "oversized nested containers rejected")
	var bad: Dictionary = state.export_state()
	bad.extra = true
	invalid_import(state, bad, "unknown schema field")
	bad = state.export_state()
	bad.erase("objects")
	invalid_import(state, bad, "missing schema field")
	for version in [2, true, "1", 1.5, NAN]:
		bad = state.export_state()
		bad.version = version
		invalid_import(state, bad, "invalid version " + str(version))
	bad = state.export_state()
	bad.flags = []
	invalid_import(state, bad, "wrong section type")
	bad = state.export_state()
	bad.objects["broken"] = 1
	invalid_import(state, bad, "non-object persistent object state")
	for counters in [{"kill": {}}, {"kill": {"": 1, "soldier": 2}}, {"kill": {"": 0}}, {"kill": {"": 1.5}}, {"kill": {"": true}}, {"kill": {"": 2, "soldier": 1, "ogre": 2}}]:
		bad = state.export_state()
		bad.counters = counters
		invalid_import(state, bad, "malformed or inconsistent counters")
	for entry in [false, 1, "true", {}]:
		bad = state.export_state()
		bad.seen_events["invalid"] = entry
		invalid_import(state, bad, "invalid deduplication marker")
	bad = state.export_state()
	bad.flags["invalid"] = {"deep": INF}
	invalid_import(state, bad, "non-finite imported number")
	bad = State.new().export_state()
	for index in range(State.MAX_FLAGS + 1):
		bad.flags["flag_%d" % index] = true
	invalid_import(state, bad, "flag capacity overflow")
	bad = State.new().export_state()
	for index in range(300):
		bad.flags["large_%d" % index] = "x".repeat(State.MAX_STRING_LENGTH)
	invalid_import(state, bad, "serialized byte capacity overflow")
	var capped := State.new()
	var full: Dictionary = capped.export_state()
	for index in range(State.MAX_SEEN_EVENTS):
		full.seen_events["source_%d" % index] = true
	verify(capped.import_state(full), "deduplication capacity can be fully used")
	var before_cap: Dictionary = capped.export_state()
	verify(not capped.record_event("kill", "soldier", 1, "one_more") and capped.export_state() == before_cap, "full deduplication registry fails atomically without evicting old IDs")
	verify(not capped.record_event("kill", "soldier", 1, "source_0"), "old IDs remain consumed at capacity")
	verify(capped.record_event("kill", "soldier"), "repeatable events still work when deduplication capacity is full")
	var overflow := State.new()
	verify(overflow.record_event("kill", "soldier", State.MAX_COUNTER), "maximum supported counter is accepted")
	var before_overflow: Dictionary = overflow.export_state()
	verify(not overflow.record_event("kill", "soldier", 1, "overflow") and overflow.export_state() == before_overflow, "counter overflow rejects atomically and does not consume source ID")
	verify(overflow.record_event("visit", "village", 1, "overflow"), "rejected event source ID remains usable")
	print("WORLD STATE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
