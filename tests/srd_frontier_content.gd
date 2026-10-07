extends "res://tests/content_preview_integration.gd"
## Real runtime behavior check for the isolated SRD Frontier candidate pack.
## All settings and save writes are redirected to OS Temp before the App is added.

const PACK_WEAPON := "srd_frontier:reed_sabre"
const PACK_ARMOR := "srd_frontier:riveted_hauberk"
const PACK_BOOTS := "srd_frontier:windwalk_boots"
const PACK_PENDANT := "srd_frontier:oakward_pendant"
const PACK_DRAUGHT := "srd_frontier:field_medic_draught"
const PACK_TONIC := "srd_frontier:blueleaf_tonic"
const PACK_SALTS := "srd_frontier:stamina_salts"
const PACK_ACTIVE := "srd_frontier:briar_sweep"
const PACK_ICE := "srd_frontier:blueglass_burst"
const PACK_STAFF := "srd_frontier:cinder_staff"
const PACK_PASSIVE := "srd_frontier:surefoot_reflex"
const PACK_GUARD := "srd_frontier:high_guard"

func near(actual: float, expected: float, label: String, tolerance := 0.01) -> void:
	check(absf(actual - expected) <= tolerance, "%s (%.4f / %.4f)" % [label, actual, expected])

func capture_candidate(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://.work/luna_content_factory_20260930/ui-captures")
	DirAccess.make_dir_recursive_absolute(directory)
	var error := root.get_texture().get_image().save_png(directory.path_join(label + ".png"))
	check(error == OK, "GPU UI capture is saved in the isolated work directory: " + label)

func run() -> void:
	create_timer(150, true).timeout.connect(func():
		printerr("SRD_FRONTIER_CONTENT TIMEOUT")
		quit(1))
	root.size = Vector2i(1280, 720)
	var bundle_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--bundle="): bundle_path = argument.trim_prefix("--bundle=")
	if bundle_path.is_empty():
		printerr("Supply -- --bundle=ABSOLUTE_COMPILED_CANDIDATE_DIRECTORY")
		quit(2)
		return
	var selected := Database.configure_content_bundle(bundle_path)
	check(selected.ok, "candidate bundle is configured before database construction: " + str(selected.error))
	if not selected.ok:
		quit(1)
		return
	isolated = OS.get_temp_dir().path_join("mosslight-srd-frontier-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path = isolated.path_join("preferences.cfg")
	repository = Repository.new(isolated.path_join("adventures"))
	database = Database.new()
	check(database.errors.is_empty(), "candidate catalog loads without runtime errors")
	for spell in [["srd_frontier:cinder_bolt", 1, 10], ["srd_frontier:blueglass_burst", 2, 20], ["srd_frontier:thunderline", 3, 35]]:
		var definition: Dictionary = database.skills[spell[0]]
		check(int(definition.get("spell_rank", 0)) == spell[1] and is_equal_approx(float(definition.get("costs", {}).get("Energy", 0)), float(spell[2])), "caster skill uses its explicit rank-to-Energy cost: " + spell[0])
	for binding in [["weapons", PACK_WEAPON], ["equipment", PACK_ARMOR], ["items", PACK_DRAUGHT], ["skills", PACK_ICE]]:
		var texture: Texture2D = database.get_content_icon(binding[0], binding[1])
		check(texture != null and texture.get_width() <= 512 and texture.get_height() <= 512, "candidate source artwork resolves into bounded runtime icon cache: " + binding[1])
	for id in [PACK_WEAPON, PACK_ARMOR, PACK_BOOTS, PACK_PENDANT]:
		check(database.weapons.has(id) or database.equipment.has(id), "candidate equipment definition loads: " + id)
	for id in [PACK_DRAUGHT, PACK_TONIC]:
		check(database.items.has(id), "candidate consumable definition loads: " + id)
	var created: Dictionary = repository.create("SRD Frontier隔离预览", 0)
	check(created.ok, "preview save is created only in OS Temp")
	if not created.ok:
		await finish()
		return
	await start_app(created.snapshot)
	check(app.saves == repository and app.saves.directory.begins_with(OS.get_temp_dir()), "App receives the isolated SaveRepository before entering the tree")
	await press("战士")
	check(actor.loadout.career_ids == ["warrior"], "real App enters the base Warrior career")
	for id in [PACK_WEAPON, PACK_ARMOR, PACK_BOOTS, PACK_PENDANT, PACK_DRAUGHT, PACK_TONIC, PACK_SALTS]:
		check(actor.inventory.add_item(id), "preview reward grants candidate definition: " + id)
	app.ui.show_panel("bag")
	await settle()
	var sword_card: Button = inventory_button(PACK_WEAPON)
	var draught_card: Button = inventory_button(PACK_DRAUGHT)
	check(is_instance_valid(sword_card) and sword_card.content_icon == database.get_content_icon("weapons", PACK_WEAPON), "real inventory card binds the candidate sword PNG")
	check(is_instance_valid(draught_card) and draught_card.content_icon == database.get_content_icon("items", PACK_DRAUGHT), "real inventory card binds the candidate draught PNG")
	await select_item(PACK_DRAUGHT)
	await capture_candidate("warrior-inventory")
	check(actor.loadout.equip_weapon(0, PACK_WEAPON), "real loadout equips the candidate sword")
	check(actor.loadout.weapon_at(0).id == PACK_WEAPON, "equipped weapon ID resolves to the candidate sword")
	var starting_armor: float = actor.stats.get_final_stat("Armor")
	check(actor.loadout.equip_item("torso", PACK_ARMOR), "real loadout equips the candidate hauberk")
	near(actor.stats.get_final_stat("Armor") - starting_armor, 6.0, "hauberk adds its declared six Armor")
	check(app.paper_doll_hero.outfit.equipment.torso.id == PACK_ARMOR, "paper doll resolves hauberk into its supported torso visual")
	check(actor.loadout.equip_item("feet", PACK_BOOTS), "real loadout equips boots with a passive")
	check(actor.loadout.equip_item("neck", PACK_PENDANT), "real loadout equips pendant with a conditional passive")
	check(PACK_PASSIVE in actor.loadout.passive_ids and PACK_GUARD in actor.loadout.passive_ids, "equipped items grant both candidate passives")
	var base_poise: float = actor.combat.max_poise()
	near(base_poise - actor.combat.base_poise, 8.0, "high-guard passive adds exactly eight Poise above 75 percent HP")
	actor.resources.change("HP", -actor.resources.max_value("HP") * .26)
	near(actor.combat.max_poise(), base_poise - 8.0, "high-guard bonus disappears at or below 75 percent HP")
	actor.resources.change("Stamina", -2.0)
	var stamina_before: float = actor.resources.current("Stamina")
	actor.combat.passives.trigger("perfect_dodge", actor.combat.context())
	near(actor.resources.current("Stamina") - stamina_before, 1.0, "surefoot passive restores exactly one Stamina after a real perfect-dodge event")
	near(float(actor.combat.passives.internal_cooldowns.get(PACK_PASSIVE, 0.0)), 8.0, "surefoot passive starts its declared eight-second trigger cooldown")
	var stamina_after_first: float = actor.resources.current("Stamina")
	actor.combat.passives.trigger("perfect_dodge", actor.combat.context())
	near(actor.resources.current("Stamina"), stamina_after_first, "repeated perfect-dodge event cannot bypass the passive cooldown")
	actor.resources.change("Stamina", -actor.resources.current("Stamina"))
	check(actor.inventory.use_item(PACK_SALTS), "real inventory consumes the stamina salts")
	near(actor.resources.current("Stamina"), 1.0 + actor.resources.max_value("Stamina") * .15, "stamina salts restore the exact fifteen percent plus one-point amount")
	actor.resources.change("HP", actor.resources.max_value("HP"))
	actor.resources.change("HP", -160)
	var before_hp: float = actor.resources.current("HP")
	var expected_hp := minf(actor.resources.max_value("HP"), before_hp + 8.0 + actor.resources.max_value("HP") * .16)
	check(actor.inventory.use_item(PACK_DRAUGHT), "real inventory consumes the field medic draught")
	near(actor.resources.current("HP"), expected_hp, "draught applies its exact 16 percent plus eight HP")
	check(actor.inventory.cooldowns.get(PACK_DRAUGHT, 0.0) == 8.0, "draught starts its declared eight-second cooldown")
	actor.resources.change("Energy", -actor.resources.max_value("Energy"))
	var expected_energy := minf(actor.resources.max_value("Energy"), 8.0 + actor.resources.max_value("Energy") * .18)
	check(actor.inventory.use_item(PACK_TONIC), "real inventory consumes the blueleaf tonic")
	near(actor.resources.current("Energy"), expected_energy, "tonic applies its exact 18 percent plus eight Energy")
	check(actor.loadout.available_skills.has(PACK_ACTIVE), "candidate active skill is granted to the real Warrior career")
	check(actor.progression.learn_skill(PACK_ACTIVE), "candidate active skill is learnable in progression")
	check(actor.loadout.assign_skill(0, 0, PACK_ACTIVE), "candidate active skill can be prepared in slot A")
	app.ui.close_panel(true)
	await ticks(3)
	var skill_failure: String = actor.combat.action_failure(database.skills[PACK_ACTIVE])
	check(skill_failure.is_empty(), "candidate active skill passes actual combat prerequisites: " + skill_failure)
	var warrior_target: Node = actor.arena.spawn_enemy("soldier", actor.global_position + Vector3(0, 0, -2.0))
	check(is_instance_valid(warrior_target), "real map arena spawns an isolated test soldier")
	if not is_instance_valid(warrior_target):
		await finish()
		return
	warrior_target.ai_enabled = false
	warrior_target.combat.reset()
	actor.facing = Vector3(0, 0, -1)
	actor.arena.aim_override = warrior_target.global_position
	actor.arena.aim_point = warrior_target.global_position
	actor.arena.locked_target = warrior_target
	var warrior_target_hp: float = warrior_target.resources.current("HP")
	var warrior_energy: float = actor.resources.current("Energy")
	check(actor.combat.request_skill(0), "real request_skill queues the candidate Warrior skill")
	await ticks(50)
	check(warrior_target.resources.current("HP") < warrior_target_hp, "candidate Warrior skill damages a real target")
	near(warrior_energy - actor.resources.current("Energy"), 12.0, "candidate Warrior skill spends exactly twelve Energy")
	check(actor.combat.cooldowns.get(PACK_ACTIVE, 0.0) > 4.5, "candidate Warrior skill starts its six-second cooldown")
	await run_ice_burst_check()
	check(Preferences.settings_path.begins_with(isolated) and repository.directory.begins_with(isolated), "preferences and saves remain inside OS Temp")
	await finish()

func run_ice_burst_check() -> void:
	var mage_save: Dictionary = repository.create("SRD Frontier法师实放预览", 1)
	check(mage_save.ok, "isolated repository prepares a second character for mage skill testing")
	if not mage_save.ok: return
	if is_instance_valid(app):
		app.free()
		app = null
		await ticks(3)
	await start_app(mage_save.snapshot)
	await press("法师")
	check(actor.loadout.career_ids == ["mage"], "real App enters the base Mage career")
	check(actor.progression.level_up() and actor.progression.level_up(), "mage reaches Lv3 through real progression")
	check(actor.inventory.add_item(PACK_STAFF), "mage preview receives the candidate staff")
	app.ui.show_panel("bag")
	await settle()
	check(actor.loadout.equip_weapon(0, PACK_STAFF), "mage equips the candidate caster staff")
	check(actor.progression.learn_skill(PACK_ICE), "mage learns the Lv3 ice-burst skill")
	check(actor.loadout.assign_skill(0, 0, PACK_ICE), "mage prepares the ice-burst skill in slot A")
	app.ui.close_panel(true)
	await ticks(3)
	var ice_target: Node = actor.arena.spawn_enemy("soldier", actor.global_position + Vector3(0, 0, -2.0))
	check(is_instance_valid(ice_target), "real map arena spawns an isolated ice-burst target")
	if not is_instance_valid(ice_target): return
	ice_target.ai_enabled = false
	ice_target.combat.reset()
	actor.facing = Vector3(0, 0, -1)
	actor.arena.aim_override = ice_target.global_position
	actor.arena.aim_point = ice_target.global_position
	actor.arena.locked_target = ice_target
	var ice_target_hp: float = ice_target.resources.current("HP")
	var mage_energy: float = actor.resources.current("Energy")
	check(actor.combat.request_skill(0), "real request_skill queues the candidate ice burst")
	await ticks(55)
	check(ice_target.resources.current("HP") < ice_target_hp, "blueglass burst hits and damages a real target")
	check(ice_target.combat.statuses.has_status("slow"), "blueglass burst applies its real slow status")
	near(mage_energy - actor.resources.current("Energy"), 20.0, "blueglass burst spends exactly twenty Energy for its declared second-rank cost")
	check(actor.combat.cooldowns.get(PACK_ICE, 0.0) > 8.0, "blueglass burst starts its nine-second cooldown")
	app.ui.show_panel("skills")
	await settle()
	var ice_index: int = app.ui.skill_index(PACK_ICE)
	check(ice_index >= 0, "candidate ice-burst entry appears in the real skill panel")
	if ice_index >= 0:
		var card: Button = app.ui.skill_buttons[ice_index]
		check(card.content_icon == database.get_content_icon("skills", PACK_ICE), "real skill panel binds the candidate transparent PNG")
		card.pressed.emit()
		await settle()
	await capture_candidate("mage-ice-burst-skill")
