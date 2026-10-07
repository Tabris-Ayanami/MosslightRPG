extends SceneTree
const Repo=preload("res://rpg/save_repository.gd")
const Prefs=preload("res://rpg/game_preferences.gd")
const OUT="res://docs/save-ui/"
var app: Node
var repo: RefCounted
var checks := 0
var failures: Array[String]=[]
var temp_directory := ""
var gpu := false
func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func click(button: Button) -> void:
	for i in range(180):
		if not app.ui.is_animating(): break
		await ticks(1)
	await ticks(2)
	if not is_instance_valid(button):
		check(false,"requested native button is present")
		return
	var point: Vector2=app.ui.get_global_transform()*button.get_global_rect().get_center() if app.ui.modal.is_ancestor_of(button) else button.get_global_rect().get_center()
	var at: Vector2=root.get_final_transform()*point
	print("CLICK ",button.text," point=",at," age=",app.choice.age," stage=",app.stage," panel=",app.ui.panel)
	button.pressed.connect(func(): print("CLICK_PRESSED ",button.text),CONNECT_ONE_SHOT)
	var motion := InputEventMouseMotion.new()
	motion.position=at
	motion.global_position=at
	Input.parse_input_event(motion)
	await ticks(1)
	for down in [true,false]:
		var event := InputEventMouseButton.new()
		event.position=at
		event.global_position=at
		event.button_index=MOUSE_BUTTON_LEFT
		event.pressed=down
		Input.parse_input_event(event)
		await ticks(2)
func button_named(text: String) -> Button:
	for button in app.ui.modal.get_children():
		if button is Button and button.text==text: return button
	return null
func click_named(label: String) -> void:
	await ticks(3)
	for i in range(180):
		if not app.ui.is_animating(): break
		await ticks(1)
	await click(button_named(label))
func shot(label: String) -> void:
	if not gpu: return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	check(image.get_size()==Vector2i(1920,1080),label+" is true 1080p")
	image.save_png(OUT+label+".png")
func choosing() -> void:
	app.stage=app.Stage.CHOOSING
	app.choice.set_save_slots(repo.list_slots())
	app.journey_cursor=1
	app._sample_journey()
	app.choice.present("continue")
	await ticks(110)
func enter() -> void:
	if app.load_requested:
		while ResourceLoader.load_threaded_get_status(app.GAME_PATH)==ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await ticks(1)
		app._enter_world(ResourceLoader.load_threaded_get(app.GAME_PATH))
	else: app._enter_world(load(app.GAME_PATH))
	app._finish_arrival()
	app.ui.modulate.a=1
	app.ui.close_panel(true)
	app.ui.region_clock=0
	await ticks(8)
	app.game.sound.muted=true
	app.game.combat_world.encounters_started=true
	for foe in app.game.combat_world.enemies: foe.set_physics_process(false)
func run() -> void:
	root.size=Vector2i(1920,1080)
	gpu=DisplayServer.get_name()!="headless"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	temp_directory=OS.get_environment("TEMP").path_join("mosslight_save_ui_%d"%Time.get_ticks_usec())
	repo=Repo.new(temp_directory)
	DirAccess.make_dir_recursive_absolute(temp_directory)
	Prefs.settings_path=temp_directory.path_join("preferences.cfg")
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=repo
	root.add_child(app)
	app.set_process(false)
	await ticks(4)
	app._begin_journey("continue")
	await choosing()
	check(app.choice.slot_buttons.size()==20,"continue screen offers twenty real save slots")
	for index in range(20):
		var card: Button=app.choice.slot_buttons[index]
		check(card.position==Vector2(132+(index%4)*258,153+(index/4)*84),"slot %02d follows four columns and five rows"%(index+1))
	await shot("01-twenty-empty-slots")
	await click(app.choice.slot_buttons[6])
	check(app.choice.selected_slot==6,"actual pointer selects slot seven")
	await click(app.choice.buttons[20])
	check(app.choice.kind=="new" and app.choice.preferred_slot==6,"empty-slot confirmation opens naming for that slot")
	if app.choice.name_input==null:
		print("CONFIRM_DEBUG age=",app.choice.age," leaving=",app.choice.leaving," selected=",app.choice.selected_slot)
		quit(1)
		return
	app.choice.name_input.text="林间旅人"
	app.choice.age=2
	app.choice._confirm()
	check(app.stage==app.Stage.DISSOLVING and app.selected_save==6,"name confirmation creates adventure in the selected slot")
	check(repo.slot(6).valid and repo.slot(6).name=="林间旅人","first civilian save exists on disk immediately")
	await enter()
	check(app.game.rpg.loadout.level==0 and app.ui.rpg_state.career=="平民","new save enters as level-zero civilian")
	check(app.game.rpg.loadout.weapon().get("unarmed",false),"new save has innate fist actions")
	var player: Node=app.game.rpg
	check(player.progression.choose_career("warrior"),"normal career choice works after a saved civilian start")
	check(player.inventory.count("magic_candy")==0,"normal starter excludes debug level candy")
	check(player.inventory.add_item("magic_candy",9),"explicit save fixture grants nine debug candies")
	check(player.inventory.use_item("magic_candy"),"saved character uses a real level candy")
	player.health.receive(71)
	player.global_position=app.game.GARDEN_ORIGIN+Vector3(29,2.35,-4)
	player.velocity=Vector3.ZERO
	await ticks(4)
	app.ui.show_panel("settings")
	await ticks(50)
	var save_button := button_named("保存旅途")
	check(is_instance_valid(save_button),"pause book contains manual save control")
	await click_named("保存旅途")
	var disk: Dictionary=repo.load_slot(6)
	check(disk.ok and int(disk.snapshot.loadout.level)==2,"real save button writes level and loadout to disk")
	check(disk.snapshot.inventory.stacks.get("magic_candy",0)==8,"actual consumed inventory is persisted")
	check(disk.metadata.location=="低语森林" and disk.metadata.display_time.length()==16,"save records actual place and real-world date and minute")
	check(app.ui.save_note.begins_with("已保存"),"manual save displays result in the book")
	app.ui._select_settings_tab(2)
	await ticks(65)
	await shot("02-settings-save-and-numbers")
	await click_named("开启")
	check(not Prefs.get_damage_numbers(),"actual settings button switches damage numbers off")
	Prefs.reload_preferences()
	check(not Prefs.get_damage_numbers(),"damage-number preference survives disk reload")
	await click_named("关闭")
	check(Prefs.get_damage_numbers(),"same visible control switches damage numbers back on")
	player.inventory.add_item("healing_potion",2)
	var automatic_count: int=player.inventory.count("healing_potion")
	await click_named("返回标题")
	await ticks(55)
	check(app.stage==app.Stage.TITLE and not is_instance_valid(app.game),"return-to-title saves and releases world")
	check(repo.load_slot(6).snapshot.inventory.stacks.get("healing_potion",0)==automatic_count,"return-to-title automatically writes changes made after manual save")
	app._begin_journey("new")
	app.stage=app.Stage.CHOOSING
	app.choice.present("new")
	app.choice.name_input.text="  林间旅人  "
	app.choice.age=2
	app.choice._confirm()
	check(app.stage==app.Stage.CHOOSING and is_instance_valid(app.choice.error_word),"duplicate adventure name is rejected in the actual naming screen")
	check(repo.list_slots().filter(func(entry): return entry.occupied).size()==1,"rejected name never allocates an extra slot")
	await ticks(100)
	await shot("03-duplicate-name")
	app.choice.hide()
	await choosing()
	check(app.choice.slot_buttons[6].record.name=="林间旅人","continue card displays saved unique name")
	await click(app.choice.slot_buttons[6])
	await click(app.choice.buttons[20])
	check(app.stage==app.Stage.DISSOLVING and not app.pending_snapshot.is_empty(),"continue card loads an actual persisted snapshot")
	await enter()
	check(app.ui.display_name=="林间旅人" and app.game.rpg.loadout.level==2,"continued adventure restores name and profession level")
	check(app.game.rpg.inventory.count("magic_candy")==8,"continued adventure preserves consumed items")
	check(app.game.rpg.global_position.distance_to(Vector3(29,2.35,106))<.8,"continued adventure returns to its saved location")
	check(app.game.rpg.resources.current("HP")<app.game.rpg.resources.max_value("HP"),"continued adventure does not grant free full health")
	await shot("04-continued-adventure")
	app.show_title()
	await ticks(6)
	for name in ["水庭访客","风铃旅人","森林巡游者","晨曦","远行者"]: check(repo.create(name).ok,"additional unique adventure "+name)
	await choosing()
	await shot("05-populated-twenty-slots")
	var right := InputEventKey.new()
	right.keycode=KEY_DOWN
	right.pressed=true
	var before: int=app.choice.selected_slot
	Input.parse_input_event(right)
	await ticks(2)
	check(app.choice.selected_slot==posmod(before+4,20),"keyboard down moves exactly one row in twenty-slot grid")
	app.queue_free()
	await ticks(5)
	Prefs.settings_path=Prefs.DEFAULT_PATH
	Prefs.reload_preferences()
	print("ADVENTURE_SAVE_UI: %d checks; %d failures"%[checks,failures.size()])
	print("Test saves isolated at ",temp_directory)
	quit(0 if failures.is_empty() else 1)
