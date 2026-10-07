extends "res://combat/combat_world.gd"

const Inputs = preload("res://combat/input_map.gd")
const Sound = preload("res://scripts/sound.gd")
var ui: Control
var renderer: Node
var player_visual_script: Script
var chest_position := Vector3(-5, 0, 7)
var warnings: Dictionary = {}

func _ready() -> void:
	Inputs.install()
	renderer = preload("res://combat/arena_presentation.gd").new()
	add_child(renderer)
	actor_parent = renderer.world
	_build_world()
	sound = Sound.new()
	add_child(sound)
	sound.muted = DisplayServer.get_name() == "headless"
	effects = Node3D.new()
	effects.name = "CombatEffects"
	actor_parent.add_child(effects)
	player = Actor.new()
	player.name = "Player"
	player.is_player = true
	player.visual_script = player_visual_script
	player.arena = self
	player.position = Vector3(0, .05, 8)
	actor_parent.add_child(player)
	camera = renderer.camera
	renderer.follow(player)
	reset_enemies()
	var layer := CanvasLayer.new()
	add_child(layer)
	var ui_script: Script = load("res://combat/combat_ui.gd")
	if ui_script:
		ui = ui_script.new()
		ui.arena = self
		layer.add_child(ui)
	get_window().focus_exited.connect(_focus_lost)

func _build_world() -> void:
	var env := WorldEnvironment.new()
	# Clone environment and sunlight settings straight from the existing main map.
	var scene: PackedScene = load("res://scenes/reference_map.tscn")
	var state := scene.get_state()
	var sun := DirectionalLight3D.new()
	for i in range(state.get_node_count()):
		var target: Node = env if state.get_node_name(i) == &"GardenEnvironment" else (sun if state.get_node_name(i) == &"GardenSun" else null)
		if target:
			for j in range(state.get_node_property_count(i)):
				var value: Variant = state.get_node_property_value(i, j)
				target.set(state.get_node_property_name(i, j), value.duplicate() if value is Resource else value)
	actor_parent.add_child(env)
	actor_parent.add_child(sun)
	renderer.camera.environment = env.environment
	Art.solid_box(actor_parent, Vector3(0, -.3, -3), Vector3(44, .6, 48), Color("496061"))
	for x in range(-5, 6):
		for z in range(-6, 6):
			Art.box(actor_parent, Vector3(x * 4, .012, z * 4), Vector3(3.94, .018, 3.94), Color("506666") if (x + z) % 2 == 0 else Color("536c6a"))
	for boundary in [[Vector3(-22, .6, -3), Vector3(.7, 1.2, 48)], [Vector3(22, .6, -3), Vector3(.7, 1.2, 48)], [Vector3(0, .6, -27), Vector3(44, 1.2, .7)], [Vector3(0, .6, 21), Vector3(44, 1.2, .7)]]:
		Art.solid_box(actor_parent, boundary[0], boundary[1], Color("344c51"))
	for at in [Vector3(-11, 1, 1), Vector3(11, 1, 1), Vector3(-5, 1, -13), Vector3(5, 1, -13)]:
		Art.solid_box(actor_parent, at, Vector3(2, 2, 2), Color("83918a"))
		Art.box(actor_parent, at + Vector3(0, 1.06, 0), Vector3(2.2, .18, 2.2), Color("b7b9a0"))
	Art.solid_box(actor_parent, chest_position + Vector3(0, .45, 0), Vector3(1.3, .9, .75), Color("9e7648"))
	Art.box(actor_parent, chest_position + Vector3(0, .9, 0), Vector3(1.4, .15, .85), Color("d7ba78"))
	_label("装备测试箱 · F", chest_position + Vector3.UP * 1.7)
	_label("战斗演练场", Vector3(0, .3, -23), 64)
	Art.ring(actor_parent, Vector3(0, .04, 8), 2.3, .08, Color("9cd9c5"))

func _label(text: String, at: Vector3, font_size := 30) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = font_size
	label.pixel_size = .015
	label.modulate = Color("f4e4b8")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = at
	actor_parent.add_child(label)

func _physics_process(delta: float) -> void:
	toast_time = maxf(0, toast_time - delta)
	if not is_instance_valid(player):
		return
	if is_instance_valid(locked_target) and (locked_target.combat.state == "DEAD" or controlled_actor().global_position.distance_to(locked_target.global_position) > 25):
		locked_target = null
	refresh_aim()
	renderer.player = controlled_actor()
	renderer.paused = input_blocked
	tick_floaters(delta)
	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue
		var id := enemy.get_instance_id()
		var active: bool = enemy.combat.runner.busy() and enemy.combat.runner.action_phase == "STARTUP"
		if active and not warnings.has(id):
			warnings[id] = Art.ring(effects, enemy.global_position + Vector3.UP * .05, enemy.attack_reach, .08, Color("eb9169"))
		if warnings.has(id):
			if active:
				warnings[id].global_position = enemy.global_position + Vector3.UP * .05
			else:
				warnings[id].queue_free()
				warnings.erase(id)

func _unhandled_input(event: InputEvent) -> void:
	if renderer._camera_input(event):
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("interact"):
		if player.global_position.distance_to(chest_position) <= 3:
			player.combat.restore_resources()
			if ui and ui.has_method("toggle_menu"):
				ui.toggle_menu()
			notify("测试箱：资源与道具已补满；可配置职业、技能和装备")
		else:
			notify("靠近出生点左侧的装备测试箱，再按 F")

func _focus_lost() -> void:
	Inputs.release_all()
	controlled_actor().input_router.cancel()

func reset_enemies() -> void:
	if control: control.cancel_all()
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.queue_free()
	enemies.clear()
	locked_target = null
	var ids: Array = database.enemies.keys()
	var positions := [Vector3(-8, .05, -3), Vector3(0, .05, -7), Vector3(8, .05, -3), Vector3(0, .05, -18)]
	for i in range(mini(4, ids.size())):
		spawn_enemy(ids[i], positions[i])

func reset_arena() -> void:
	control.cancel_all()
	player.form.clear_for_load()
	for effect in effects.get_children():
		effect.queue_free()
	warnings.clear()
	reset_enemies()
	player.global_position = Vector3(0, .05, 8)
	player.combat.reset()

func defense_drill(kind: String) -> void:
	if kind not in ["shield", "counter", "grab", "dual"]:
		return
	player.combat.reset()
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.queue_free()
	enemies.clear()
	for effect in effects.get_children():
		effect.queue_free()
	warnings.clear()
	floaters.clear()
	player.loadout.select_career("warrior")
	if kind in ["counter", "shield"]:
		player.loadout.set_level(2)
		player.loadout.select_career("duelist" if kind == "counter" else "soldier")
	elif kind == "dual":
		player.loadout.set_level(10)
		player.loadout.select_career("swordsman")
		player.loadout.select_career("dual_swordsman")
	player.global_position = Vector3(0, .05, 6)
	player.facing = Vector3.FORWARD
	var enemy := spawn_enemy("ogre" if kind == "grab" else "soldier", Vector3(0, .05, 4.3))
	enemy.facing = Vector3.BACK
	enemy.ai_cooldown = 2.0
	if kind == "grab":
		enemy.grab_every = 1
	locked_target = enemy
	aim_point = enemy.global_position
	player.combat.engage()
	notify({"shield": "士兵：左键剑 / 右键盾，微白光为精准窗口；Shift 只切换技能组", "counter": "R 负剑：站定进入反击姿态，拦截下一击并自动反击", "grab": "红光抓取无法格挡；Space 闪避或拉开距离", "dual": "二刀流：每次剑武技双剑接连出手；Shift 切换 A/B 技能组"}[kind])

func kill_all_enemies() -> void:
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.resources.change("HP", -enemy.resources.max_value("HP"))


func world_to_screen(point: Vector3) -> Vector2:
	return renderer.world_to_screen(point)
