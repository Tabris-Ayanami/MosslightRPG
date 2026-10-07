extends RefCounted
## One adventure's persistent facts. Scene nodes and quest controllers are consumers,
## never part of the serialized state. Loading is silent: it does not replay rewards.

signal flag_changed(id: String, value: Variant)
signal object_changed(id: String)
signal event_recorded(event: Dictionary)

const VERSION := 1
const MAX_ID_LENGTH := 128
const MAX_FLAGS := 2048
const MAX_OBJECTS := 2048
const MAX_EVENT_TYPES := 256
const MAX_SUBJECTS := 2048
const MAX_SEEN_EVENTS := 16384
const MAX_COUNTER := 2147483647
const MAX_JSON_DEPTH := 8
const MAX_JSON_NODES := 65536
const MAX_CONTAINER_SIZE := 512
const MAX_STRING_LENGTH := 4096
const MAX_STATE_BYTES := 1048576
const MAX_SAFE_NUMBER := 9007199254740991.0
const ROOT_KEYS := ["version", "flags", "objects", "counters", "seen_events"]

var last_error := ""
var _state: Dictionary = {"version": VERSION, "flags": {}, "objects": {}, "counters": {}, "seen_events": {}}

func get_flag(id: String, default_value: Variant = null) -> Variant:
	if _state.flags.has(id):
		return _copy_json(_state.flags[id])
	# An arbitrary caller default must not bypass the copy boundary or recurse forever.
	return _copy_json(default_value) if _json_error(default_value, 0, [0]).is_empty() else null

func set_flag(id: String, value: Variant) -> bool:
	if not _valid_id(id):
		return _reject("Invalid flag ID")
	var reason := _json_error(value, 0, [0])
	if not reason.is_empty():
		return _reject(reason)
	if _state.flags.has(id) and _state.flags[id] == value:
		last_error = ""
		return false
	var candidate := export_state()
	candidate.flags[id] = _copy_json(value)
	if not _commit(candidate):
		return false
	flag_changed.emit(id, _copy_json(value))
	return true

func get_object(id: String) -> Dictionary:
	return _copy_json(_state.objects.get(id, {}))

func set_object(id: String, state: Dictionary) -> bool:
	if not _valid_id(id):
		return _reject("Invalid object ID")
	var reason := _json_error(state, 0, [0])
	if not reason.is_empty():
		return _reject(reason)
	if _state.objects.has(id) and _state.objects[id] == state:
		last_error = ""
		return false
	var candidate := export_state()
	candidate.objects[id] = _copy_json(state)
	if not _commit(candidate):
		return false
	object_changed.emit(id)
	return true

## Empty subject requests the total across all subjects, including subjectless events.
func get_event_count(type: String, subject: String = "") -> int:
	return int(_state.counters.get(type, {}).get(subject, 0))

## source_id identifies this occurrence globally within the adventure. Use stable
## IDs for one-shot actions; repeatable actions must supply a fresh occurrence ID
## or leave it empty. Deduplication IDs are never evicted, so old rewards stay spent.
func record_event(type: String, subject: String = "", amount: int = 1, source_id: String = "") -> bool:
	if not _valid_id(type) or (not subject.is_empty() and not _valid_id(subject)) or (not source_id.is_empty() and not _valid_id(source_id)):
		return _reject("Invalid event, subject, or source ID")
	if amount < 1 or amount > MAX_COUNTER:
		return _reject("Event amount is outside the supported range")
	if not source_id.is_empty() and _state.seen_events.has(source_id):
		last_error = ""
		return false
	var total := get_event_count(type)
	if total > MAX_COUNTER - amount:
		return _reject("Event counter is full")
	var candidate := export_state()
	if not candidate.counters.has(type):
		candidate.counters[type] = {"": 0}
	candidate.counters[type][""] = total + amount
	if not subject.is_empty():
		candidate.counters[type][subject] = get_event_count(type, subject) + amount
	if not source_id.is_empty():
		candidate.seen_events[source_id] = true
	if not _commit(candidate):
		return false
	event_recorded.emit({"type": type, "subject": subject, "amount": amount, "source_id": source_id,
		"total": total + amount, "subject_total": get_event_count(type, subject)})
	return true

## Sorted keys make equivalent state produce deterministic JSON. Every result is
## detached from the service, including nested arrays and dictionaries.
func export_state() -> Dictionary:
	return _copy_json(_state)

## A successful import is atomic and intentionally emits no live gameplay signals.
func import_state(state: Dictionary) -> bool:
	return _commit(state)

func validate_state(state: Dictionary) -> String:
	if state.size() != ROOT_KEYS.size():
		return "World state has missing or unknown fields"
	for key in state:
		if not key is String:
			return "World state field names must be JSON strings"
	for key in ROOT_KEYS:
		if not state.has(key):
			return "World state has missing or unknown fields"
	if not _integer(state.version, VERSION, VERSION):
		return "Unsupported world state version"
	for key in ["flags", "objects", "counters", "seen_events"]:
		if not state[key] is Dictionary:
			return "World state section must be an object: " + key
	if state.flags.size() > MAX_FLAGS or state.objects.size() > MAX_OBJECTS or state.counters.size() > MAX_EVENT_TYPES or state.seen_events.size() > MAX_SEEN_EVENTS:
		return "World state capacity exceeded"
	var budget := [0]
	for id in state.flags:
		if not _valid_id(id):
			return "Invalid flag ID"
		var reason := _json_error(state.flags[id], 0, budget)
		if not reason.is_empty():
			return reason
	for id in state.objects:
		if not _valid_id(id) or not state.objects[id] is Dictionary:
			return "Invalid object ID or state"
		var reason := _json_error(state.objects[id], 0, budget)
		if not reason.is_empty():
			return reason
	for type in state.counters:
		if not _valid_id(type) or not state.counters[type] is Dictionary:
			return "Invalid event counter"
		var counts: Dictionary = state.counters[type]
		if counts.size() > MAX_SUBJECTS + 1 or not counts.has(""):
			return "Event counter requires a total and bounded subjects"
		var subject_sum := 0
		for subject in counts:
			if not subject is String or (subject != "" and not _valid_id(subject)) or not _integer(counts[subject], 1, MAX_COUNTER):
				return "Invalid event subject or count"
			if subject != "":
				subject_sum += int(counts[subject])
		if subject_sum > int(counts[""]):
			return "Event subjects exceed the recorded total"
	for source in state.seen_events:
		if not _valid_id(source) or not state.seen_events[source] is bool or state.seen_events[source] != true:
			return "Invalid event deduplication entry"
	if JSON.stringify(state).to_utf8_buffer().size() > MAX_STATE_BYTES:
		return "World state exceeds the serialized size limit"
	return ""

func _commit(candidate: Dictionary) -> bool:
	var reason := validate_state(candidate)
	if not reason.is_empty():
		return _reject(reason)
	var copy: Dictionary = _copy_json(candidate)
	copy.version = VERSION
	for type in copy.counters:
		for subject in copy.counters[type]:
			copy.counters[type][subject] = int(copy.counters[type][subject])
	_state = copy
	last_error = ""
	return true

func _reject(reason: String) -> bool:
	last_error = reason
	return false

func _valid_id(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > MAX_ID_LENGTH:
		return false
	for index in range(value.length()):
		var code: int = value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code in [45, 46, 47, 58, 95]):
			return false
	return true

func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and value >= minimum and value <= maximum

func _json_error(value: Variant, depth: int, budget: Array) -> String:
	budget[0] += 1
	if depth > MAX_JSON_DEPTH or budget[0] > MAX_JSON_NODES:
		return "JSON nesting or node limit exceeded"
	match typeof(value):
		TYPE_NIL, TYPE_BOOL:
			return ""
		TYPE_INT, TYPE_FLOAT:
			if not is_finite(float(value)) or absf(float(value)) > MAX_SAFE_NUMBER:
				return "JSON number must be finite and safely representable"
			return ""
		TYPE_STRING:
			return "" if value.length() <= MAX_STRING_LENGTH else "JSON string is too long"
		TYPE_ARRAY, TYPE_DICTIONARY:
			if value.size() > MAX_CONTAINER_SIZE:
				return "JSON container is too large"
			if value is Dictionary:
				for key in value:
					if not key is String or key.is_empty() or key.length() > MAX_ID_LENGTH:
						return "JSON object keys must be nonempty bounded strings"
					var reason := _json_error(value[key], depth + 1, budget)
					if not reason.is_empty():
						return reason
			else:
				for entry in value:
					var reason := _json_error(entry, depth + 1, budget)
					if not reason.is_empty():
						return reason
			return ""
		_:
			return "World state only accepts JSON values"

func _copy_json(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort()
		for key in keys:
			result[key] = _copy_json(value[key])
		return result
	if value is Array:
		var result: Array = []
		for entry in value:
			result.append(_copy_json(entry))
		return result
	return value
