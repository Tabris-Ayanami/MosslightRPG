extends "res://tests/frontend_rpg.gd"
## Real quest service, native book controls, isolated saves/preferences and GPU captures.
const Prefs=preload("res://rpg/game_preferences.gd")
const Repo=preload("res://rpg/save_repository.gd")
const State=preload("res://rpg/world_state.gd")
const OUT="res://docs/rpg/quest-journal/"
var temp_directory := ""
var old_preferences := ""

func capture(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await ticks(3)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path(OUT+label+".png"))

func label_texts(node: Node) -> PackedStringArray:
	var values: PackedStringArray=[]
	if node is Label: values.append(node.text)
	for child in node.get_children(): values.append_array(label_texts(child))
	return values

func run() -> void:
	root.size=Vector2i(1280,720)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	temp_directory=OS.get_temp_dir().path_join("mosslight-quest-journal-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(temp_directory)
	old_preferences=Prefs.settings_path
	Prefs.settings_path=temp_directory.path_join("preferences.cfg")
	var repo=Repo.new(temp_directory.path_join("saves"))
	check(repo.create("日志旅人",0).ok,"isolated adventure created")
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=repo
	app.selected_save=0
	app.selected_name="日志旅人"
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate.a=1
	await settle()
	actor=app.game.player
	app.game.sound.muted=true
	app.game.combat_world.encounters_started=true
	for foe in app.game.combat_world.enemies: foe.set_physics_process(false)
	app.ui.close_panel(true)
	actor.combat.reset()
	check(actor.progression.choose_career("warrior"),"real career selected: "+actor.progression.last_error)
	app.ui.show_panel("journal")
	await settle()
	check(app.ui.quest_records.is_empty(),"unaccepted and locked quests are absent from live journal")
	check(app.ui.tracked_quest_summary().title=="研习第一个招式","live HUD guides the actual unprepared hero instead of displaying a fixture quest")
	await capture("01-empty")
	check(app.game.quests.accept("village_patrol"),"accept live patrol quest")
	await ticks(5)
	check(app.ui.quest_records.size()==1 and app.ui.quest_at(0).status=="active","accept refreshes open book from quest signal")
	check(app.ui.quest_at(0).objectives[0].current==0,"new quest displays exact event baseline")
	await click(app.ui.quest_buttons.get("village_patrol"))
	check(named("停止追踪")!=null,"first patrol is already tracked when its journal page opens")
	check(app.game.world_state.get_flag("journal.tracked_quest")=="village_patrol","tracking persists as world-state stable ID")
	check(app.ui.tracked_quest_summary().detail.contains("0/1"),"HUD uses real unfinished objective")
	await click_label("停止追踪")
	check(app.ui.tracked_quest_id.is_empty() and app.game.world_state.get_flag("journal.tracked_quest")=="","stop tracking clears durable selection")
	await click_label("追踪此任务")
	await capture("02-active")
	check(repo.save(0,"日志旅人",actor,app.game,"风息原野").ok,"save includes active quest and tracked ID")
	var saved: Dictionary=repo.load_slot(0).snapshot
	var defeated: Node=null
	for foe in app.game.combat_world.enemies:
		if foe.enemy_id=="soldier": defeated=foe; break
	if not is_instance_valid(defeated): defeated=app.game.combat_world.spawn_enemy("soldier",actor.global_position+Vector3(20,0,0))
	check(is_instance_valid(defeated),"real soldier encounter exists")
	if is_instance_valid(defeated): defeated.combat.receive_damage({"formula":{"base":999999},"can_crit":false,"damage_type":"PHYSICAL"},actor,Vector3.FORWARD)
	await ticks(5)
	check(app.ui.quest_at(0).status=="ready" and app.ui.quest_at(0).objectives[0].current==1,"real encounter event refreshes ready progress")
	check(app.ui.tracked_quest_summary().detail.contains("返回委托人"),"ready HUD points to hand-in")
	var text: String="\n".join(label_texts(app.ui.modal))
	check(text.contains("经验  +60") and text.contains("生命药水  ×2"),"rewards use actual XP and item display names")
	check(named("领取奖励")==null and named("接受任务")==null,"book has no claim or accept shortcut")
	await capture("03-ready")
	check(repo.restore(saved,actor,app.game).ok,"restore active snapshot succeeds")
	await ticks(5)
	check(app.ui.quest_at(0).status=="active" and app.ui.quest_at(0).objectives[0].current==0,"restore refreshes open book without stale progress")
	check(app.ui.tracked_quest_id=="village_patrol","restore reloads tracked quest ID")
	app.game.world_state.record_event("enemy_defeated","soldier")
	check(app.game.quests.claim("village_patrol"),"quest service commits NPC-equivalent hand-in")
	await ticks(5)
	check(app.ui.quest_at(0).status=="rewarded" and app.ui.tracked_quest_id.is_empty(),"completed quest remains readable and leaves HUD tracking")
	check("\n".join(label_texts(app.ui.modal)).contains("已获奖励"),"completed detail confirms reward already received")
	await capture("03b-completed")
	check(app.game.quests.accept("forest_investigation"),"follow-up quest unlocked by actual hand-in")
	await ticks(5)
	check(app.ui.tracked_quest_id=="forest_investigation" and app.ui.tracked_quest_summary().detail.contains("重甲守卫"),"claim then accept continues HUD tracking into the second real main quest")
	await click(app.ui.quest_buttons.get("forest_investigation"))
	check(app.ui.selected_quest_id=="forest_investigation","native selection uses real quest identity")
	check(app.ui.quest_at(app.ui.selected_quest).objectives.size()==2,"all actual follow-up objectives are visible")
	await capture("04-follow-up")
	# Stress only the detached test catalog, leaving authored game content untouched.
	var long_catalog: Dictionary={}
	for i in range(9):
		var id := "journal_test_%d"%i
		var objectives: Array=[]
		for j in range(16): objectives.append({"id":"step_%d"%j,"type":"flag","flag":"journal_test.flag_%d"%j,"value":true,"target":1,"label":"沿林间小路调查第 %d 处异常，确认旅人能够安全通过。"%(j+1)})
		long_catalog[id]={"id":id,"title":"巡林人的长篇委托 %d：沿古道寻找遗失的旅途记录"%(i+1),"description":"记下沿途的风声、路标和旅人的消息，再把发现带回村庄。".repeat(20),"objectives":objectives,"rewards":{"experience":60,"items":{"healing_potion":2}}}
	app.game.world_state.import_state(State.new().export_state())
	check(app.game.quests.setup(app.game.world_state,actor,long_catalog),"detached long quest catalog validates")
	for id in long_catalog: app.game.quests.accept(id)
	await ticks(5)
	await click(app.ui.quest_buttons.get("journal_test_0"))
	for extent in [Vector2i(1280,720),Vector2i(960,540)]:
		root.size=extent
		await ticks(5)
		var list: ScrollContainer=app.ui.modal.get_node("QuestList")
		var details: ScrollContainer=app.ui.modal.get_node("QuestDetails")
		check(list.get_v_scroll_bar().max_value>list.size.y,"long quest list scrolls at "+str(extent))
		check(details.get_v_scroll_bar().max_value>details.size.y,"long detail and sixteen objectives scroll at "+str(extent))
		details.scroll_vertical=int(details.get_v_scroll_bar().max_value)
		await ticks(3)
		check(details.scroll_vertical>0,"reward footer is reachable through detail scrolling")
		await capture("05-long-%dx%d"%[extent.x,extent.y])
		var reading_offset: int=details.scroll_vertical
		actor.inventory.changed.emit()
		await ticks(4)
		check(app.ui.modal.get_node("QuestDetails").scroll_vertical==reading_offset and app.ui.selected_quest_id=="journal_test_0","background refresh preserves current reading position")
	app.ui.close_panel(true)
	app.selected_save=-1
	app.queue_free()
	await ticks(12)
	Prefs.settings_path=old_preferences
	print("QUEST_JOURNAL ",checks-failures.size(),"/",checks)
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
