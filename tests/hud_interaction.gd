extends SceneTree
## Native HUD pointer and InputMap tests at the production 1.5x UI scale.
const Preferences=preload("res://rpg/game_preferences.gd")
var app: Node
var actor: Node
var checks := 0
var failures: Array[String]=[]
var skill_events := 0

func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func key(code: Key,down: bool) -> void:
	var e:=InputEventKey.new()
	e.physical_keycode=code
	e.keycode=code
	e.pressed=down
	Input.parse_input_event(e)
func mouse(at: Vector2,down: bool,index := MOUSE_BUTTON_LEFT) -> void:
	var e:=InputEventMouseButton.new()
	e.position=root.get_final_transform()*at
	e.global_position=e.position
	e.button_index=index
	e.pressed=down
	Input.parse_input_event(e)
func click_slot(action: StringName,index := MOUSE_BUTTON_LEFT) -> void:
	var at: Vector2=app.ui.quick_buttons[action].get_global_rect().get_center()
	await click_at(at,index)
func click_at(at: Vector2,index := MOUSE_BUTTON_LEFT) -> void:
	var motion:=InputEventMouseMotion.new()
	motion.position=root.get_final_transform()*at
	motion.global_position=motion.position
	Input.parse_input_event(motion)
	await ticks(1)
	mouse(at,true,index)
	await ticks(1)
	mouse(at,false,index)
	await ticks(3)

func run() -> void:
	Preferences.settings_path=OS.get_temp_dir().path_join("mosslight-hud-input-%d-%d.cfg"%[OS.get_process_id(),Time.get_ticks_usec()])
	root.size=Vector2i(1920,1080)
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=app.SAVE_REPOSITORY.new(Preferences.settings_path+"-adventures")
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	actor=app.game.rpg
	check(actor.progression.choose_career("warrior"),"fixture chooses a real warrior")
	check(actor.inventory.count("magic_candy")==0 and actor.inventory.add_item("magic_candy") and actor.inventory.assign_quick_slot(3,"magic_candy"),"HUD item-clear fixture explicitly owns and assigns one debug candy")
	actor.progression.learn_skill("warrior_whirlwind")
	actor.loadout.assign_skill(0,0,"warrior_whirlwind")
	app._finish_arrival()
	app.ui.modulate.a=1
	app.ui.region_clock=0
	app.game.combat_world.encounters_started=true
	for foe in app.game.combat_world.enemies: foe.set_physics_process(false)
	actor.combat.skill_used.connect(func(_id: String): skill_events+=1)
	await ticks(10)
	check(app.ui.scale.is_equal_approx(Vector2(1.5,1.5)),"1920x1080 retains 1280x720 logical HUD at 1.5 scale")
	check(app.ui.quick_buttons.size()==7,"exactly seven QER and item slots exist")
	var actions: Array=app.ui.BINDINGS.ACTIONS+app.ui.BINDINGS.QUICK_ACTIONS
	for i in range(7):
		var b: Button=app.ui.quick_buttons[actions[i]]
		check(b.size==Vector2(48,50) and b.position.y==663,"compact slot size and bottom alignment "+str(i))
		check(app.ui.blocks_world_pointer(b.get_global_rect().get_center()),"visible scaled slot blocks world pointer "+str(i))
		check(b.caption==["Q","E","R","1","2","3","4"][i],"slot caption follows default binding "+str(i))
	for logical in [Vector2(380,680),Vector2(640,622),Vector2(800,615),Vector2(350,145),Vector2(225,125)]:
		check(not app.ui.blocks_world_pointer(app.ui.get_global_transform()*logical),"removed HUD blank area permits world pointer "+str(logical))
	check(app.ui.hud_resource_id=="Energy" and actor.resources.max_value("Energy")>0,"warrior HUD shows the shared continuous energy pool")
	actor.resources.change("Energy",-12.5)
	await ticks(2)
	var expected_ratio: float=actor.resources.current("Energy")/actor.resources.max_value("Energy")
	check(is_equal_approx(app.ui.hud_energy_ratio(),expected_ratio),"fractional energy consumption reaches the HUD without rounding to pips")
	actor.resources.change("Energy",6.25)
	await ticks(2)
	check(app.ui.hud_energy_ratio()>expected_ratio and is_equal_approx(app.ui.hud_energy_ratio(),actor.resources.current("Energy")/actor.resources.max_value("Energy")),"fractional energy recovery continuously fills the same meter")
	var energy_before: float=actor.resources.current("Energy")
	await click_slot(&"skill_q")
	check(actor.skill_casting.active() and actor.skill_casting.source=="hud" and actor.skill_casting.mode==Preferences.CAST_PRECISE and actor.skill_casting.indicator.visible,"native Q slot opens a precise preview even with default quick keyboard casting")
	var assigned_item: String=actor.inventory.quickslots[3]
	await click_slot(&"quick_item_4",MOUSE_BUTTON_RIGHT)
	check(not actor.skill_casting.active() and actor.inventory.quickslots[3]==assigned_item and skill_events==0,"right-click over an assigned item cancels casting without clearing that item slot")
	await click_slot(&"skill_q")
	check(skill_events==0 and not actor.combat.runner.busy() and is_equal_approx(actor.resources.current("Energy"),energy_before) and is_zero_approx(float(actor.combat.cooldowns.get("warrior_whirlwind",0))),"HUD selection does not start an action or pay cost and cooldown before confirmation")
	var scene_point: Vector2=app.ui.get_global_transform()*Vector2(640,500)
	check(not app.ui.blocks_world_pointer(scene_point),"HUD confirmation uses an actual point in the battle scene")
	await click_at(scene_point,MOUSE_BUTTON_RIGHT)
	check(not actor.skill_casting.active() and not actor.skill_casting.indicator.visible and not actor.combat.runner.busy() and skill_events==0 and is_equal_approx(actor.resources.current("Energy"),energy_before) and is_zero_approx(float(actor.combat.cooldowns.get("warrior_whirlwind",0))),"scene right-click cancels a HUD preview without cost or cooldown")
	await click_slot(&"skill_q")
	check(actor.skill_casting.active() and skill_events==0 and is_equal_approx(actor.resources.current("Energy"),energy_before),"HUD preview can be selected again after cancellation")
	await click_at(scene_point)
	check(skill_events==1 and actor.combat.runner.busy() and not actor.skill_casting.active(),"scene left-click confirms the native Q slot exactly once")
	check(is_equal_approx(actor.resources.current("Energy"),energy_before-20),"HUD confirmation pays exactly the selected skill's Energy cost")
	check(app.ui.quick_buttons[&"skill_q"].cooldown>0 and app.ui.quick_buttons[&"skill_q"].quantity.is_empty(),"skill cooldown remains separate from item quantity")
	check(actor.input_router.held.is_empty(),"HUD pointer never begins a hidden mouse attack")
	await ticks(55)
	actor.resources.change("HP",-150)
	var potions: int=actor.inventory.count("healing_potion")
	await click_slot(&"quick_item_1")
	check(actor.inventory.count("healing_potion")==potions-1,"native item slot consumes exactly one owned potion")
	check(app.ui.quick_buttons[&"quick_item_1"].quantity==str(potions-1) and app.ui.quick_buttons[&"quick_item_1"].cooldown>0,"item slot simultaneously retains count and cooldown")
	var candies: int=actor.inventory.count("magic_candy")
	await click_slot(&"quick_item_4",MOUSE_BUTTON_RIGHT)
	check(actor.inventory.quickslots[3].is_empty() and actor.inventory.count("magic_candy")==candies,"fourth visible slot right-click clears without consuming")
	var remap:=InputEventKey.new()
	remap.physical_keycode=KEY_4
	check(app.ui.BINDINGS.assign(0,remap),"skill key remapping swaps with the fourth item action")
	await ticks(2)
	check(app.ui.quick_buttons[&"skill_q"].caption=="4" and app.ui.quick_buttons[&"quick_item_4"].caption=="Q","all seven visible captions follow remapped actions")
	key(KEY_Q,true)
	await ticks(1)
	key(KEY_Q,false)
	check(app.ui.quick_buttons[&"quick_item_4"].pulse>0,"remapped fourth item receives real keyboard visual feedback")
	check(skill_events==1,"remapped item input does not cast the old Q skill")
	var restore:=InputEventKey.new()
	restore.physical_keycode=KEY_Q
	app.ui.BINDINGS.assign(0,restore)
	await ticks(2)
	var before: float=app.ui.hud_weapon_rect(0).size.x
	key(KEY_SHIFT,true)
	await ticks(1)
	key(KEY_SHIFT,false)
	await ticks(1)
	var intermediate: float=app.ui.hud_weapon_rect(0).size.x
	check(actor.loadout.current_set==1 and intermediate<before and intermediate>88,"actual Shift starts a smooth weapon width transition")
	await ticks(40)
	check(absf(app.ui.hud_weapon_rect(0).size.x-88)<.1 and absf(app.ui.hud_weapon_rect(1).size.x-146)<.1,"weapon transition settles at short inactive and long active widths")
	check(app.ui.hud_weapon_rect(0).size.y==24 and app.ui.hud_weapon_rect(1).position.x>app.ui.hud_weapon_rect(0).end.x,"weapon glyphs remain low and horizontally separated")
	app.game._release_actions()
	app.queue_free()
	await ticks(4)
	print("HUD_INTERACTION: %d checks; %d failures"%[checks,failures.size()])
	DirAccess.remove_absolute(Preferences.settings_path)
	Preferences.settings_path=Preferences.DEFAULT_PATH
	for failure in failures: printerr("FAIL: ",failure)
	quit(0 if failures.is_empty() else 1)
