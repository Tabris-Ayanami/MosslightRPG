extends SceneTree
## Real Dreamwalk, common faction queries and the production overhead presenter.
const Preferences=preload("res://rpg/game_preferences.gd")
const Repository=preload("res://rpg/save_repository.gd")
const Definitions=preload("res://combat/unit_definition.gd")
const Overlay=preload("res://rpg/world_overlay.gd")
var app: Node
var game: Node
var arena: Node
var hero: Node
var hud: RefCounted
var checks:=0
var failures: Array[String]=[]

func _initialize() -> void: call_deferred("run")
func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func entry(unit: Node) -> Dictionary:
	for record in hud.overhead_entries:
		if record.id==unit.get_instance_id(): return record
	return {}
func spawn(id: String, faction: String, offset: Vector3, label: String) -> Node:
	var definition:=Definitions.for_enemy(arena.database,id)
	definition.faction_id=faction
	definition.name=label
	var unit: Node=arena.spawn_unit(definition,hero.global_position+offset,"none")
	unit.ai_enabled=false
	unit.set_physics_process(false)
	return unit
func shot(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/faction-hud/"+label+".png")

func run() -> void:
	root.size=Vector2i(1280,720)
	create_timer(120,true).timeout.connect(func(): printerr("FACTION_HUD timeout"); quit(2))
	var isolated:=OS.get_temp_dir().path_join("faction-hud-%d"%Time.get_ticks_usec())
	Preferences.settings_path=isolated+".cfg"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/faction-hud"))
	app=load("res://scenes/frontend/app.tscn").instantiate()
	app.saves=Repository.new(isolated)
	root.add_child(app)
	app.set_process(false)
	await ticks(3)
	app._enter_world(load("res://scenes/main.tscn"))
	app._finish_arrival()
	app.ui.close_panel(true)
	app.ui.modulate.a=1
	app.ui.region_clock=0
	game=app.game
	arena=game.combat_world
	hero=game.player
	for child in game.get_children():
		if child.get_script()==Overlay: hud=child.battle_hud
	game.sound.muted=true
	arena.encounters_started=true
	for unit in arena.enemies: unit.set_physics_process(false)
	check(hero.progression.choose_career("mage"),"choose mage through normal progression")
	check(hero.inventory.add_item("magic_candy") and hero.inventory.use_item("magic_candy"),"explicit test fixture grants and uses the level item")
	check(hero.progression.choose_career("conjurer"),"advance to conjurer through its real career gate")
	check(hero.progression.learn_skill("conjurer_dreamwalk") and hero.loadout.assign_skill(0,0,"conjurer_dreamwalk"),"learn and equip real Dreamwalk in Q")
	Preferences.set_cast_mode("skill_q",Preferences.CAST_QUICK)
	var soldier: Node=spawn("soldier","hostiles",Vector3(2.0,0,0),"梦行目标")
	var companion: Node=spawn("ogre","heroes",Vector3(-2.7,0,0),"友方守卫")
	var neutral: Node=spawn("heavy_guard","forest_wardens",Vector3(0,0,-3.4),"林地旅人")
	var hostile: Node=spawn("heavy_guard","hostiles",Vector3(-2.8,0,2.5),"敌方守卫")
	await ticks(25)
	check(arena.relation_between(hero,hero)==&"self" and not arena.are_hostile(hero,hero),"self is distinct from a friendly or attackable unit")
	check(arena.are_allied(hero,companion) and arena.are_allied(companion,hero),"same-faction alliance is symmetric for ordinary actors")
	check(arena.relation_between(hero,neutral)==&"neutral" and not arena.are_allied(hero,neutral),"non-hostile villagers are not implicitly teammates")
	check(arena.are_hostile(hero,soldier) and arena.relation_between(hero,null)==&"invalid","hostility and invalid actors use the same relation resolver")
	check(not entry(companion).is_empty() and entry(companion).relation==&"ally" and not companion.combat.in_combat,"ordinary idle allies already get the shared overhead bar")
	check(entry(hero).is_empty() and entry(neutral).is_empty() and entry(soldier).is_empty(),"self, neutrals and idle hostiles have no duplicate battle bars")
	check(not hud.boss_active and companion.is_boss and not entry(companion).is_empty(),"a friendly boss uses an ally bar, never an enemy boss header")
	check(arena.set_faction_relation("heroes","forest_wardens",&"ally") and arena.are_allied(neutral,hero),"distinct factions can explicitly ally without changing unit identity")
	await ticks(2)
	check(entry(neutral).get("relation")==&"ally" and neutral not in arena.targets_for(hero),"overhead UI and attack targeting agree on a cross-faction alliance")
	arena.set_faction_relation("heroes","forest_wardens",false)
	await ticks(2)
	check(arena.relation_between(hero,neutral)==&"neutral" and entry(neutral).is_empty(),"clearing hostility means neutral and removes the teammate bar")
	arena.set_faction_relation("heroes","forest_wardens",true)
	neutral.combat.engage()
	await ticks(2)
	check(entry(neutral).get("relation")==&"hostile" and neutral in arena.targets_for(hero),"explicit hostility updates presentation and combat consistently")
	arena.set_faction_relation("heroes","forest_wardens",&"neutral")
	neutral.combat.reset()
	check(not arena.set_faction_relation("heroes","forest_wardens",&"typo") and arena.relation_between(hero,neutral)==&"neutral","an invalid relation cannot corrupt the current diplomacy")
	# Trigger the actual equipped spell using physical Q, not a presentation hook.
	arena.locked_target=soldier
	game.aim_override=soldier.global_position
	await ticks(2)
	for down in [true,false]:
		var key:=InputEventKey.new()
		key.physical_keycode=KEY_Q
		key.keycode=KEY_Q
		key.pressed=down
		Input.parse_input_event(key)
		await ticks(1)
	await ticks(25)
	check(arena.controlled_actor()==soldier and hero.control_mode=="none","physical Q Dreamwalk transfers control and leaves Kirito's body in world")
	if arena.controlled_actor()!=soldier:
		app.queue_free()
		await ticks(4)
		quit(1)
		return
	check(arena.are_allied(soldier,hero) and arena.relation_between(soldier,hero)==&"ally","the old body is naturally an ally of the controlled body")
	check(entry(hero).get("relation")==&"ally" and is_equal_approx(entry(hero).get("ratio",-1),hero.health.ratio()),"Kirito's real HP appears overhead via the same rule as every ally")
	check(entry(soldier).is_empty() and app.ui.hud_actor()==soldier,"only the controlled body's HP belongs in the corner HUD")
	check(entry(companion).get("relation")==entry(hero).get("relation") and entry(neutral).is_empty(),"protagonist and ordinary allies share presentation; neutrals stay neutral")
	check(hero not in arena.targets_for(soldier) and companion not in arena.targets_for(soldier) and hostile in arena.targets_for(soldier),"possessed unit targets enemies without friendly fire candidates")
	check(hero in arena.targets_for(hostile) and soldier in arena.targets_for(hostile),"hostile AI can still attack both allied bodies")
	var packet: Dictionary=hostile.action_for("PRIMARY_TAP")
	var prior_hp: float=hero.resources.current("HP")
	var friendly_hit: Dictionary=soldier.combat.hit_target(hero,packet,Vector3.LEFT)
	check(friendly_hit.get("blocked",false) and hero.resources.current("HP")==prior_hp,"real damage routing rejects the possessed body's friendly attack")
	var hostile_hit: Dictionary=hostile.combat.hit_target(hero,packet,Vector3.RIGHT)
	await ticks(2)
	check(not hostile_hit.get("blocked",true) and hero.resources.current("HP")<prior_hp,"hostile damage still reaches the parked original body")
	check(is_equal_approx(entry(hero).get("ratio",-1),hero.health.ratio()) and entry(hero).get("trail",0)>entry(hero).get("ratio",1),"ally bar updates real damage immediately and shares the delayed HP trail")
	await shot("01-dreamwalk-allies")
	var saved_position: Vector3=companion.global_position
	companion.global_position=hero.global_position+Vector3.RIGHT*60
	await ticks(2)
	check(entry(companion).is_empty(),"distant allies do not stick to the screen edge")
	companion.global_position=saved_position
	arena.control.release()
	soldier.combat.engage()
	await ticks(5)
	check(entry(hero).is_empty() and app.ui.hud_actor()==hero,"returning control removes the duplicate overhead bar from the controlled body")
	check(arena.are_hostile(hero,soldier) and entry(soldier).get("relation")==&"hostile","released unit restores original faction and enemy presentation")
	await shot("02-returned-to-kirito")
	arena.control.possess(soldier,.18)
	await ticks(3)
	check(entry(hero).get("relation")==&"ally","temporary reacquisition applies the same relation rule immediately")
	await ticks(15)
	check(arena.controlled_actor()==hero and entry(hero).is_empty(),"lease expiry restores the ordinary self/ally/enemy classification")
	companion.health.receive(999999)
	await ticks(2)
	check(entry(companion).is_empty() and not hud.states.has(companion.get_instance_id()),"dead allies lose their bar and cached trail state")
	var removed_id:=neutral.get_instance_id()
	neutral.queue_free()
	await ticks(2)
	check(not hud.states.has(removed_id),"removed units leave no stale overhead state")
	app.queue_free()
	await ticks(5)
	print("FACTION_HUD %d/%d passed"%[checks-failures.size(),checks])
	quit(0 if failures.is_empty() else 1)
