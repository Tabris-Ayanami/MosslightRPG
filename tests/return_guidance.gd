extends "res://tests/frontend_rpg.gd"
## Real death/respawn, quick-item input, and native journal controls. All player IO
## is redirected before App enters the tree; captures are explicit test evidence.
const Repo=preload("res://rpg/save_repository.gd")
const State=preload("res://rpg/world_state.gd")
const Guidance=preload("res://rpg/return_guidance.gd")
var isolated := ""
var evidence := ""

func _initialize() -> void:
	isolated=OS.get_temp_dir().path_join("mosslight-return-guidance-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path=isolated.path_join("preferences.cfg")
	evidence=ProjectSettings.globalize_path("res://.work/return-guidance-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(evidence)
	call_deferred("_run_at_display_size")

func capture(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(evidence.path_join(label+".png"))==OK,"Forward+ capture "+label)

func label_texts(node: Node) -> String:
	var text: String=node.text if node is Label else ""
	for child in node.get_children(): text+="\n"+label_texts(child)
	return text

func run() -> void:
	var repo=Repo.new(isolated.path_join("adventures"))
	var created: Dictionary=repo.create("归途旅人",0)
	check(created.ok,"isolated adventure created")
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=repo
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app.selected_name="归途旅人"
	app.selected_save=0
	app.pending_snapshot=created.snapshot
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate.a=1
	await settle()
	actor=app.game.player
	app.game.sound.muted=true
	app.game.combat_world.encounters_started=true
	for foe in actor.arena.enemies: foe.set_physics_process(false)
	app.ui.show_panel("journal")
	await settle()
	check(app.ui.quest_records.is_empty(),"actual new adventure has no accepted tasks")
	await click_label("旅途备忘")
	check(app.ui.journey_memo_open and app.ui.modal.get_node_or_null("JourneyMemo")!=null,"memo is available before accepting any task")
	await capture("00-new-adventure-memo-1280x720")
	await close_book()
	check(actor.progression.choose_career("warrior"),"real warrior selected")
	for index in range(4): actor.inventory.assign_quick_slot(index,"")
	check(actor.inventory.assign_quick_slot(3,"healing_potion"),"real healing supply assigned to fourth slot")
	var binding:=InputEventKey.new()
	binding.physical_keycode=KEY_U
	InputMap.action_erase_events(&"quick_item_4")
	InputMap.action_add_event(&"quick_item_4",binding)
	var advice: Dictionary=Guidance.describe(actor)
	check(advice.sections[1].body.contains("按 U") and advice.sections[1].body.contains("快捷槽 4"),"guidance reads actual fourth-slot binding at full health")
	check(actor.inventory.can_use("healing_potion")=="资源已满" and advice.respawn_notice.contains("受伤按 U"),"full health does not hide carried healing supplies")
	check(app.game.quests.accept("village_patrol"),"real tracked patrol accepted")
	var before_inventory: Dictionary=actor.inventory.export_state()
	var before_world: Dictionary=app.game.world_state.export_state()
	var before_level: int=actor.loadout.level
	var before_xp: int=actor.progression.experience
	actor.combat.receive_damage({"formula":{"base":999999},"can_crit":false,"damage_type":"PHYSICAL"},null,Vector3.FORWARD)
	check(actor.combat.state=="DEAD" and app.game.toast_text.contains("等级与物品保留"),"actual lethal damage announces retained progress")
	check(app.ui.panel.is_empty(),"death does not force a book popup")
	await ticks(180)
	check(actor.combat.state!="DEAD" and actor.resources.current("HP")==actor.resources.max_value("HP"),"normal death timer returns a fully healed player")
	check(actor.global_position.distance_to(app.game.checkpoint)<.75,"respawn returns to the recorded point")
	check(actor.inventory.export_state()==before_inventory and actor.loadout.level==before_level and actor.progression.experience==before_xp,"death retains real items level and experience")
	check(app.game.world_state.export_state()==before_world,"death guidance leaves all world facts and tracking unchanged")
	check(app.game.toast_text.contains("受伤按 U") and app.game.toast_text.contains("日志备忘") and app.game.toast_text.length()<=42,"short respawn notice fits the feed and points to persistent memo")
	await capture("01-return-hud")
	actor.resources.change("HP",-actor.resources.max_value("HP")*.5)
	var count_before: int=actor.inventory.count("healing_potion")
	var hp_before: float=actor.resources.current("HP")
	key(KEY_U,true)
	await ticks(1)
	key(KEY_U,false)
	await ticks(3)
	check(actor.inventory.count("healing_potion")==count_before-1 and actor.resources.current("HP")>hp_before,"the advertised rebound key consumes the actual potion and heals")
	# Expire all transient hints: the memo must still be discoverable and readable.
	app.game.world_ui.feed.tick(20,Vector2(-999,-999))
	app.ui.show_panel("journal")
	await settle()
	await click_label("旅途备忘")
	check(app.ui.journey_memo_open and app.ui.transition.is_empty(),"native memo control completes the existing page animation")
	var memo: ScrollContainer=app.ui.modal.get_node("JourneyMemo")
	var text:=label_texts(memo)
	check(text.contains("等级、经验、物品和任务进度") and text.contains("按 U") and text.contains("剩余 %d"%actor.inventory.count("healing_potion")),"memo remains readable after feed expiry with current inventory")
	check(text.contains("免费恢复状态") and text.contains("不会补发药水") and text.contains("商人售罄"),"memo gives accurate free-rest fallback without inventing potion rewards")
	check(named("停止追踪")==null and app.game.world_state.export_state()==before_world,"memo offers no task mutation and leaves tracking intact")
	await capture("02-memo-supply-1280x720")
	await click_label("返回任务")
	check(not app.ui.journey_memo_open and app.ui.selected_quest_id=="village_patrol" and named("停止追踪")!=null,"return restores the existing tracked task")
	actor.inventory.assign_quick_slot(3,"")
	check(Guidance.describe(actor).sections[1].body.contains("放入快捷槽"),"carried but unassigned healing supply explains configuration")
	actor.inventory.assign_quick_slot(3,"healing_potion")
	actor.inventory.remove_item("healing_potion",actor.inventory.count("healing_potion"))
	check(actor.inventory.quickslots[3]=="healing_potion" and Guidance.describe(actor).sections[1].body.contains("当前没有生命补给"),"stale empty quick slot cannot advertise nonexistent supplies")
	check(Guidance.describe(actor).sections[1].body.contains("库存有限") and Guidance.describe(actor).sections[1].body.contains("铜币"),"no-potion advice accurately describes merchant limits")
	check(repo.save(0,"归途旅人",actor,app.game).ok,"normal adventure remains saveable after death and memo use")
	var saved: Dictionary=repo.load_slot(0).snapshot
	check(saved.world_state.flags.get("journal.tracked_quest")=="village_patrol","normal save keeps the player's task tracking")
	check(repo.restore(saved,actor,app.game).ok,"saved return state restores through the real repository")
	await ticks(4)
	await click_label("旅途备忘")
	check(label_texts(app.ui.modal.get_node("JourneyMemo")).contains("当前没有生命补给"),"memo regenerates correct advice after a normal restore")
	# A detached catalog provides genuine long-scroll state without changing data.
	var catalog: Dictionary={}
	for index in range(7):
		var id := "memo_test_%d"%index
		catalog[id]={"id":id,"title":"归途阅读位置 %d"%index,"description":"一份需要保留阅读位置的长篇记录。".repeat(40),"objectives":[{"id":"look","type":"flag","flag":"memo_fixture.look","value":true,"target":1,"label":"确认沿途记录"}],"rewards":{}}
	app.game.world_state.import_state(State.new().export_state())
	check(app.game.quests.setup(app.game.world_state,actor,catalog),"detached long-journal fixture validates")
	for id in catalog: app.game.quests.accept(id)
	await ticks(4)
	await click_label("返回任务")
	await click(app.ui.quest_buttons.get("memo_test_0"))
	var details: ScrollContainer=app.ui.modal.get_node("QuestDetails")
	var list: ScrollContainer=app.ui.modal.get_node("QuestList")
	details.scroll_vertical=100
	list.scroll_vertical=85
	await ticks(3)
	var reading_offset: int=details.scroll_vertical
	var list_offset: int=list.scroll_vertical
	var selected_id: String=app.ui.selected_quest_id
	var journal_world: Dictionary=app.game.world_state.export_state()
	check(reading_offset>0 and list_offset>0,"fixture has two real nonzero reading positions")
	for extent in [Vector2i(1280,720),Vector2i(960,540)]:
		root.size=extent
		await ticks(4)
		await click_label("旅途备忘")
		memo=app.ui.modal.get_node("JourneyMemo")
		check(memo.get_v_scroll_bar().max_value>memo.size.y,"memo scroll reaches all supply guidance at "+str(extent))
		memo.scroll_vertical=0
		await ticks(3)
		await capture("03-memo-no-potions-%dx%d"%[extent.x,extent.y])
		memo.scroll_vertical=int(memo.get_v_scroll_bar().max_value)
		await ticks(3)
		var memo_offset: int=memo.scroll_vertical
		actor.inventory.changed.emit()
		await ticks(4)
		check(app.ui.modal.get_node("JourneyMemo").scroll_vertical==memo_offset,"live inventory refresh preserves the independent memo reading position at "+str(extent))
		await capture("04-memo-rest-%dx%d"%[extent.x,extent.y])
		await click_label("返回任务")
		check(app.ui.selected_quest_id==selected_id and app.ui.modal.get_node("QuestDetails").scroll_vertical==reading_offset and app.ui.modal.get_node("QuestList").scroll_vertical==list_offset,"memo exit restores task selection and both reading positions at "+str(extent))
		check(app.game.world_state.export_state()==journal_world,"memo browsing never changes tracking or records at "+str(extent))
	check(Preferences.settings_path.begins_with(isolated) and app.saves.directory.begins_with(isolated),"preferences and repository were isolated before App entered the tree")
	app.ui.close_panel(true)
	app.selected_save=-1
	app.queue_free()
	await ticks(5)
	var summary := "RETURN_GUIDANCE checks=%d failures=%d evidence=%s"%[checks,failures.size(),evidence]
	print(summary)
	for failure in failures: printerr("FAIL: ",failure)
	var log:=FileAccess.open(evidence.path_join("result.log"),FileAccess.WRITE)
	log.store_string(summary+"\n"+"\n".join(failures))
	quit(0 if failures.is_empty() else 1)
