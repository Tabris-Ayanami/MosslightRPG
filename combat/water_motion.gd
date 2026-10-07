extends RefCounted
## One stroke clock for both skeletal/procedural visuals and water contacts.
## Physical buoyancy, collisions and combat state stay in CombatActor.
var active := false
var moving := false
var blend := 0.0
var travel_blend := 0.0
var cycles := 0.0
var burst := false
var burst_progress := 0.0
var phase: float:
	get: return fposmod(cycles,1.0)
var stroke_id: int:
	get: return floori(cycles-.32)

func tick(actor: Node, delta: float, locomotion: bool, state: String, climbing: bool) -> void:
	# Portrait and preview parents have no swimming state.
	var combat: Variant=actor.get("combat") if is_instance_valid(actor) else null
	var water_dodge: bool=state=="DODGE" and combat!=null and (actor.get("swimming")==true or combat.dodge_in_water)
	active=not climbing and (is_instance_valid(actor) and actor.get("swimming")==true and state in ["NORMAL","MOVE"] or water_dodge)
	burst=active and water_dodge
	burst_progress=clampf(combat.dodge_time/.42,0,1) if burst else 0.0
	moving=active and (locomotion or burst)
	blend=move_toward(blend,1.0 if active else 0.0,maxf(0,delta)*5.5)
	travel_blend=move_toward(travel_blend,1.0 if moving else 0.0,maxf(0,delta)*3.8)
	if active: cycles+=maxf(0,delta)*lerpf(.48,.86,travel_blend)

func body_transform() -> Transform3D:
	var lean := lerpf(.24,1.10,travel_blend)*blend
	if burst: lean=lerpf(lean,1.24,smoothstep(0,.12,burst_progress)*(1-smoothstep(.72,1,burst_progress)))
	var bob := sin(phase*TAU)*lerpf(.025,.045,travel_blend)*blend
	# Lean about the pelvis instead of rotating the feet through the water.
	return Transform3D(Basis.from_euler(Vector3(-lean,0,0)),Vector3(0,(.90*(1-cos(lean))-.18*blend)+bob,.90*sin(lean)))

func hand_goal(left: bool) -> Vector3:
	var side := -1.0 if left else 1.0
	if burst:
		var pull := smoothstep(.14,.58,burst_progress)
		var recover := smoothstep(.65,1.0,burst_progress)
		return Vector3(side*lerpf(lerpf(.12,.46,pull),.17,recover),lerpf(1.22,1.10,pull),lerpf(lerpf(-.78,.26,pull),-.66,recover))
	var pull := smoothstep(.12,.55,phase)
	var recover := smoothstep(.58,.97,phase)
	var spread := lerpf(.17,.62,pull)
	spread=lerpf(spread,.17,recover)
	var reach := lerpf(-.66,.12,pull)
	reach=lerpf(reach,-.66,recover)
	var tread := Vector3(side*(.42+sin(phase*TAU)*.07),1.00,-.18+cos(phase*TAU)*.10)
	return tread.lerp(Vector3(side*spread,1.15+sin(phase*TAU)*.04,reach),travel_blend)

func foot_goal(left: bool) -> Vector3:
	var side := -1.0 if left else 1.0
	if burst:
		var flutter := sin(burst_progress*TAU*2+(0.0 if left else PI))
		return Vector3(side*.14,.12+maxf(0,flutter)*.18,.08+flutter*.22)
	var kick := sin((phase-.34)*TAU)
	return Vector3(side*(.16+maxf(0,kick)*.11*travel_blend),.08+maxf(0,-kick)*.14,.08+kick*.12)

func can_pose(state: String) -> bool:
	return blend>.001 and (state in ["NORMAL","MOVE"] or burst)

func animation_name() -> String:
	return "swim_dash" if burst else ("swim_breaststroke" if moving else "swim_tread")
