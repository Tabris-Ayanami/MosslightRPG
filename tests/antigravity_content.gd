extends "res://tests/content_preview_integration.gd"
## Live external-AI candidate acceptance. Uses inherited isolated App/UI helpers.
const W_ITEM := "willow_watch:herb_brew"
const W_WEAPON := "willow_watch:willow_blade"
const W_ARMOR := "willow_watch:watch_hood"
const W_SKILL := "willow_watch:willow_strike"
const W_PASSIVE := "willow_watch:willow_step"
const W_CAREER := "willow_watch:willow_sentinel"

func run() -> void:
	create_timer(150, true).timeout.connect(func():
		printerr("ANTIGRAVITY_CONTENT TIMEOUT")
		quit(1))
	root.size = Vector2i(1280, 720)
	var full_art: bool = OS.get_cmdline_user_args().has("--full-art")
	var picture_prefix := "antigravity-willow-020-" if full_art else "antigravity-willow-"
	if OS.get_cmdline_user_args().has("--cache-art"): picture_prefix = "antigravity-willow-020-cache-"
	var bundle_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--bundle="): bundle_path = argument.trim_prefix("--bundle=")
	if bundle_path.is_empty():
		printerr("Supply -- --bundle=ABSOLUTE_WILLOW_WATCH_BUNDLE_DIRECTORY")
		quit(2)
		return
	var selected := Database.configure_content_bundle(bundle_path)
	check(selected.ok, "candidate bundle validates before database construction: " + str(selected.error))
	if not selected.ok:
		quit(1)
		return
	isolated = OS.get_temp_dir().path_join("mosslight-antigravity-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path = isolated.path_join("preferences.cfg")
	repository = Repository.new(isolated.path_join("adventures"))
	database = Database.new()
	check(database.errors.is_empty(), "all merged definitions load cleanly")
	var expected := {"items": W_ITEM, "weapons": W_WEAPON, "equipment": W_ARMOR,
		"skills": W_SKILL, "passives": W_PASSIVE, "careers": W_CAREER}
	for family in expected:
		check(database.get(family).has(expected[family]), "external generated definition loads: " + family)
		if full_art:
			var bound: Texture2D = database.get_content_icon(family, expected[family])
			check(bound != null and bound.get_width() >= 512 and bound.get_height() >= 512, "full art pack binds a real generated image for " + family)
	var texture: Texture2D = database.get_content_icon("items", W_ITEM)
	check(texture != null and texture.get_size() == Vector2(512, 512), "actual generated PNG decodes into a bounded display cache")
	if texture == null:
		await finish()
		return
	var pixels: Image = texture.get_image()
	check(pixels.get_pixel(0, 0).a == 0 and pixels.get_pixel(pixels.get_width() - 1, pixels.get_height() - 1).a == 0, "generated icon has transparent corners in Godot")
	check(pixels.get_pixel(261, 265).a > .95, "glass highlights remain opaque artwork rather than punched holes")
	var created: Dictionary = repository.create("柳径内容试批", 0)
	check(created.ok, "isolated candidate adventure created")
	if not created.ok:
		await finish()
		return
	await start_app(created.snapshot)
	await press("战士")
	check(actor.progression.level_up() and actor.progression.level_up(), "explicit preview fixture reaches level three")
	app.ui._select_career()
	await settle()
	await press("柳野哨卫")
	check(actor.loadout.career_ids == ["warrior", W_CAREER], "generated career is selected via native UI")
	if full_art:
		# Career ink has a separate grow/erase animation from the book turn.
		while app.ui.career_age < 1.4: await ticks(1)
		await capture(picture_prefix + "career")
	check(actor.progression.learn_skill(W_SKILL) and actor.loadout.assign_skill(0, 0, W_SKILL), "generated active skill can be learned and prepared")
	check(W_PASSIVE in actor.loadout.passive_ids, "generated career grants its passive")
	for id in [W_ITEM, W_WEAPON, W_ARMOR]:
		check(actor.inventory.add_item(id, 3 if id == W_ITEM else 1), "explicit candidate preview grant: " + id)
	app.ui.show_panel("bag")
	await settle()
	await press("武器")
	await select_item(W_WEAPON)
	await press("装备至 A")
	check(actor.loadout.weapon_at(0).id == W_WEAPON, "generated sword equips through inventory UI")
	if full_art: await capture(picture_prefix + "weapon")
	await press("护具")
	await select_item(W_ARMOR)
	await press("穿戴")
	check(actor.loadout.equipment.head == W_ARMOR, "generated hood equips through inventory UI")
	check(app.paper_doll_hero.outfit.equipment.head.visual.color == "#537358", "paper doll uses generated hood visual definition")
	if full_art: await capture(picture_prefix + "equipment")
	await press("补给")
	await select_item(W_ITEM)
	var card := inventory_button(W_ITEM)
	check(is_instance_valid(card) and card.content_icon == texture, "real bag card uses generated transparent artwork")
	actor.resources.change("HP", -300)
	var before_hp: float = actor.resources.current("HP")
	var expected_hp: float = minf(actor.resources.max_value("HP"), before_hp + 20 + actor.resources.max_value("HP") * .2)
	await press("使用")
	check(actor.inventory.count(W_ITEM) == 2 and is_equal_approx(actor.resources.current("HP"), expected_hp), "generated drink consumes once and restores exact declared HP")
	await press("放入快捷槽")
	await press("快捷 1")
	check(actor.inventory.quickslots[0] == W_ITEM, "generated supply prepares in real quick slot")
	await capture(picture_prefix + "inventory")
	actor.resources.change("Energy", -actor.resources.max_value("Energy"))
	actor.combat.passives.trigger("perfect_dodge", actor.combat.context())
	check(is_equal_approx(actor.resources.current("Energy"), 10), "generated passive restores ten continuous Energy")
	actor.combat.passives.trigger("perfect_dodge", actor.combat.context())
	check(is_equal_approx(actor.resources.current("Energy"), 10), "generated passive cooldown prevents duplicate reward")
	actor.resources.change("Energy", 20)
	app.ui.close_panel(true)
	await ticks(3)
	var before_energy: float = actor.resources.current("Energy")
	check(actor.combat.request_skill(0), "generated skill enters real combat controller")
	check(is_equal_approx(actor.resources.current("Energy"), before_energy - 20), "generated skill consumes exactly twenty Energy")
	check(actor.combat.cooldowns.get(W_SKILL, 0) > 5, "generated skill starts declared cooldown")
	await ticks(65)
	check(app.ui.quick_buttons[BINDINGS.QUICK_ACTIONS[0]].content_icon == texture, "HUD uses same verified artwork")
	app.ui.show_panel("skills")
	await settle()
	var skill_index: int = app.ui.skill_index(W_SKILL)
	check(skill_index >= 0, "generated skill has a real journal entry")
	if skill_index >= 0:
		app.ui.skill_buttons[skill_index].pressed.emit()
		await settle()
	await capture(picture_prefix + "skills")
	var passive_index: int = app.ui.skill_index(W_PASSIVE)
	check(passive_index >= 0, "passive still has an accessible journal entry")
	if passive_index >= 0:
		var passive_card: Button = app.ui.skill_buttons[passive_index]
		check(passive_card.role == "node" and (not full_art or passive_card.content_icon == database.get_content_icon("passives", W_PASSIVE)), "passive journal entry uses the same icon presentation as active skills")
		var passive_entry: Dictionary = app.ui.skill_at(passive_index)
		check(passive_entry.note.contains("完美闪避") and passive_entry.note.contains("10 点能量") and passive_entry.note.contains("6 秒"), "passive text explains the actual trigger, recovery and interval")
		check(passive_entry.cooldown == "6.0 秒", "triggered passive displays its real cooldown")
		passive_card.pressed.emit()
		await settle()
		if full_art: await capture(picture_prefix + "passive")
	var save_ok: bool = app.save_adventure()
	check(save_ok, "candidate equipment and generated IDs persist via App save: " + str(app.ui.save_note))
	if not save_ok:
		await finish()
		return
	var saved: Dictionary = repository.load_slot(0)
	check(saved.ok, "candidate save passes full repository validation")
	if not saved.ok:
		await finish()
		return
	check(saved.snapshot.content_set == JSON.parse_string(JSON.stringify(selected.identity)), "candidate save pins exact compiled identity")
	paused = false
	app.free()
	app = null
	await ticks(3)
	await start_app(saved.snapshot)
	app.ui.show_panel("bag")
	await settle()
	check(actor.loadout.career_ids == ["warrior", W_CAREER] and actor.loadout.level == 3, "new App restores generated career")
	check(actor.loadout.weapon_at(0).id == W_WEAPON and actor.loadout.equipment.head == W_ARMOR, "new App restores generated equipment")
	check(actor.loadout.sets[0].skills[0] == W_SKILL and W_SKILL in actor.loadout.learned_skills, "new App restores learned prepared skill")
	check(actor.inventory.count(W_ITEM) == 2 and actor.inventory.quickslots[0] == W_ITEM, "new App preserves consumption and quick slot")
	check(actor.loadout.database.get_content_icon("items", W_ITEM) == texture, "new App keeps verified artwork cache")
	check(Preferences.settings_path.begins_with(isolated) and repository.directory.begins_with(isolated), "all settings and saves remain in OS-temp")
	await finish()

func finish() -> void:
	paused = false
	if is_instance_valid(app): app.free()
	await ticks(3)
	print("ANTIGRAVITY_CONTENT ", checks - failures.size(), "/", checks, " isolated=", isolated)
	for failure in failures: printerr("FAILED: ", failure)
	quit(0 if failures.is_empty() else 1)
