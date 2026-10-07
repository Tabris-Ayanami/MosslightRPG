extends SceneTree
## One energy pool across live growth, temporary bodies and old checksummed saves.
const Repository = preload("res://rpg/save_repository.gd")
const Resources = preload("res://combat/resource_component.gd")
var checks := 0
var failures: Array[String] = []
var game: Node
var actor: Node
var workspace := ""

func _initialize() -> void:
	preload("res://rpg/game_preferences.gd").settings_path = OS.get_temp_dir().path_join("mosslight-energy-prefs-%d.cfg" % OS.get_process_id())
	call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ", label)
func same(a: Dictionary, b: Dictionary) -> bool:
	return JSON.stringify(a) == JSON.stringify(b)
func envelope(path: String, snapshot: Dictionary) -> void:
	var payload := JSON.stringify(snapshot)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"format": "mosslight_adventure", "version": snapshot.version,
		"payload_json": payload, "sha256": payload.sha256_text()}))
	file.close()
func ratio() -> float:
	return actor.resources.current("Energy") / maxf(.001, actor.resources.max_value("Energy"))

func run() -> void:
	var resources := Resources.new()
	root.add_child(resources)
	resources.configure("Energy", 100.0)
	resources.change("Energy", -62.5)
	check(resources.pay({"Energy": 12.25}) and is_equal_approx(resources.current("Energy"), 25.25), "energy payments retain fractional values instead of rounding to pips")
	resources.configure("Qi", 3)
	resources.configure("SpellSlot", 3)
	check(resources.pools.keys() == ["Energy"], "legacy names cannot create a second runtime energy pool")
	check(Resources.migrated_values({"HP": 100, "Qi": 3, "SpellSlot": 2}) == {"HP": 100, "Energy": 60.0}, "legacy capacities merge by maximum at twenty energy per point")
	check(Resources.migrated_values({"Qi": 3, "SpellSlot": 2, "Energy": 17.5}) == {"Energy": 17.5}, "explicit energy wins over legacy aliases without adding them")
	resources.queue_free()
	workspace = OS.get_temp_dir().path_join("mosslight-energy-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var repository := Repository.new(workspace)
	var created: Dictionary = repository.create("统一能量迁移回归", 0)
	check(created.ok and created.snapshot.version == Repository.VERSION and created.snapshot.resources == {"HP": 100.0, "Stamina": 3.0, "Energy": 0.0}, "new civilian save has the current version and one empty energy pool")
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await ticks(15)
	actor = game.player
	game.sound.muted = true
	game.combat_world.encounters_started = true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	actor.set_physics_process(false)
	check(repository.restore(created.snapshot, actor, game).ok and actor.resources.max_value("Energy") == 0 and actor.resources.pools.size() == 3, "real main-world civilian restores exactly HP, stamina and empty energy")
	check(actor.progression.choose_career("warrior") and actor.resources.max_value("Energy") == 60, "choosing warrior converts the former three-point pool into sixty energy")
	actor.resources.change("Energy", 31.5 - actor.resources.current("Energy"))
	var fraction := ratio()
	var before_max: float = actor.resources.max_value("Energy")
	for i in range(3):
		actor.progression.level_up()
		if actor.resources.max_value("Energy") > before_max: break
	check(actor.resources.max_value("Energy") > before_max and is_equal_approx(ratio(), fraction), "career growth changes energy maximum while keeping its current fraction")
	var target: Node = game.combat_world.spawn_enemy("soldier", actor.global_position + Vector3.RIGHT * 5)
	target.set_physics_process(false)
	var control: Node = game.combat_world.control
	var energy: float = actor.resources.current("Energy")
	check(control.possess(target, 30) and target.resources.max_value("Energy") == 0 and actor.resources.current("Energy") == energy, "possession uses the controlled body's own energy without copying or consuming the owner's pool")
	control.release()
	check(actor.form.apply_enemy_form("fire_elemental", 30) and actor.resources.max_value("Energy") == 0, "a zero-energy temporary body does not invent a second casting resource")
	check(is_equal_approx(actor.form.canonical_resources().Energy / actor.form.canonical_max_resources().Energy, fraction), "canonical saving retains the dormant energy fraction while transformed")
	before_max = actor.form.canonical_max_resources().Energy
	for i in range(3):
		actor.progression.level_up()
		if actor.form.canonical_max_resources().Energy > before_max: break
	check(actor.form.canonical_max_resources().Energy > before_max and actor.form.restore() and is_equal_approx(ratio(), fraction), "growth inside a temporary body restores the live career maximum at the preserved energy fraction")
	actor.resource_profile = {"Qi": 2, "SpellSlot": 1}
	actor.loadout.refresh_resources(false)
	check(actor.resources.max_value("Energy") == 40 and is_equal_approx(ratio(), fraction), "legacy native profiles use the larger capacity and preserve energy fraction")
	actor.resource_profile.Energy = 10
	actor.loadout.refresh_resources(false)
	check(actor.resources.max_value("Energy") == 10 and not actor.resources.pools.has("Qi") and not actor.resources.pools.has("SpellSlot"), "an explicit native Energy profile takes precedence and leaves no old pools")
	actor.resource_profile = {}
	actor.loadout.refresh_resources(false)
	var saved: Dictionary = repository.save(0, "统一能量迁移回归", actor, game)
	check(saved.ok and saved.snapshot.resources.keys().size() == 3 and saved.snapshot.resources.has("Energy"), "real grown character saves only the three canonical resources")
	if not saved.ok:
		print("SAVE_ERROR ", saved.error)
		finish()
		return
	var canonical: Dictionary = saved.snapshot
	var legacy: Dictionary = canonical.duplicate(true)
	legacy.version = 3
	legacy.erase("content_set")
	legacy.resources = {"HP": canonical.resources.HP, "Stamina": canonical.resources.Stamina,
		"Qi": canonical.resources.Energy / 40.0, "SpellSlot": canonical.resources.Energy / 20.0}
	for version in [1, 2, 3]:
		var source: Dictionary = legacy.duplicate(true)
		source.version = version
		if version < 3: source.erase("race_id")
		if version < 2: source.erase("world_state")
		var before := source.duplicate(true)
		var migrated: Dictionary = repository.migrate_snapshot(source)
		check(migrated.ok and migrated.snapshot.version == Repository.VERSION and is_equal_approx(migrated.snapshot.resources.Energy, canonical.resources.Energy), "v%d migrates both old pools by max rather than summing them" % version)
		check(same(source, before), "v%d migration leaves its input snapshot unchanged" % version)
	var disk_path: String = repository._path(0)
	envelope(disk_path, legacy)
	var disk_before := FileAccess.get_file_as_bytes(disk_path)
	var loaded: Dictionary = Repository.new(workspace).load_slot(0)
	check(loaded.ok and loaded.snapshot.version == Repository.VERSION and is_equal_approx(loaded.snapshot.resources.Energy, canonical.resources.Energy), "fresh repository reads and migrates a real v3 checksummed file")
	check(FileAccess.get_file_as_bytes(disk_path) == disk_before, "reading an old file does not rewrite its bytes or checksum")
	actor.resources.change("Energy", -actor.resources.current("Energy"))
	check(repository.restore(legacy, actor, game).ok and is_equal_approx(actor.resources.current("Energy"), canonical.resources.Energy), "restore accepts a validated legacy snapshot and applies continuous energy")
	for bad in [-1, true, "2", 1000001]:
		var invalid := legacy.duplicate(true)
		invalid.resources.Qi = bad
		energy = actor.resources.current("Energy")
		check(not repository.restore(invalid, actor, game).ok and actor.resources.current("Energy") == energy, "invalid old energy value is rejected without changing the live actor: " + str(bad))
	var invalid := canonical.duplicate(true)
	invalid.resources.Qi = 1
	check(not repository.migrate_snapshot(invalid).ok, "current version rejects mixed legacy and canonical resource keys")
	var resaved: Dictionary = repository.save(0, "统一能量迁移回归", actor, game)
	var disk: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(disk_path))
	var payload: Dictionary = JSON.parse_string(disk.payload_json)
	check(resaved.ok and disk.version == Repository.VERSION and payload.resources.has("Energy") and not payload.resources.has("Qi") and not payload.resources.has("SpellSlot"), "the next explicit save writes the current envelope without either old pool")
	finish()

func finish() -> void:
	if is_instance_valid(game): game.queue_free()
	await ticks(3)
	var directory := DirAccess.open(workspace)
	if directory != null:
		for filename in directory.get_files(): DirAccess.remove_absolute(workspace.path_join(filename))
		DirAccess.remove_absolute(workspace)
	print("ENERGY_MIGRATION_RESULT %d/%d passed" % [checks - failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
