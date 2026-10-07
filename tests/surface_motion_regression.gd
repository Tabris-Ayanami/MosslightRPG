extends SceneTree
## Real InputMap events; frame deltas are captured after each physics tick.
var game: Node
var actor: Node
var checks := 0
var failures: Array[String] = []
var traces: Dictionary = {}
var baseline := false
var hz := 60
var smoke := false
func _initialize() -> void: call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func key(code: Key,pressed: bool) -> void:
	var event:=InputEventKey.new()
	event.physical_keycode=code
	event.keycode=code
	event.pressed=pressed
	Input.parse_input_event(event)
func start(at: Vector3,yaw: float) -> void:
	key(KEY_W,false)
	key(KEY_SPACE,false)
	game._release_actions()
	game.camera_yaw=yaw
	actor.restore(game.GARDEN_ORIGIN+at)
	await ticks(12)
func xyz(value: Vector3) -> Array: return [value.x,value.y,value.z]
func route(label: String,at: Vector3,target: Vector2,yaw: float,limit:=300,dodge_mode: String="") -> Dictionary:
	await start(at,yaw)
	var rows: Array=[]
	var maximum_xz:=0.0
	var maximum_y:=0.0
	var max_xz_frame:=0
	var max_y_frame:=0
	var prior: Vector3=actor.global_position
	var goal: Vector3=game.GARDEN_ORIGIN+Vector3(target.x,0,target.y)
	var start_steps: int=actor.surface_traversal.steps
	var dodges:=0
	var rolls:=0
	var dashes:=0
	var period: int=maxi(1,roundi(.6*hz))
	key(KEY_W,true)
	for frame in range(roundi(limit*hz/60.0)):
		if dodge_mode=="roll": actor.combat.engage()
		if not dodge_mode.is_empty():
			key(KEY_SPACE,frame%period==2)
		await ticks(1)
		var current: Vector3=actor.global_position
		var displacement: Vector3=current-prior
		var xz:=Vector2(displacement.x,displacement.z).length()
		if xz>maximum_xz:
			maximum_xz=xz
			max_xz_frame=frame
		if absf(displacement.y)>maximum_y:
			maximum_y=absf(displacement.y)
			max_y_frame=frame
		if actor.combat.state=="DODGE":
			dodges+=1
			if actor.combat.dodge_is_dash: dashes+=1
			else: rolls+=1
		rows.append({"frame":frame,"position":xyz(current-game.GARDEN_ORIGIN),"delta":xyz(displacement),"state":actor.combat.state,"swimming":actor.swimming,"wading":actor.wading,"steps":actor.surface_traversal.steps-start_steps,"reason":actor.surface_traversal.last_reason})
		prior=current
		var remaining:=goal-current
		remaining.y=0
		if remaining.dot(game.camera_forward())<=0: break
	key(KEY_W,false)
	key(KEY_SPACE,false)
	var final_offset: Vector3=goal-actor.global_position
	final_offset.y=0
	var report: Dictionary={"hz":hz,"seconds":float(rows.size())/hz,"reached":final_offset.dot(game.camera_forward())<=.04,"max_xz":maximum_xz,"max_y":maximum_y,"max_xz_frame":max_xz_frame,"max_y_frame":max_y_frame,"end":xyz(actor.global_position-game.GARDEN_ORIGIN),"swimming":actor.swimming,"wading":actor.wading,"steps":actor.surface_traversal.steps-start_steps,"dodge_frames":dodges,"roll_frames":rolls,"dash_frames":dashes,"rows":rows}
	traces[label]=report
	print("TRACE ",label," frames=",rows.size()," maxXZ=",maximum_xz," @",max_xz_frame," maxY=",maximum_y," @",max_y_frame," end=",report.end," steps=",report.steps," dodgeFrames=",dodges)
	return report
func continuous(report: Dictionary,label: String,dodge:=false) -> void:
	var scale: float=60.0/hz
	check(report.max_xz<=(.23 if dodge else .13)*scale and report.max_y<=(.28 if dodge else .20)*scale,label+" has bounded per-tick capsule motion")
func on_land(report: Dictionary,label: String) -> void:
	check(report.reached and not report.swimming and not report.wading,label+" reaches land")
func box(at: Vector3,size: Vector3) -> void:
	var body:=StaticBody3D.new()
	var collision:=CollisionShape3D.new()
	var geometry:=BoxShape3D.new()
	geometry.size=size
	collision.shape=geometry
	body.add_child(collision)
	game.world.add_child(body)
	body.global_position=game.GARDEN_ORIGIN+at
func ramp(at: Vector3,degrees: float,run_length:=2.0) -> void:
	var rise: float=tan(deg_to_rad(degrees))*run_length
	var shape:=ConvexPolygonShape3D.new()
	shape.points=PackedVector3Array([Vector3(-1.2,-.1,0),Vector3(1.2,-.1,0),Vector3(-1.2,0,0),Vector3(1.2,0,0),Vector3(-1.2,-.1,-run_length),Vector3(1.2,-.1,-run_length),Vector3(-1.2,rise,-run_length),Vector3(1.2,rise,-run_length)])
	var body:=StaticBody3D.new()
	var collision:=CollisionShape3D.new()
	collision.shape=shape
	body.add_child(collision)
	game.world.add_child(body)
	body.global_position=game.GARDEN_ORIGIN+at
func suite() -> void:
	for x in [0.0,.75,1.5]:
		var name: String="garden_left_%.2f"%x
		var report: Dictionary=await route(name,Vector3(x,-.1,13.4),Vector2(x,8.2),0)
		on_land(report,name)
		continuous(report,name)
	for mode in ["roll","dash"]:
		var report: Dictionary=await route("left_bank_"+mode,Vector3(0,-.1,13.4),Vector2(0,8.2),0,300,mode)
		on_land(report,"physical Space "+mode+" on left bank")
		check(report[mode+"_frames"]>0 and report["dash_frames" if mode=="roll" else "roll_frames"]==0,"Space input enters the expected "+mode+" state")
		continuous(report,mode+" shore traversal",true)
	var forest: Dictionary=await route("forest_east",Vector3(70.5,-.1,0),Vector2(64,0),PI/2)
	on_land(forest,"forest east slope")
	continuous(forest,"forest east slope")
	forest=await route("forest_south",Vector3(45,-.1,25),Vector2(45,19),0)
	on_land(forest,"forest south slope")
	continuous(forest,"forest south slope")
	box(Vector3(103,9.8,0),Vector3(30,.4,18))
	box(Vector3(96,10.125,-2),Vector3(2,.25,3))
	var step: Dictionary=await route("dry_step",Vector3(96,10.05,1),Vector2(96,-1.5),0,120)
	check(step.reached and step.end[1]>10.2,"dry quarter metre step remains walkable")
	continuous(step,"dry step")
	ramp(Vector3(110,10,0),65)
	var slope: Dictionary=await route("dry_65_degree_slope",Vector3(110,10.05,1),Vector2(110,-1.6),0,180)
	check(slope.reached and slope.end[1]>13.2,"a 65 degree dry slope is walkable")
	continuous(slope,"65 degree dry slope")
	ramp(Vector3(114,10,0),67)
	slope=await route("dry_67_degree_walk",Vector3(114,10.05,1),Vector2(114,-1.6),0,180)
	check(not slope.reached,"ordinary walking rejects a slope above its 65 degree limit")
	slope=await route("dry_67_degree_roll",Vector3(114,10.05,1),Vector2(114,-1.6),0,240,"roll")
	check(slope.reached and slope.end[1]>13.4 and slope.roll_frames>0,"a 67 degree dry slope is traversable with physical Space roll")
	continuous(slope,"67 degree roll slope",true)
	ramp(Vector3(90,10,0),80)
	slope=await route("dry_80_degree_roll",Vector3(90,10.05,1),Vector2(90,-1.6),0,180,"roll")
	check(not slope.reached and slope.end[1]<11,"even Space rejects an 80 degree cliff")
	continuous(slope,"80 degree rejected cliff",true)
	box(Vector3(100,10.75,-2),Vector3(2,1.5,3))
	var wall: Dictionary=await route("dry_high_wall",Vector3(100,10.05,1),Vector2(100,-1.5),0,120)
	check(not wall.reached and wall.end[2]>-.5 and wall.end[1]<10.15,"walking cannot climb a vertical 1.5 metre wall")
	continuous(wall,"dry wall")
	wall=await route("dry_high_wall_roll",Vector3(100,10.05,1),Vector2(100,-1.5),0,120,"roll")
	check(not wall.reached and wall.end[2]>-.5 and wall.end[1]<10.15,"Space cannot bypass a vertical high wall")
	continuous(wall,"dry wall roll",true)
	box(Vector3(104,10.15,-2),Vector3(2,.3,3))
	box(Vector3(104,11.55,-1.5),Vector3(2,.3,4))
	var ceiling: Dictionary=await route("low_ceiling",Vector3(104,10.05,1),Vector2(104,-1.5),0,120)
	check(not ceiling.reached and ceiling.end[2]>-.5,"full capsule overhead clearance prevents crossing a low ceiling")
	continuous(ceiling,"low ceiling")
	box(Vector3(80,.6,7),Vector3(4,2.8,3))
	wall=await route("water_high_wall_dash",Vector3(80,-.1,10),Vector2(80,6),0,160,"dash")
	check(not wall.reached and wall.swimming and wall.end[2]>8.5,"shore assistance and dash cannot scale a high wall in water")
	continuous(wall,"water wall dash",true)
func run() -> void:
	baseline="--baseline" in OS.get_cmdline_user_args()
	smoke="--smoke" in OS.get_cmdline_user_args()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--hz="): hz=int(argument.trim_prefix("--hz="))
	Engine.physics_ticks_per_second=hz
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(25)
	actor=game.player
	game.sound.muted=true
	game.combat_world.encounters_started=true
	for enemy in game.combat_world.enemies: enemy.set_physics_process(false)
	var main_route: Dictionary=await route("garden_stairs",Vector3(2.5,-.1,13.4),Vector2(2.5,8.2),0)
	if not baseline:
		check(not main_route.swimming and main_route.end[1]>1.6,"garden stairs leave water through actual W input")
		continuous(main_route,"garden shoreline at %d Hz"%hz)
		if not smoke: await suite()
	var log_path: String="res://docs/traversal/old_motion_baseline.json" if baseline else "res://docs/traversal/motion_regression_%dhz.json"%hz
	var file:=FileAccess.open(log_path,FileAccess.WRITE)
	file.store_string(JSON.stringify(traces,"\t"))
	file.close()
	print("SURFACE_MOTION_RESULT %d/%d passed"%[checks-failures.size(),checks])
	game.queue_free()
	await ticks(3)
	quit(0 if failures.is_empty() else 1)
