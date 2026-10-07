extends SceneTree
var game: Node
var checks := 0
var failures: Array[String] = []
var fixtures: Array[Node] = []
func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func key(pressed: bool) -> void:
	var event:=InputEventKey.new()
	event.physical_keycode=KEY_W
	event.keycode=KEY_W
	event.pressed=pressed
	Input.parse_input_event(event)
func start(at: Vector3,yaw: float) -> void:
	key(false)
	game._release_actions()
	game.camera_yaw=yaw
	game.player.restore(game.GARDEN_ORIGIN+at)
	await ticks(12)
func capture(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/traversal/"+label+".png")
func walk(n: int) -> void:
	key(true)
	await ticks(n)
	key(false)
	await ticks(3)
func walk_to(at: Vector2,limit: int) -> void:
	var target: Vector3=game.GARDEN_ORIGIN+Vector3(at.x,0,at.y)
	key(true)
	for i in range(limit):
		await ticks(1)
		var offset: Vector3=target-game.player.global_position
		offset.y=0
		if offset.dot(game.camera_forward())<=0: break
	key(false)
	await ticks(3)
func box(at: Vector3,size: Vector3) -> void:
	var body:=StaticBody3D.new()
	var shape:=CollisionShape3D.new()
	var geometry:=BoxShape3D.new()
	geometry.size=size
	shape.shape=geometry
	body.add_child(shape)
	game.world.add_child(body)
	body.global_position=game.GARDEN_ORIGIN+at
	fixtures.append(body)
func run() -> void:
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(25)
	game.sound.muted=true
	game.combat_world.encounters_started=true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	var actor: Node=game.player
	var hp: float=actor.resources.current("HP")
	await start(Vector3(2.5,-.1,13.4),0)
	check(actor.swimming,"garden starts swimming below the shoreline")
	await capture("01-garden-water")
	var before_steps: int=actor.surface_traversal.steps
	await walk_to(Vector2(2.5,8.2),240)
	print("TRACE garden ",actor.global_position-game.GARDEN_ORIGIN," reason=",actor.surface_traversal.last_reason," step=",actor.surface_traversal.last_step)
	check(not actor.swimming and not actor.wading and actor.global_position.y>1.6,"physical W input leaves water across the garden south bank")
	# This real bank is a continuous 63-degree slope; it now uses normal floor
	# movement. Exact frame continuity is checked by surface_motion_regression.
	await capture("02-garden-land")
	await start(Vector3(70.5,-.1,0),PI/2)
	check(actor.swimming,"forest starts swimming below the shoreline")
	await capture("03-forest-water")
	await walk_to(Vector2(64,0),250)
	print("TRACE forest ",actor.global_position-game.GARDEN_ORIGIN," reason=",actor.surface_traversal.last_reason)
	check(not actor.swimming and not actor.wading and actor.global_position.x<65,"physical W input leaves water across the forest east bank")
	check(is_equal_approx(hp,actor.resources.current("HP")),"swimming and shore exits preserve health")
	await capture("04-forest-land")
	# Actual village wall: approach its south face along its own local forward axis.
	var house: Node3D=game.reference_map.get_node("NorthernVillage/Buildings/House_2")
	var wall_forward: Vector3=house.global_basis.z.normalized()
	var house_start: Vector3=house.global_position+wall_forward*5.2
	house_start.y=2.35
	await start(house_start-game.GARDEN_ORIGIN,atan2(wall_forward.x,wall_forward.z))
	before_steps=actor.surface_traversal.steps
	await walk(180)
	var house_local: Vector3=house.to_local(actor.global_position)
	print("TRACE house local ",house_local)
	check(house_local.z>1.0 and actor.global_position.y<2.7,"actual village house remains a blocking wall")
	check(actor.surface_traversal.steps==before_steps,"house wall cannot become a climbing step")
	await capture("05-house-wall")
	# Isolated geometry exercises exact capsule limits without changing map assets.
	box(Vector3(100,9.8,0),Vector3(12,.4,18))
	box(Vector3(100,10.125,-2),Vector3(4,.25,3))
	await start(Vector3(100,10.05,1),0)
	before_steps=actor.surface_traversal.steps
	await walk(48)
	check(actor.global_position.y>10.2 and actor.surface_traversal.steps>before_steps,"a quarter metre dry step can be climbed")
	box(Vector3(104,10.65,-2),Vector3(2,1.3,3))
	await start(Vector3(104,10.05,1),0)
	before_steps=actor.surface_traversal.steps
	await walk(100)
	check(actor.global_position.z>game.GARDEN_ORIGIN.z-.5 and actor.global_position.y<10.1 and actor.surface_traversal.steps==before_steps,"a 1.3 metre dry wall cannot be stepped through")
	box(Vector3(96,10.15,-2),Vector3(2,.3,3))
	box(Vector3(96,11.55,-1.5),Vector3(2,.3,4))
	await start(Vector3(96,10.05,1),0)
	before_steps=actor.surface_traversal.steps
	await walk(100)
	check(actor.global_position.z>game.GARDEN_ORIGIN.z-.5 and actor.surface_traversal.steps==before_steps,"low overhead clearance rejects an otherwise reachable step")
	box(Vector3(80,.6,7),Vector3(4,2.8,3))
	await start(Vector3(80,-.1,10),0)
	before_steps=actor.surface_traversal.steps
	check(actor.swimming,"shore wall case starts in actual lake water")
	await walk(140)
	check(actor.swimming and actor.global_position.z>game.GARDEN_ORIGIN.z+8.5 and actor.surface_traversal.steps==before_steps,"swimming cannot use the higher shore limit to climb a tall wall")
	key(false)
	game._release_actions()
	print("SURFACE_TRAVERSAL_RESULT %d/%d passed"%[checks-failures.size(),checks])
	game.queue_free()
	await ticks(3)
	quit(0 if failures.is_empty() else 1)
