extends SceneTree
## The real frontend HUD follows controller identity, not protagonist identity.
const Repository=preload("res://rpg/save_repository.gd")
const Preferences=preload("res://rpg/game_preferences.gd")
const OUTPUT="res://docs/hud-portrait/"
var app: Node
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
func shot(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await RenderingServer.frame_post_draw
	var picture:=root.get_texture().get_image()
	picture.save_png(OUTPUT+label+".png")
	picture.get_region(Rect2i(20,18,342,114)).save_png(OUTPUT+label+"-hud.png")
	app.portrait_view.get_texture().get_image().save_png(OUTPUT+label+"-source.png")

func run() -> void:
	root.size=Vector2i(1280,720)
	create_timer(100,true).timeout.connect(func(): printerr("HUD_PORTRAIT timeout"); quit(2))
	var isolated:=OS.get_temp_dir().path_join("hud-portrait-%d"%Time.get_ticks_usec())
	Preferences.settings_path=isolated+".cfg"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
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
	var game: Node=app.game
	var hero: Node=game.player
	var studio: SubViewport=app.portrait_view
	game.sound.muted=true
	game.combat_world.encounters_started=true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	hero.progression.choose_career("warrior")
	await ticks(35)
	check(studio.source_actor_id==hero.get_instance_id() and studio.source_definition_id==hero.definition_id,"portrait initially uses the HUD's actual hero body")
	check(studio.visual!=hero.animation and studio.visual.get_world_3d()!=hero.get_world_3d(),"portrait pose lives in an isolated world and never reposes gameplay")
	check(app.ui.portrait.material.shader.resource_path.ends_with("round_portrait.gdshader") and studio.transparent_bg,"HUD composes the pencil shader over a transparent bust")
	var revision: int=studio.render_revision
	await ticks(10)
	check(studio.render_revision==revision and studio.render_target_update_mode!=SubViewport.UPDATE_ALWAYS,"unchanged appearance does not rebuild or continuously render")
	await shot("01-kirito-pencil")
	var soldier: Node=game.combat_world.spawn_enemy("soldier",hero.global_position+Vector3(4,0,0))
	soldier.ai_enabled=false
	soldier.set_physics_process(false)
	check(game.combat_world.control.possess(soldier,30),"dreamwalk control lease enters the actual soldier")
	await ticks(6)
	check(app.ui.hud_actor()==soldier and studio.source_actor_id==soldier.get_instance_id() and studio.source_definition_id=="soldier","portrait, name and bars follow the same possessed body")
	check(studio.visual.get_script()==soldier.animation.get_script() and studio.visual._base_color==soldier.animation._base_color,"enemy portrait uses its own visual adapter and palette")
	check(app.ui.rpg==hero,"possession portrait does not replace the original character-sheet owner")
	await shot("02-soldier-pencil")
	game.combat_world.control.release()
	await ticks(5)
	check(studio.source_actor_id==hero.get_instance_id() and studio.source_definition_id=="hero","manual return restores Kirito's portrait")
	game.combat_world.control.possess(soldier,.12)
	await ticks(3)
	check(studio.source_actor_id==soldier.get_instance_id(),"short lease also changes the portrait")
	await ticks(12)
	check(studio.source_actor_id==hero.get_instance_id(),"timeout restores the original portrait automatically")
	check(hero.form.apply_enemy_form("ogre",30),"same actor can change its visual body")
	await ticks(5)
	check(studio.source_actor_id==hero.get_instance_id() and studio.source_definition_id=="ogre","transformation refreshes appearance without an actor-ID change")
	check(is_equal_approx(studio.camera.size,1.17),"large bodies keep the same portrait framing scale")
	await shot("03-transformed-pencil")
	hero.form.restore()
	await ticks(5)
	check(studio.source_definition_id=="hero","ending transformation restores the correct face")
	var ogre: Node=game.combat_world.spawn_enemy("ogre",hero.global_position+Vector3(-4,0,0))
	ogre.ai_enabled=false
	ogre.set_physics_process(false)
	# Force several switches before pending skin-registration captures settle.
	for body: Node in [soldier,ogre,hero]:
		if body==hero: game.combat_world.control.release()
		else: game.combat_world.control.possess(body,30)
		studio.sync_actor(app.ui.hud_actor())
	await ticks(6)
	check(studio.source_actor_id==hero.get_instance_id() and studio.source_definition_id=="hero","rapid switches cannot restore a stale enemy portrait")
	game.combat_world.control.possess(soldier,30)
	await ticks(3)
	soldier.queue_free()
	await ticks(5)
	check(studio.source_actor_id==hero.get_instance_id(),"removing the possessed unit returns the portrait without dangling references")
	app.ui.bind_rpg(null)
	check(studio.source_actor_id==0 and not is_instance_valid(studio.visual),"unbinding gameplay clears the previous portrait immediately")
	app.queue_free()
	await ticks(5)
	print("HUD_PORTRAIT %d/%d passed"%[checks-failures.size(),checks])
	quit(0 if failures.is_empty() else 1)
