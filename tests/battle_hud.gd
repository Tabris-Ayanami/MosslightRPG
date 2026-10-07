extends SceneTree
## Actual actions damage actual enemies; the same presenter runs in both worlds.
const Preferences = preload("res://rpg/game_preferences.gd")
const Overlay = preload("res://rpg/world_overlay.gd")
var mounted: Node
var arena: Node
var overlay: Control
var player: Node
var helper: RefCounted
var checks := 0
var failures: Array[String] = []
var mode := ""
var hit_count := 0

func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(mode+": "+label)
	print("PASS " if ok else "FAIL ",mode," ",label)
func shot(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/battle-hud/"+mode+"-"+label+".png")
func visible_enemy(enemy: Node) -> Dictionary:
	for entry in helper.overhead_entries:
		if entry.id == enemy.get_instance_id(): return entry
	return {}
func spawn(id: String, at: Vector3) -> Node:
	var enemy: Node = arena.spawn_enemy(id,at)
	enemy.ai_enabled=false
	enemy.set_physics_process(false)
	enemy.combat.in_combat=false
	enemy.combat.combat_timeout=0
	return enemy
func strike(enemy: Node, amount := 220.0) -> void:
	for i in range(60):
		if player.combat.can_start(): break
		await ticks(1)
	arena.locked_target=enemy
	arena.aim_override=enemy.global_position
	arena.aim_point=enemy.global_position
	if is_instance_valid(arena.host): arena.host.aim_override=enemy.global_position
	var before: float=enemy.resources.current("HP")
	var action: Dictionary={"id":"hud_test_strike","name":"HUD真实命中测试","is_skill":false,"presentation_type":"WEAPON_ACTION","animation_family":"SINGLE_BLADE",
		"startup":.02,"active":.05,"recovery":.025,"cooldown":0,"costs":{},"gains":{},"formula":{"base":amount},"damage_type":"PHYSICAL","can_crit":false,
		"targeting":"TARGET","range":12.0,"radius":.7,"poise_damage":0,"knockback_force":0,"conditions":[],"effects":[]}
	check(player.combat.use_action(action),"attack starts through the actual action runner")
	for i in range(45):
		await ticks(1)
		if enemy.resources.current("HP")<before: break
	check(enemy.resources.current("HP")<before,"AttackInstance decreases real enemy HP")
	hit_count+=1
	await ticks(1)

func build(which: String) -> void:
	mode=which
	if mode=="main":
		mounted=load("res://scenes/frontend/app.tscn").instantiate()
		root.add_child(mounted)
		mounted.set_process(false)
		await ticks(3)
		mounted._enter_world(load("res://scenes/main.tscn"))
		mounted._finish_arrival()
		arena=mounted.game.combat_world
		player=arena.player
		player.progression.choose_career("warrior")
		mounted.ui.close_panel(true)
		mounted.ui.modulate.a=1
		mounted.ui.region_clock=0
		arena.encounters_started=true
		for child in mounted.game.get_children():
			if child.get_script()==Overlay: overlay=child
	else:
		mounted=load("res://scenes/demo/CombatTestArena.tscn").instantiate()
		root.add_child(mounted)
		arena=mounted
		player=arena.player
		player.loadout.select_career("warrior")
		overlay=arena.ui
		overlay.toggle_menu(false)
	for enemy in arena.enemies:
		if is_instance_valid(enemy): enemy.queue_free()
	arena.enemies.clear()
	arena.locked_target=null
	arena.floaters.clear()
	arena.sound.muted=true
	player.combat.reset()
	await ticks(8)
	helper=overlay.battle_hud
	check(helper.get_script()==preload("res://combat/battle_hud.gd"),"production scene uses the shared battle presenter")

func exercise() -> void:
	var enemy: Node=spawn("soldier",player.global_position+Vector3.RIGHT*1.6)
	await ticks(3)
	check(visible_enemy(enemy).is_empty(),"idle enemy has no battle bar")
	arena.locked_target=enemy
	await ticks(2)
	check(visible_enemy(enemy).is_empty(),"lock-on alone does not show an out-of-combat bar")
	await strike(enemy)
	var first: Dictionary=visible_enemy(enemy)
	check(not first.is_empty() and is_equal_approx(first.get("ratio",-1),enemy.health.ratio()),"first hit shows an immediately accurate HP bar")
	check(first.get("trail",0)>first.get("ratio",1),"lost HP remains in the delayed pale trail")
	check(helper.number_entries.size()==1,"one actual hit creates one damage number")
	if not first.is_empty() and not helper.number_entries.is_empty():
		check(helper.number_entries[0].position.y<first.position.y-20*helper.ui_scale,"damage number starts above the enemy bar")
	await shot("01-hit-trail")
	var old_trail: float=first.get("trail",0)
	await strike(enemy,180)
	var second: Dictionary=visible_enemy(enemy)
	check(second.get("ratio",1)<first.get("ratio",0) and second.get("trail",0)>=old_trail-.001,"quick second hit lowers HP immediately and preserves the prior trailing segment")
	check(helper.number_entries.size()==2 and helper.number_entries[0].position.x!=helper.number_entries[1].position.x,"two damage numbers occupy distinct floating lanes")
	if helper.number_entries.size()==2:
		check(not helper.number_entries[0].bounds.intersects(helper.number_entries[1].bounds),"consecutive hit numbers remain readable without overlapping")
	await shot("02-multiple-hits")
	var trail_before: float=second.get("trail",0)
	await ticks(8)
	check(is_equal_approx(helper.states[enemy.get_instance_id()].trail,trail_before),"trailing HP waits after the most recent hit")
	await ticks(11)
	check(helper.states[enemy.get_instance_id()].trail<trail_before,"delayed segment starts following after its hold")
	await ticks(45)
	check(is_equal_approx(helper.states[enemy.get_instance_id()].trail,enemy.health.ratio()),"trail settles exactly at real HP")
	check(helper.number_entries.is_empty() and arena.floaters.is_empty(),"expired floaters leave no retained entries")
	await shot("03-trail-settled")
	check(Preferences.set_damage_numbers(false)==OK,"damage number preference can be disabled")
	await strike(enemy,75)
	check(helper.number_entries.is_empty() and arena.floaters.is_empty(),"disabled damage numbers create no hidden numeric queue")
	arena.float_text(enemy.global_position+Vector3.UP*2,"破绽",Color.WHITE)
	await ticks(2)
	check(helper.status_entries.size()==1,"important nonnumeric combat feedback remains enabled")
	await shot("04-numbers-disabled")
	Preferences.set_damage_numbers(true)
	await strike(enemy,60)
	check(not helper.number_entries.is_empty(),"reenabling damage numbers affects the next real hit")
	Preferences.set_damage_numbers(false)
	await ticks(1)
	check(helper.number_entries.is_empty() and arena.floaters.all(func(entry: Dictionary)->bool:return not entry.get("is_damage",false)),"toggling off removes already visible numbers immediately")
	Preferences.set_damage_numbers(true)
	var old_position: Vector3=enemy.global_position
	enemy.global_position=arena.camera.global_position+arena.camera.global_basis.z*5
	await ticks(2)
	check(visible_enemy(enemy).is_empty(),"enemies behind the camera are not projected into the HUD")
	enemy.global_position=old_position
	enemy.combat.in_combat=false
	enemy.combat.combat_timeout=0
	await ticks(2)
	check(visible_enemy(enemy).is_empty(),"leaving combat hides the overhead bar")
	enemy.combat.engage()
	await ticks(2)
	check(not visible_enemy(enemy).is_empty(),"reengaging restores a current bar without stale damage")
	enemy.global_position=player.global_position+Vector3.RIGHT*8
	var boss: Node=spawn("ogre",player.global_position+Vector3.LEFT*1.8)
	await ticks(2)
	check(not helper.boss_active,"idle boss has no screen-wide bar")
	await strike(boss,500)
	check(helper.boss_active and helper.boss_entry.id==boss.get_instance_id(),"hitting the boss opens its dedicated combat header")
	check(not str(helper.boss_entry.get("title","")).is_empty() and helper.boss_entry.name==boss.display_name,"boss header exposes separate title and name")
	check(is_equal_approx(helper.boss_entry.width,420*helper.ui_scale) and helper.boss_entry.position.y<110*helper.ui_scale,"boss HP uses the compact top-center bar")
	check(visible_enemy(boss).is_empty() and not visible_enemy(enemy).is_empty() and not helper.lock_entries.is_empty(),"boss keeps only its top bar and lock ring while ordinary enemy bars remain visible")
	check(helper.boss_entry.trail>helper.boss_entry.ratio,"boss header shares the immediate-hit and delayed-trail animation")
	await shot("05-boss-hit")
	boss.combat.in_combat=false
	boss.combat.combat_timeout=0
	await ticks(2)
	check(not helper.boss_active,"boss disengagement hides the header")
	await strike(boss,100)
	check(helper.boss_active,"boss reengagement restores the header")
	await strike(boss,100000)
	check(boss.combat.state=="DEAD" and not helper.boss_active,"actual boss death immediately removes the header")
	check(not helper.states.has(boss.get_instance_id()),"dead bosses do not retain trail state")
	var removed_id: int=enemy.get_instance_id()
	arena.enemies.erase(enemy)
	enemy.queue_free()
	await ticks(2)
	check(not helper.states.has(removed_id),"despawned enemies are pruned without dangling identities")
	await shot("06-boss-defeated")
	if is_instance_valid(arena.host): arena.host._release_actions()
	helper.clear()
	check(helper.states.is_empty() and helper.overhead_entries.is_empty() and helper.number_entries.is_empty(),"explicit teardown clears every presentation state")
	mounted.queue_free()
	await ticks(5)

func run() -> void:
	root.size=Vector2i(1920,1080)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/battle-hud/"))
	Preferences.settings_path=OS.get_temp_dir().path_join("mosslight-battle-hud-%d-%d.cfg"%[OS.get_process_id(),Time.get_ticks_usec()])
	var config:=ConfigFile.new()
	config.set_value("unrelated","volume",.37)
	config.save(Preferences.settings_path)
	check(Preferences.set_damage_numbers(false)==OK,"isolated setting saves")
	Preferences.reload_preferences()
	check(not Preferences.get_damage_numbers(),"damage preference survives an explicit reload")
	config.load(Preferences.settings_path)
	check(is_equal_approx(float(config.get_value("unrelated","volume")),.37),"saving damage preference preserves unrelated options")
	Preferences.set_damage_numbers(true)
	for which in ["main","arena"]:
		await build(which)
		await exercise()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Preferences.settings_path))
	Preferences.settings_path=Preferences.DEFAULT_PATH
	Preferences.reload_preferences()
	print("BATTLE_HUD: %d checks; %d failures; %d real action hits"%[checks,failures.size(),hit_count])
	for failure in failures: printerr("FAIL: ",failure)
	quit(0 if failures.is_empty() else 1)
