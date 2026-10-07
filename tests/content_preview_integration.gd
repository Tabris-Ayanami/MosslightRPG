extends SceneTree
## Real App/map coverage of an explicitly compiled preview bundle. Procedural X
## icons are routing fixtures, not production art. All settings/saves stay in Temp.
## Build with: python tools/content_pipeline/tests/runtime_preview_fixture.py
## Run with: godot --headless --path . --script res://tests/content_preview_integration.gd
##   -- --bundle=ABSOLUTE_COMPILED_FIXTURE_DIRECTORY
## Omit --headless for the four GPU screenshots in docs/content-preview/.
const Database = preload("res://combat/combat_database.gd")
const Preferences = preload("res://rpg/game_preferences.gd")
const Repository = preload("res://rpg/save_repository.gd")
const BINDINGS = preload("res://scripts/frontend/journal_bindings.gd")
const ITEM := "trail_guard:herbal_draught"
const TOKEN := "trail_guard:energy_token"
const ACTION := "trail_guard:energy_token_action"
const WEAPON := "trail_guard:watch_sword"
const ARMOR := "trail_guard:scout_hood"
const SKILL := "trail_guard:guard_cut"
const PASSIVE := "trail_guard:steady_breath"
const CAREER := "trail_guard:warden"
var app: Node
var actor: Node
var database: RefCounted
var repository: RefCounted
var isolated := ""
var checks := 0
var failures: Array[String] = []
var restore_notifications := 0

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
	print("PASS " if value else "FAIL ", label)

func ticks(count: int) -> void:
	for _i in range(count):
		await physics_frame
		await process_frame

func settle() -> void:
	await ticks(2)
	for _i in range(160):
		if not app.ui.is_animating(): break
		await ticks(1)
	await ticks(2)

func button(label: String) -> Button:
	for node in app.ui.modal.get_children():
		if node is Button and node.text == label: return node
	return null

func press(label: String) -> void:
	await settle()
	var control := button(label)
	check(is_instance_valid(control), "live native button exists: " + label)
	if not is_instance_valid(control): return
	check(not control.disabled, "live native button enabled: " + label)
	if not control.disabled: control.pressed.emit()
	await settle()

func select_item(id: String) -> void:
	for index in app.ui.item_buttons:
		if app.ui.item_at(index).get("id", "") == id:
			app.ui.item_buttons[index].pressed.emit()
			await settle()
			return
	check(false, "live inventory card exists: " + id)

func inventory_button(id: String) -> Button:
	for index in app.ui.item_buttons:
		if app.ui.item_at(index).get("id", "") == id:
			return app.ui.item_buttons[index]
	return null

func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://docs/content-preview")
	DirAccess.make_dir_recursive_absolute(directory)
	var error := root.get_texture().get_image().save_png(directory.path_join(label + ".png"))
	check(error == OK, "GPU screenshot saved: " + label)

func start_app(snapshot: Dictionary) -> void:
	app = load("res://scenes/frontend/app.tscn").instantiate()
	# Inject before _ready can enumerate adventures or read settings.
	app.saves = repository
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	# _ready enters the title screen and intentionally clears selection first.
	app.selected_name = str(snapshot.get("name", "内容联合测试"))
	app.selected_save = 0
	app.pending_snapshot = snapshot.duplicate(true)
	app._enter_world(load("res://scenes/main.tscn"))
	check(is_instance_valid(app.game), "real main scene starts with isolated snapshot")
	if not is_instance_valid(app.game): return
	app._finish_arrival()
	app.ui.modulate.a = 1
	app.ui.region_clock = 0
	actor = app.game.rpg
	for enemy in actor.arena.enemies:
		enemy.ai_enabled = false
	await settle()

func actor_snapshot() -> String:
	var resources := {}
	for resource in ["HP", "Stamina", "Energy"]:
		resources[resource] = actor.resources.current(resource)
	return JSON.stringify({"inventory": actor.inventory.export_state(),
		"progression": actor.progression.export_state(), "loadout": actor.loadout.export_state(),
		"resources": resources, "cooldowns": actor.combat.cooldowns,
		"world": app.game.world_state.export_state(), "position": str(actor.global_position)}, "", true)

func run() -> void:
	create_timer(180, true).timeout.connect(func():
		printerr("CONTENT_PREVIEW_INTEGRATION TIMEOUT; inspect preceding script errors")
		quit(1))
	root.size = Vector2i(1600, 900)
	var bundle_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--bundle="): bundle_path = argument.trim_prefix("--bundle=")
	if bundle_path.is_empty():
		printerr("Supply -- --bundle=ABSOLUTE_COMPILED_FIXTURE_DIRECTORY")
		quit(2)
		return
	var selected := Database.configure_content_bundle(bundle_path)
	check(selected.ok, "explicit bundle configuration precedes every database instance: " + str(selected.error))
	if not selected.ok:
		quit(1)
		return
	isolated = OS.get_temp_dir().path_join("mosslight-content-integration-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path = isolated.path_join("preferences.cfg")
	repository = Repository.new(isolated.path_join("adventures"))
	database = Database.new()
	check(database.is_active(), "explicit preview content set is active")
	# Constructors only: never enumerate or create these user-directory paths.
	var safe_default: String = ProjectSettings.globalize_path("user://content-previews/" + str(selected.identity.bundle_sha256) + "/adventures").simplify_path()
	check(Repository.new().directory == safe_default, "active content redirects an omitted save path to its preview hash")
	if OS.has_feature("windows"):
		check(Repository.new(ProjectSettings.globalize_path("user://adventures").to_upper()).directory == safe_default, "Windows uppercase formal-path alias redirects before any directory IO")
	check(database.identity() == selected.identity and repository.database.identity() == selected.identity, "all database instances share the compiled identity")
	check(database.errors.is_empty(), "merged database has no loading errors")
	for catalog in {"items": ITEM, "weapons": WEAPON, "equipment": ARMOR, "skills": SKILL, "passives": PASSIVE, "careers": CAREER}:
		var id: String = {"items": ITEM, "weapons": WEAPON, "equipment": ARMOR, "skills": SKILL, "passives": PASSIVE, "careers": CAREER}[catalog]
		check(database.get(catalog).has(id), "real merged catalog contains " + catalog + "/" + id)
		var texture: Texture2D = database.get_content_icon(catalog, id)
		check(texture != null and texture.get_size() == Vector2(64, 64), "verified PNG decodes for " + catalog)
		check(texture == repository.database.get_content_icon(catalog, id), "texture cache shared between databases: " + catalog)
	check(database.get_content_icon("items", ITEM) != database.get_content_icon("skills", SKILL), "different asset bindings do not collapse into one fallback icon")
	check(database.get_content_icon("items", "healing_potion") == null, "base item retains procedural fallback without a new binding")
	var original_item: Dictionary = database.items[ITEM].duplicate(true)
	repository.database.items[ITEM].name = "MUTATION PROBE"
	check(database.items[ITEM] == original_item, "catalog instances are independent deep copies")
	repository.database.items[ITEM] = original_item.duplicate(true)
	var created: Dictionary = repository.create("内容联合测试", 0)
	check(created.ok, "new adventure is created only in explicit Temp repository")
	if not created.ok:
		printerr(created.error)
		var temp_snapshot: String = repository.directory.path_join("slot_01.json.tmp")
		if FileAccess.file_exists(temp_snapshot):
			printerr("ISOLATED_TEMP_VERIFY ", repository._read(temp_snapshot))
		quit(1)
		return
	check(created.snapshot.version == 5 and created.snapshot.content_set == selected.identity, "v5 new snapshot records exact active content identity")
	await start_app(created.snapshot)
	check(actor == app.game.player and app.ui.rpg == actor, "real App presenter is bound to the playable map actor")
	check(actor.loadout.database.identity() == selected.identity and actor.arena.database.identity() == selected.identity, "world actor and combat arena use identical merged content")
	check(actor.loadout.level == 0 and paused, "fresh preview enters the real initial career page")
	await press("战士")
	check(actor.loadout.career_ids == ["warrior"], "real career card selects warrior")
	check(actor.progression.level_up() and actor.progression.level_up(), "normal progression reaches level three")
	app.ui._select_career()
	await settle()
	await press("巡林卫士")
	check(actor.loadout.career_ids == ["warrior", CAREER], "new career link can be advanced through live career card")
	check(SKILL in actor.loadout.available_skills and PASSIVE in actor.loadout.passive_ids, "new career grants its active and passive definitions")
	check(actor.progression.learn_skill(SKILL), "new active skill is explicitly learnable")
	check(actor.loadout.assign_skill(0, 0, SKILL), "new learned skill can be prepared in A Q")
	for id in [ITEM, TOKEN, WEAPON, ARMOR]:
		check(actor.inventory.add_item(id, 3 if id in [ITEM, TOKEN] else 1), "test reward grant owns new definition: " + id)
	await settle()
	app.ui.show_panel("bag")
	await settle()
	await press("武器")
	await select_item(WEAPON)
	await press("装备至 A")
	check(actor.loadout.weapon_at(0).id == WEAPON, "live inventory equips newly loaded weapon")
	await press("护具")
	await select_item(ARMOR)
	await press("穿戴")
	check(actor.loadout.equipment.head == ARMOR, "live inventory wears newly loaded head equipment")
	check(actor.stats.modifiers.equipment_head == database.equipment[ARMOR].modifiers, "new armor applies the exact derived stat modifiers")
	var outfit: RefCounted = app.paper_doll_hero.outfit
	check(outfit.equipment.head.id == ARMOR and outfit.equipment.head.visual == database.equipment[ARMOR].visual, "paper doll resolves new equipment ID into the real visual definition")
	check(not outfit.surfaces.is_empty(), "paper doll has actual garment shader surfaces")
	for entry in outfit.surfaces:
		check(entry.material.get_shader_parameter("head_color") == Color("#477D66") and int(entry.material.get_shader_parameter("head_pattern")) == 1, "paper doll garment receives new hood color and pattern")
	await press("补给")
	await select_item(ITEM)
	var item_card := inventory_button(ITEM)
	check(is_instance_valid(item_card) and item_card.content_icon == database.get_content_icon("items", ITEM), "live bag card uses exact item PNG binding")
	actor.resources.change("HP", -200)
	var before_hp: float = actor.resources.current("HP")
	var expected_hp: float = minf(actor.resources.max_value("HP"), before_hp + 30 + actor.resources.max_value("HP") * .2)
	await press("使用")
	check(actor.inventory.count(ITEM) == 2 and is_equal_approx(actor.resources.current("HP"), expected_hp), "live Use button consumes loaded supply and applies its amount plus fraction")
	await press("放入快捷槽")
	await press("快捷 1")
	check(actor.inventory.quickslots[0] == ITEM, "live bag assigns loaded item to quick slot")
	check(actor.inventory.assign_quick_slot(1, TOKEN), "new action consumable is assignable to another quick slot")
	await capture("01-test-art-inventory")
	app.ui.show_panel("skills")
	await settle()
	var skill_index: int = app.ui.skill_index(SKILL)
	check(skill_index >= 0 and app.ui.skill_at(skill_index).texture == database.get_content_icon("skills", SKILL), "skill view model receives exact skill PNG binding")
	var skill_card: Button = app.ui.skill_buttons.get(skill_index)
	check(is_instance_valid(skill_card) and skill_card.content_icon == database.get_content_icon("skills", SKILL), "live skill card uses exact loaded texture")
	if is_instance_valid(skill_card):
		skill_card.pressed.emit()
		await settle()
	check(app.ui.skill_at(app.ui.selected_skill).get("id", "") == SKILL, "live skill details select the loaded skill")
	await capture("02-test-art-skills")
	app.ui.show_panel("character")
	await settle()
	await press("面板")
	check(app.ui.paper_doll.visible and app.ui.paper_doll.texture == app.paper_doll_view.get_texture(), "character page displays the actual updated paper doll viewport")
	await capture("03-test-art-equipment")
	actor.resources.change("Energy", -actor.resources.max_value("Energy"))
	actor.combat.passives.trigger("perfect_dodge", actor.combat.context())
	check(is_equal_approx(actor.resources.current("Energy"), 20), "new career passive restores continuous Energy on real event")
	check(actor.combat.passives.internal_cooldowns.get(PASSIVE, 0) == 5, "new passive records its configured cooldown")
	actor.combat.passives.trigger("perfect_dodge", actor.combat.context())
	check(is_equal_approx(actor.resources.current("Energy"), 20), "passive cooldown prevents duplicate event reward")
	app.ui.close_panel(true)
	await ticks(3)
	check(app.ui.quick_buttons[BINDINGS.ACTIONS[0]].content_icon == database.get_content_icon("skills", SKILL), "HUD prepared skill uses exact loaded skill texture")
	check(app.ui.quick_buttons[BINDINGS.QUICK_ACTIONS[0]].content_icon == database.get_content_icon("items", ITEM), "HUD quick slot uses exact loaded item texture")
	check(app.ui.quick_buttons[BINDINGS.QUICK_ACTIONS[1]].content_icon == database.get_content_icon("items", TOKEN), "HUD action item has its own distinct texture")
	var before_skill_energy: float = actor.resources.current("Energy")
	app.ui.quick_buttons[BINDINGS.ACTIONS[0]].pressed.emit()
	check(is_equal_approx(actor.resources.current("Energy"), before_skill_energy - 20), "real HUD skill executes the new continuous Energy cost")
	check(actor.combat.cooldowns.get(SKILL, 0) > 5, "loaded active skill starts its own cooldown")
	await ticks(70)
	var before_energy: float = actor.resources.current("Energy")
	check(actor.inventory.use_quick_slot(1), "loaded action consumable enters real action runner: " + actor.inventory.last_error)
	await ticks(24)
	check(actor.inventory.count(TOKEN) == 2 and actor.resources.current("Energy") >= before_energy + 15, "action consumable executes SELF resource effect and consumes one")
	check(actor.combat.cooldowns.get(ACTION, 0) > 80 and actor.inventory.cooldowns.get(TOKEN, 0) > 110, "item and action cooldowns retain distinct new namespaced keys")
	await capture("04-test-art-hud")
	app.ui.show_panel("character")
	await settle()
	check(app.save_adventure(), "real App save accepts new career, inventory, equipment and action cooldowns: " + str(app.ui.save_note))
	var saved: Dictionary = repository.load_slot(0)
	check(saved.ok, "saved preview can be read back")
	if not saved.ok:
		printerr(saved.error)
		await finish()
		return
	check(saved.snapshot.content_set == JSON.parse_string(JSON.stringify(selected.identity)), "saved snapshot retains exact compiled identity after JSON number normalization")
	check(saved.snapshot.combat.cooldowns.get(ACTION, 0) > 0, "new item action cooldown survives snapshot validation")
	var foreign: Dictionary = saved.snapshot.duplicate(true)
	foreign.content_set.bundle_sha256 = "a".repeat(64) if selected.identity.bundle_sha256 != "a".repeat(64) else "b".repeat(64)
	var before := actor_snapshot()
	actor.inventory.changed.connect(func(): restore_notifications += 1)
	var rejected: Dictionary = repository.restore(foreign, actor, app.game)
	check(not rejected.ok and not rejected.error.is_empty(), "same IDs from a different bundle fingerprint cannot restore")
	check(actor_snapshot() == before and restore_notifications == 0, "rejected content identity restore makes no state change or notification")
	paused = false
	app.free()
	app = null
	await ticks(3)
	await start_app(saved.snapshot)
	# Freeze immediately after the real restore to compare cooldown durations.
	app.ui.show_panel("character")
	await settle()
	check(actor.loadout.career_ids == ["warrior", CAREER] and actor.loadout.level == 3, "reconstructed App restores the new career and level")
	check(SKILL in actor.loadout.learned_skills and actor.loadout.sets[0].skills[0] == SKILL, "reconstructed App retains new learned and prepared skill")
	check(actor.loadout.equipment.head == ARMOR and actor.loadout.weapon_at(0).id == WEAPON, "reconstructed App restores new armor and weapon")
	check(actor.inventory.count(ITEM) == 2 and actor.inventory.count(TOKEN) == 2, "reconstructed App retains consumed inventory quantities")
	check(actor.inventory.quickslots[0] == ITEM and actor.inventory.quickslots[1] == TOKEN, "reconstructed App restores loaded quick slots")
	check(actor.combat.cooldowns.get(ACTION, 0) > 0 and actor.combat.cooldowns.get(ACTION, 0) <= saved.snapshot.combat.cooldowns[ACTION], "reconstructed App restores item action cooldown instead of silently dropping it")
	check(actor.inventory.cooldowns.get(TOKEN, 0) > 0, "reconstructed App restores separate inventory cooldown")
	check(app.paper_doll_hero.outfit.equipment.get("head", {}).get("id", "") == ARMOR, "reconstructed paper doll still resolves new equipment visuals")
	check(actor.loadout.database.get_content_icon("items", ITEM) == database.get_content_icon("items", ITEM), "reconstructed world shares verified content textures")
	check(app.save_adventure(), "reconstructed preview is saveable again")
	check(Preferences.settings_path.begins_with(isolated) and repository.directory.begins_with(isolated), "preferences and repository remain isolated in Temp")
	await finish()

func finish() -> void:
	paused = false
	if is_instance_valid(app): app.free()
	await ticks(3)
	print("CONTENT_PREVIEW_INTEGRATION ", checks - failures.size(), "/", checks, " isolated=", isolated)
	for failure in failures: printerr("FAILED: ", failure)
	quit(0 if failures.is_empty() else 1)
