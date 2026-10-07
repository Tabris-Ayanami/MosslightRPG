extends "res://tests/frontend_rpg.gd"
## Native book controls plus live App/map/quest persistence. No combat-input
## semantics are changed or exercised here; all player data is OS-temp isolated.
const Repo=preload("res://rpg/save_repository.gd")
const Bridge=preload("res://rpg/dialogue_bridge.gd")
const Compiler=preload("res://addons/dialogue_manager/compiler/compiler.gd")
var isolated := ""
var evidence := ""
var saw_skill_turn := false

func _initialize() -> void:
	isolated=OS.get_temp_dir().path_join("mosslight-onboarding-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path=isolated.path_join("preferences.cfg")
	evidence=ProjectSettings.globalize_path("res://.work/onboarding-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(evidence)
	call_deferred("_run_at_display_size")

func ticks(count: int) -> void:
	for _i in range(count):
		await physics_frame
		await process_frame
		if is_instance_valid(app) and is_instance_valid(app.ui) and app.ui.panel=="skills" and app.ui.transition=="turning": saw_skill_turn=true

func capture(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(evidence.path_join(label+".png"))==OK,"GPU capture "+label)

func run() -> void:
	var repo=Repo.new(isolated.path_join("adventures"))
	var created: Dictionary=repo.create("初来旅人",0)
	check(created.ok,"isolated new adventure created")
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=repo
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app.selected_name="初来旅人"
	app.selected_save=0
	app.pending_snapshot=created.snapshot
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate.a=1
	await settle()
	actor=app.game.player
	app.game.sound.muted=true
	app.game.combat_world.encounters_started=true
	for enemy in actor.arena.enemies: enemy.set_physics_process(false)
	check(actor.loadout.level==0 and app.ui.panel=="character" and app.ui.character_tab==1,"arrival opens the real civilian career page")
	await click_label("战士")
	check(actor.loadout.career_ids==["warrior"] and app.ui.panel=="skills","first career continues to the live skill page")
	check(saw_skill_turn and app.ui.transition.is_empty(),"first career uses and completes the existing page-turn animation")
	check(actor.loadout.learned_skills.is_empty() and actor.loadout.sets[0].skills==["","",""] and actor.loadout.sets[1].skills==["","",""],"guidance never learns or assigns skills automatically")
	check(app.ui.tracked_quest_summary().title=="研习第一个招式","unlearned hero has a persistent study reminder")
	await capture("01-first-study")
	await click_label("角色")
	await select_loadout(0)
	check(app.ui.modal.get_node_or_null("LearnFirstPreparedSkill")!=null,"empty preparation chooser offers a study exit")
	await capture("02-empty-preparation")
	await click(app.ui.modal.get_node("LearnFirstPreparedSkill"))
	check(app.ui.panel=="skills" and app.ui.loadout_slot==-1,"empty preparation exit turns to the skill page and clears picker state")
	await click_label("研习此招式")
	check(actor.loadout.learned_skills.size()==1 and actor.loadout.sets[0].skills==["","",""],"study teaches only the selected skill without preparing it")
	check(app.ui.tracked_quest_summary().title=="备战第一个招式","learned but unprepared hero gets the next step")
	await click_label("备战")
	await ticks(45)
	await click(app.ui.ink_buttons.get(0))
	check(not str(actor.loadout.sets[0].skills[0]).is_empty() and actor.loadout.sets[1].skills==["","",""],"native preparation assigns only the chosen A slot")
	await close_book()
	check(app.ui.tracked_quest_summary().title=="寻找守望人艾琳" and app.ui.tracked_quest_summary().detail.contains("北桥"),"prepared hero receives the north-bridge destination on the HUD")
	await capture("03-find-warden")
	var bridge=Bridge.new()
	bridge.setup(app.game)
	var observed: Array[Dictionary]=[]
	app.game.world_state.object_changed.connect(func(id: String):
		if id=="quest.village_patrol": observed.append(app.game.world_state.export_state()))
	check(bridge.accept_quest("village_patrol"),"NPC dialogue bridge accepts the actual first quest")
	await ticks(4)
	check(app.ui.tracked_quest_id=="village_patrol" and app.ui.tracked_quest_summary().detail.contains("0/1"),"first accepted objective is immediately visible on HUD")
	check(observed.size()==1 and observed[0].flags.get("journal.tracked_quest")=="village_patrol","acceptance observers see the tracking flag committed with the quest")
	check(app.game.quests.definition("village_patrol").description.contains("南桥") and app.game.quests.definition("village_patrol").description.contains("向东过桥"),"journal retains the complete outward route")
	await click_label_if_closed_journal()
	check(named("停止追踪")!=null,"journal reflects the automatic tracking selection")
	await capture("04-patrol-route")
	await click_label("停止追踪")
	check(app.ui.tracked_quest_id.is_empty(),"player may still stop tracking explicitly")
	await click_label("追踪此任务")
	check(repo.save(0,"初来旅人",actor,app.game).ok,"prepared skill and tracked patrol save together")
	var saved: Dictionary=repo.load_slot(0).snapshot
	check(saved.world_state.flags.get("journal.tracked_quest")=="village_patrol" and saved.loadout.learned_skills.size()==1,"isolated disk snapshot contains actual onboarding choices")
	check(repo.restore(saved,actor,app.game).ok,"prepared onboarding snapshot restores through the real repository")
	await ticks(4)
	check(app.ui.tracked_quest_id=="village_patrol" and not str(actor.loadout.sets[0].skills[0]).is_empty(),"restore preserves prepared slot and visible objective")
	var source:=FileAccess.get_file_as_string("res://data/dialogue/village_warden.dialogue")
	var compiled: Variant=Compiler.compile_string(source,"res://data/dialogue/village_warden.dialogue")
	check(compiled.errors.is_empty(),"revised first-patrol dialogue compiles")
	check(Preferences.settings_path.begins_with(isolated) and app.saves.directory.begins_with(isolated),"Prefs and saves were injected before App entered the tree")
	app.ui.close_panel(true)
	app.selected_save=-1
	app.queue_free()
	await ticks(4)
	var summary:="ONBOARDING_FLOW checks=%d failures=%d evidence=%s"%[checks,failures.size(),evidence]
	print(summary)
	for failure in failures: printerr("FAIL: ",failure)
	var log:=FileAccess.open(evidence.path_join("result.log"),FileAccess.WRITE)
	log.store_string(summary+"\n"+"\n".join(failures))
	quit(0 if failures.is_empty() else 1)

func click_label_if_closed_journal() -> void:
	app.ui.show_panel("journal")
	await settle()
