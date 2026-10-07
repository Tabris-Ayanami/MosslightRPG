extends Node3D

const Art = preload("res://scripts/art.gd")
@export_enum("shrine", "chest", "gate", "sign") var kind := "shrine"
var opened := false
var lid: Node3D
var crystal: Node3D
var phase := 0.0
var persistent_id := ""
var display_name := ""
var activated := false
var grounded := false
var _service: RefCounted
var _lid_tween: Tween

func configure(service: RefCounted, definition: Dictionary) -> void:
	_service = service
	persistent_id = definition.id
	display_name = definition.name
	kind = definition.kind

func unbind() -> void:
	_service = null
	if is_instance_valid(_lid_tween): _lid_tween.kill()
	remove_from_group("interactables")

func apply_persistent_state(record: Dictionary, animate := false) -> void:
	var was_open := opened
	opened = record.get("opened", false)
	activated = record.get("activated", false)
	if is_instance_valid(lid):
		if not animate or opened != was_open:
			if is_instance_valid(_lid_tween): _lid_tween.kill()
			var angle := -1.2 if opened else 0.0
			if animate and opened:
				_lid_tween = create_tween()
				_lid_tween.tween_property(lid, "rotation:x", angle, .35)
			else: lid.rotation.x = angle
	if is_instance_valid(crystal) and kind == "shrine":
		crystal.material_override = Art.mat(Color("85d9b9") if activated else Color("9bb6a0"), .65 if activated else .2)

func _ground() -> void:
	if not is_inside_tree(): return
	await get_tree().physics_frame
	if not is_inside_tree(): return
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 3, global_position - Vector3.UP * 4, 1)
	var excluded: Array[RID] = []
	for body: Node in find_children("*", "CollisionObject3D", true, false): excluded.append(body.get_rid())
	query.exclude = excluded
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and hit.normal.y > .7:
		global_position.y = hit.position.y + .015
		grounded = true

func _ready() -> void:
	add_to_group("interactables")
	if get_child_count() > 0:
		lid = get_node_or_null("Lid")
		crystal = get_node_or_null("Crystal")
		if _service != null: _ground.call_deferred()
		return
	match kind:
		"shrine":
			Art.cylinder(self, Vector3(0, 0.15, 0), 0.95, 0.3, Color("777f70"), 8)
			Art.cylinder(self, Vector3(0, 0.42, 0), 0.65, 0.3, Color("a5a48b"), 8)
			crystal = Art.sphere(self, Vector3(0, 1.3, 0), Vector3(0.5, 1.3, 0.5), Color("95ebc1"))
			crystal.name = "Crystal"
			crystal.material_override = Art.mat(Color("85d9b9"), 0.65)
			Art.ring(self, Vector3(0, 0.04, 0), 1.25, 0.055, Color("aec5a2"))
		"chest":
			Art.box(self, Vector3(0, 0.3, 0), Vector3(1.05, 0.6, 0.72), Color("866744"))
			for x in [-0.39, 0.39]:
				Art.box(self, Vector3(x, 0.33, 0), Vector3(0.09, 0.66, 0.76), Color("c9ac6b"))
			lid = Node3D.new()
			lid.name = "Lid"
			lid.position = Vector3(0, 0.61, 0.36)
			add_child(lid)
			Art.box(lid, Vector3(0, 0.08, -0.36), Vector3(1.08, 0.19, 0.77), Color("a98956"))
			Art.box(self, Vector3(0, 0.51, -0.39), Vector3(0.14, 0.23, 0.06), Color("e2c585"))
		"gate":
			Art.cylinder(self, Vector3(0, 0.18, 0), 0.68, 0.35, Color("6f7e73"), 8)
			crystal = Art.box(self, Vector3(0, 0.8, 0), Vector3(0.42, 0.85, 0.24), Color("abc8b2"))
			crystal.name = "Crystal"
			crystal.rotation.z = 0.15
			Art.box(self, Vector3(0, 0.82, -0.15), Vector3(0.13, 0.40, 0.04), Color("e6ca84"))
		"sign":
			Art.box(self, Vector3(0, 0.55, 0), Vector3(0.13, 1.1, 0.16), Color("786d51"))
			Art.box(self, Vector3(0, 1.02, 0), Vector3(0.95, 0.48, 0.12), Color("a08c62"))
			Art.box(self, Vector3(0, 1.05, -0.071), Vector3(0.52, 0.035, 0.015), Color("514f3f"))
	var bounds := Vector3(0.85, 0.62, 0.65) if kind == "chest" else Vector3(0.6, 0.85, 0.6)
	if kind == "sign":
		bounds = Vector3(0.2, 0.85, 0.2)
	Art.solid_box(self, Vector3(0, bounds.y / 2, 0), bounds, Color.WHITE, false)
	if _service != null: _ground.call_deferred()

func _process(delta: float) -> void:
	phase += delta
	if kind == "shrine" and crystal:
		crystal.position.y = 1.3 + sin(phase * 1.7) * 0.12
		crystal.rotation.y += delta * 0.6

func prompt(game: Node) -> String:
	if _service != null:
		if kind == "chest": return display_name + (" · 已开启" if opened else " · F 打开")
		if kind == "shrine": return display_name + " · F 恢复 / 记录重生点"
	match kind:
		"shrine": return "苔光石碑 · 恢复 / 记录重生点"
		"chest": return "宝箱已开启" if opened else "打开遗迹宝箱"
		"gate": return "试炼进行中" if game.wave_active else "唤醒下一轮试炼"
		"sign": return "阅读旅人手记"
	return "交互"

func interact(game: Node) -> void:
	if _service != null:
		if not _service.interact(self): game.notify(_service.last_error)
		return
	if not persistent_id.is_empty():
		game.notify("世界物体已释放，暂时无法交互")
		return
	match kind:
		"shrine":
			game.checkpoint = global_position + Vector3(1.6, 0.05, 0)
			game.player.restore(game.player.global_position)
			game.notify("苔光回应了你 · 状态恢复，重生点已记录", Color("b4e4b3"))
			game.ring_fx(global_position + Vector3(0, 0.1, 0), 2.0, Color("a1e2bd"), 0.6)
			game.sound.play_tone("heal")
		"chest":
			if opened:
				game.notify("箱中已空 · 获得的物品已放入背包")
				return
			opened = true
			game.player.inventory.add_item("healing_potion", 3)
			game.player.inventory.add_item("magic_candy", 1)
			create_tween().tween_property(lid, "rotation:x", -1.2, 0.35)
			game.burst(global_position + Vector3.UP, Color("efd495"), 18, 1.4)
			game.notify("获得生命药水 ×3 · 神奇糖果 ×1", Color("e6ca84"))
			game.sound.play_tone("chest")
		"gate":
			if game.wave_active:
				game.notify("先击败庭院中的全部敌人")
			else:
				game.start_wave()
		"sign":
			game.show_help = not game.show_help
			game.notify("旅人手记 · WASD 移动朝向；攻击时鼠标瞄准；Space 闪避，Shift 切换技能组")
