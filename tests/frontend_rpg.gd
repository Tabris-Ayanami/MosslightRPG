extends SceneTree
const Preferences=preload("res://rpg/game_preferences.gd")
## Real InputMap and native book buttons exercise the live main-world RPG facade.
var app: Node
var actor: Node
var checks := 0
var failures: Array[String]=[]
var used_skills: Array[String]=[]

func _initialize() -> void:
	call_deferred("_run_at_display_size")

func _run_at_display_size() -> void:
	# The headless display defaults to 64x64. Native mouse coordinates otherwise
	# round small buttons down to a pixel and can miss despite valid UI layout.
	if DisplayServer.get_name()=="headless": root.size=Vector2i(1280,720)
	await process_frame
	print("UI_TEST_DISPLAY ",root.size," viewport=",root.get_visible_rect().size)
	await run()
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func key(code: Key,down: bool) -> void:
	var event:=InputEventKey.new()
	event.physical_keycode=code
	event.keycode=code
	event.pressed=down
	Input.parse_input_event(event)
func mouse(point: Vector2,down: bool,button_index := MOUSE_BUTTON_LEFT) -> void:
	var event:=InputEventMouseButton.new()
	event.position=root.get_final_transform()*point
	event.global_position=event.position
	event.button_index=button_index
	event.pressed=down
	Input.parse_input_event(event)
func settle() -> void:
	# Native input is buffered: allow the event and deferred page change to start
	# before deciding that there is no animation left to wait for.
	await ticks(2)
	for i in range(120):
		if not app.ui.is_animating(): break
		await ticks(1)
	await ticks(2)
func click(button: Button,button_index := MOUSE_BUTTON_LEFT) -> void:
	check(is_instance_valid(button),"native button exists")
	if not is_instance_valid(button): return
	var point: Vector2=app.ui.get_global_transform()*button.get_global_rect().get_center() if app.ui.modal.is_ancestor_of(button) else button.get_global_rect().get_center()
	print("UI_CLICK_TRACE ",button.text," disabled=",button.disabled," point=",point," stage=",app.stage," panel=",app.ui.panel," visible=",app.ui.book_surface.visible)
	var motion:=InputEventMouseMotion.new()
	motion.position=root.get_final_transform()*point
	motion.global_position=motion.position
	Input.parse_input_event(motion)
	await ticks(1)
	mouse(point,true,button_index)
	await ticks(1)
	mouse(point,false,button_index)
	await ticks(3)
	await settle()
func named(label: String) -> Button:
	for node in app.ui.modal.get_children():
		if node is Button and node.text==label: return node
	return null
func click_label(label: String) -> void:
	await settle()
	await click(named(label))
func select_item(id: String) -> void:
	for index in app.ui.item_buttons:
		if app.ui.item_at(index).get("id","")==id:
			await click(app.ui.item_buttons[index])
			return
	check(false,"owned item is visible: "+id)
func select_skill(id: String) -> void:
	var index: int=app.ui.skill_index(id)
	await click(app.ui.skill_buttons.get(index))
func select_equipment(slot_caption: String) -> void:
	for node in app.ui.modal.get_children():
		if node is Button and node.get("role")=="equip_small" and node.get("caption")==slot_caption:
			await click(node)
			return
	check(false,"equipment card is visible: "+slot_caption)
func select_loadout(slot: int) -> void:
	var found := 0
	for node in app.ui.modal.get_children():
		if node is Button and node.get("role")=="loadout":
			if found==slot:
				await click(node)
				return
			found+=1
	check(false,"loadout card is visible")
func close_book() -> void:
	for node in app.ui.modal.get_children():
		if node is Button and node.get("role")=="close":
			await click(node)
			return
func capture(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/rpg/ui-live/"+label+".png"))

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/rpg/ui-live/"))
	var isolated := OS.get_temp_dir().path_join("mosslight-frontend-rpg-%d-%d"%[OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(isolated)
	Preferences.settings_path=isolated.path_join("preferences.cfg")
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=app.SAVE_REPOSITORY.new(isolated.path_join("adventures"))
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app.selected_name="试炼旅人"
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.modulate.a=1
	await settle()
	if not is_instance_valid(app.game.get("rpg")):
		check(false,"main game has an RPG facade")
		quit(1)
		return
	actor=app.game.rpg
	for enemy in actor.arena.enemies: enemy.ai_enabled=false
	actor.combat.skill_used.connect(func(id: String): used_skills.append(id))
	check(actor==app.game.player and app.ui.rpg==actor,"main presenter binds the actual playable actor")
	check(actor.loadout.level==0 and app.ui.panel=="character" and app.ui.career_picker and paused,"arrival opens the initial career page and pauses the world")
	check(app.ui.rpg_state.name=="试炼旅人","HUD character name uses the chosen adventure name")
	await capture("01-career")
	await click_label("战士")
	check(actor.loadout.level==1 and actor.loadout.career_ids==["warrior"],"real career card selects the initial warrior")
	if actor.loadout.level==0:
		printerr("CAREER_CLICK_FAILED state=",actor.combat.state," actor_error=",actor.progression.last_error," ui_note=",app.ui.rpg_note," surface_hover=",root.gui_get_hovered_control())
		app.queue_free()
		await ticks(2)
		quit(1)
		return
	check(actor.inventory.count("magic_candy")==0 and actor.inventory.count("healing_potion")==5,"initial career grants normal supplies without debug candy")
	check(actor.inventory.add_item("magic_candy",9),"explicit UI level-item fixture grants nine debug candies")
	check(actor.loadout.sets[0].skills==["","",""] and actor.loadout.learned_skills.is_empty(),"initial skill preparation starts empty until manual learning")
	check(app.ui.rpg_state.resources.HP.max==actor.resources.max_value("HP") and app.ui.rpg_state.level==1,"character page shows actual resource maxima and level")
	await ticks(3) # Let the inventory fixture's separate structural refresh settle.
	var retained_quick_button: Button = app.ui.quick_buttons[&"quick_item_1"]
	actor.resources.change("HP",-200)
	await ticks(3)
	check(app.ui.rpg_state.resources.HP.current==actor.resources.current("HP"),"resource changes reach the live HUD while the book is open")
	check(is_instance_valid(retained_quick_button) and app.ui.quick_buttons[&"quick_item_1"]==retained_quick_button,"resource changes preserve shortcut identity and held input")
	await click_label("背包")
	await click_label("补给")
	await select_item("healing_potion")
	await click_label("使用")
	check(actor.inventory.count("healing_potion")==4 and actor.resources.current("HP")==actor.resources.max_value("HP"),"native Use button consumes one potion and restores real HP")
	check(named("使用").disabled and not named("使用").tooltip_text.is_empty(),"unavailable potion explains its cooldown or full-resource condition")
	await click_label("放入快捷槽")
	await click_label("快捷 4")
	check(actor.inventory.quickslots[3]=="healing_potion","inventory native buttons configure the fourth real quick slot")
	await select_item("magic_candy")
	await click_label("使用")
	check(actor.loadout.level==2 and actor.inventory.count("magic_candy")==8,"magic candy advances one real level and consumes one item")
	await capture("02-inventory")
	await click_label("角色")
	for node in app.ui.modal.get_children():
		if node is Button and node.get("role")=="hotspot": await click(node); break
	await click_label("剑士")
	check(actor.loadout.career_ids==["warrior","swordsman"],"native career control performs the unlocked level-two advancement")
	actor.inventory.add_item("azure_katana",1)
	actor.inventory.add_item("iron_helm",1)
	await ticks(3)
	await click_label("背包")
	await click_label("武器")
	await select_item("azure_katana")
	await click_label("装备至 A")
	check(actor.loadout.weapon_at(0).id=="azure_katana" and actor.loadout.weapon_at(1).id=="hunter_dagger","inventory equips the owned weapon into A while retaining B")
	check(actor.inventory.count("azure_katana")==1,"equipping preserves inventory ownership count")
	await click_label("护具")
	await select_item("iron_helm")
	await click_label("穿戴")
	check(actor.loadout.equipment.head=="iron_helm" and actor.stats.get_final_stat("Armor")>=8,"native armor action changes both worn equipment and derived defense")
	var armor_before: float=actor.stats.get_final_stat("Armor")
	await click_label("角色")
	await click_label("面板")
	await select_equipment("武器 B")
	await click_label("卸下")
	# weapon_at() now returns the virtual unarmed combat profile for an empty
	# slot; ownership is represented by the stored weapon identifier.
	check(str(actor.loadout.sets[1].weapon).is_empty() and actor.inventory.count("hunter_dagger")==1,"native unequip returns the single B weapon to inventory without changing ownership")
	await click_label("背包")
	await click_label("武器")
	await select_item("hunter_dagger")
	await click_label("装备至 A")
	check(actor.loadout.weapon_at(0).id=="hunter_dagger" and str(actor.loadout.sets[1].weapon).is_empty(),"one owned weapon can move from B to A through real UI actions")
	await select_item("azure_katana")
	await click_label("装备至 A")
	await select_item("hunter_dagger")
	await click_label("装备至 B")
	await click_label("角色")
	await select_equipment("头部")
	await click_label("卸下")
	check(actor.loadout.equipment.get("head","").is_empty() and actor.stats.get_final_stat("Armor")<armor_before,"native armor unequip removes its derived defense")
	await select_equipment("头部")
	await click_label(actor.inventory.definition("iron_helm").name)
	check(actor.loadout.equipment.head=="iron_helm" and actor.stats.get_final_stat("Armor")==armor_before,"owned armor picker restores the exact previous defense")
	await click_label("技能")
	await select_skill("warrior_whirlwind")
	await click_label("研习此招式")
	check("warrior_whirlwind" in actor.loadout.learned_skills,"native skill study button updates actual learned skills")
	await click_label("备战")
	await ticks(40)
	await click(app.ui.ink_buttons.get(0))
	check(actor.loadout.sets[0].skills[0]=="warrior_whirlwind","ink Q selection assigns the learned skill to actual A Q")
	check(named("A 组")==null and named("B 组")==null,"skill tree is independent of preparation groups")
	await select_skill("warrior_thrust")
	await click_label("研习此招式")
	await click_label("备战")
	await ticks(40)
	await click(app.ui.ink_buttons.get(4))
	check(actor.loadout.sets[1].skills[1]=="warrior_thrust" and actor.loadout.sets[0].skills[0]=="warrior_whirlwind","B E preparation is independent of A Q")
	await ticks(40)
	await capture("03-skills")
	await click_label("角色")
	await click_label("职业")
	await select_loadout(0)
	await click_label("清空此槽")
	check(actor.loadout.sets[0].skills[0].is_empty() and "warrior_whirlwind" in actor.loadout.learned_skills,"native clear slot removes A Q while retaining learned skill ownership")
	await select_loadout(0)
	await click_label(actor.loadout.database.skills.warrior_whirlwind.name)
	check(actor.loadout.sets[0].skills[0]=="warrior_whirlwind","native preparation picker can restore a cleared learned skill")
	await close_book()
	check(not paused and app.ui.panel=="" and not app.game.paused,"closing the real RPG book safely resumes the world")
	key(KEY_Q,true)
	await ticks(1)
	key(KEY_Q,false)
	await ticks(40)
	check(used_skills==["warrior_whirlwind"],"actual Q input casts the skill learned and assigned through the book")
	key(KEY_SHIFT,true)
	await ticks(1)
	key(KEY_SHIFT,false)
	await ticks(25)
	key(KEY_E,true)
	await ticks(1)
	key(KEY_E,false)
	await ticks(40)
	check(actor.loadout.current_set==1 and used_skills==["warrior_whirlwind","warrior_thrust"],"actual Shift then E uses the separately prepared B skill")
	await ticks(250)
	actor.resources.change("HP",-150)
	var potions: int=actor.inventory.count("healing_potion")
	key(KEY_4,true)
	await ticks(1)
	key(KEY_4,false)
	await ticks(3)
	check(actor.inventory.count("healing_potion")==potions-1 and actor.resources.current("HP")==actor.resources.max_value("HP"),"actual key 4 uses the item configured through the book")
	check(app.ui.quick_buttons.size()==7,"live HUD displays three skills and four item slots")
	check(app.ui.quick_buttons.has(&"quick_item_1") and app.ui.quick_buttons.has(&"quick_item_4"),"all four quick items remain visible without paging")
	await click(app.ui.quick_buttons[&"quick_item_4"],MOUSE_BUTTON_RIGHT)
	check(actor.inventory.quickslots[3].is_empty() and actor.inventory.count("healing_potion")==potions-1,"right-click clears quick slot four without consuming its item")
	await capture("04-hud")
	key(KEY_B,true)
	await ticks(1)
	key(KEY_B,false)
	await settle()
	check(app.ui.panel=="bag" and paused,"actual B reopens the bound inventory and pauses combat")
	await click_label("补给")
	await select_item("healing_potion")
	await click_label("放入快捷槽")
	await click_label("快捷 4")
	check(actor.inventory.quickslots[3]=="healing_potion","cleared quick slot can be reassigned through the inventory")
	await select_item("magic_candy")
	for i in range(3): await click_label("使用")
	check(actor.loadout.level==5 and actor.inventory.count("magic_candy")==5,"three further native candy uses reach the first-map level cap")
	actor.inventory.add_item("magic_candy",1)
	await ticks(3)
	await select_item("magic_candy")
	check(named("使用").disabled and named("使用").tooltip_text.contains("Lv5"),"level-cap candy rejection is visible without consuming stock")
	await click_label("角色")
	for node in app.ui.modal.get_children():
		if node is Button and node.get("role")=="hotspot": await click(node); break
	var career_before: Array=actor.loadout.career_ids.duplicate()
	check(not named("二刀流").disabled and named("二刀流").tooltip_text.contains("10"),"first-map career page exposes the level-ten requirement for inspection")
	await click_label("二刀流")
	check(actor.loadout.career_ids==career_before and not actor.loadout.is_dual_wielding() and actor.loadout.level==5 and app.ui.rpg_feedback_failed,"activating the inspected advancement rejects it without changing the capped character")
	await capture("05-advanced-character")
	print("FRONTEND_RPG: %d checks; %d failures"%[checks,failures.size()])
	for failure in failures: printerr("FAIL: ",failure)
	app.queue_free()
	await ticks(3)
	quit(0 if failures.is_empty() else 1)
