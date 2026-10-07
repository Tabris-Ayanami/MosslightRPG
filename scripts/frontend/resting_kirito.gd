extends Node3D
## Deterministic title-only performance, body baked at 60 Hz and cloth at 30 Hz.
## interpolate rotations at render rate, so low FPS and reverse seeking are stable.
const VISUAL=preload("res://scripts/kirito_visual.gd")
const PERFORMANCE=preload("res://assets/ui/title/title-story.res")
const STORY=preload("res://scripts/frontend/title_story.gd")
const SWORD=preload("res://scripts/frontend/title_sword.gd")
var hero: Node3D
var skeleton: Skeleton3D
var performer: AnimationPlayer
var rise := 0.0
var contact_error := 0.0
var chain_errors := {}
var performance_time := 0.0
var cloth: MeshInstance3D
var cloth_materials: Array[ShaderMaterial]=[]
var sword: Node3D
var sword_attached := false
var back_grip: Vector3
var back_tip: Vector3

func _ready() -> void:
	hero=VISUAL.new()
	hero.name="PerformanceHero"
	add_child(hero)
	hero.scale=Vector3.ONE*1.78
	skeleton=hero.skeleton
	hero.animator.stop()
	hero.animator.active=false
	performer=AnimationPlayer.new()
	performer.name="BakedTitlePerformance"
	add_child(performer)
	var library := AnimationLibrary.new()
	library.add_animation("rise",PERFORMANCE)
	performer.add_animation_library("",library)
	performer.play("rise")
	performer.pause()
	_build_cloth()
	sword=SWORD.new()
	sword.name="TravellersSword"
	add_child(sword)
	back_grip=PERFORMANCE.get_meta("back_grip")
	back_tip=PERFORMANCE.get_meta("back_tip")
	apply_pose(0)

func _build_cloth() -> void:
	var garment: MeshInstance3D=hero.find_child("polySurface84",true,false)
	cloth=MeshInstance3D.new()
	cloth.name="SimulatedCoatSurface"
	cloth.mesh=load("res://assets/ui/title/cloth-shell.res")
	cloth.custom_aabb=cloth.mesh.get_aabb()
	for surface in range(garment.mesh.get_surface_count()):
		var source: ShaderMaterial=garment.get_surface_override_material(surface)
		var mat := ShaderMaterial.new()
		mat.shader=preload("res://shaders/frontend/title_cloth.gdshader")
		mat.set_shader_parameter("albedo_texture",source.get_shader_parameter("albedo_texture"))
		mat.set_shader_parameter("tint",source.get_shader_parameter("tint"))
		mat.set_shader_parameter("position_cache",load("res://assets/ui/title/cloth-positions.res"))
		mat.set_shader_parameter("normal_cache",load("res://assets/ui/title/cloth-normals.res"))
		mat.set_shader_parameter("frame_count",roundi(STORY.END*30)+1)
		cloth.set_surface_override_material(surface,mat)
		cloth_materials.append(mat)
	garment.mesh=load("res://assets/ui/title/upper-garment.res")
	add_child(cloth)

func _chest_frame() -> Transform3D:
	return global_transform.affine_inverse()*skeleton.global_transform*skeleton.get_bone_global_pose(skeleton.find_bone("J_Bip_C_Chest"))

func _update_sword() -> void:
	var grip := STORY.GROUND_GRIP
	var ground_direction := Vector3(.28,0,.96).normalized()
	var carry_direction := Vector3(.25,-1,.35).normalized()
	var direction := ground_direction
	var seconds := performance_time
	sword_attached=seconds>=STORY.ATTACH_TIME
	if sword_attached:
		var chest := _chest_frame()
		grip=chest*back_grip
		direction=(chest*back_tip-grip).normalized()
	elif seconds>=STORY.PICKUP_TIME:
		grip=to_local(skeleton.to_global(skeleton.get_bone_global_pose(skeleton.find_bone("L_Hand")).origin))
		if seconds<=STORY.RISE_END:
			direction=ground_direction.slerp(carry_direction,smoothstep(.70,1.45,STORY.getup_time(seconds)))
		else:
			var p := STORY.prepare(seconds)
			if p<.40:
				direction=carry_direction.slerp(Vector3.UP,smoothstep(0,.40,p))
			elif p<.51:
				direction=Vector3.UP.slerp(Vector3(0,.25,-1).normalized(),smoothstep(.40,.51,p))
			else:
				direction=Vector3(0,.25,-1).normalized().slerp((STORY.BACK_TIP-STORY.BACK_GRIP).normalized(),smoothstep(.51,.61,p))
			direction=Basis(Vector3.UP,STORY.yaw_at(seconds))*direction
	if not sword_attached:
		# Clamp the blade's actual tip, retaining a unit direction afterwards.
		var minimum_y := clampf((.065-grip.y)/1.79,-1,1)
		if direction.y<minimum_y:
			var horizontal := Vector3(direction.x,0,direction.z).normalized()
			if horizontal.length_squared()<.1: horizontal=ground_direction
			direction=horizontal*sqrt(1-minimum_y*minimum_y)+Vector3.UP*minimum_y
	sword.transform=Transform3D(Basis(Quaternion(Vector3.UP,direction)),grip+direction*.09)

func apply_pose(progress: float) -> void:
	rise=clampf(progress,0,1)
	apply_time(rise*STORY.RISE_END)

func apply_time(seconds: float) -> void:
	performance_time=clampf(seconds,0,STORY.END)
	rise=clampf(performance_time/STORY.RISE_END,0,1)
	if not is_instance_valid(performer): return
	performer.seek(performance_time,true)
	for mat in cloth_materials: mat.set_shader_parameter("frame",performance_time*30)
	if is_instance_valid(sword): _update_sword()
	contact_error=0
	var goals: Dictionary=PERFORMANCE.get_meta("contact_targets")
	var sample_frame := performance_time*float(PERFORMANCE.get_meta("sample_hz"))
	for name: String in goals:
		var points: PackedVector3Array=goals[name]
		var i := mini(floori(sample_frame),points.size()-2)
		var target := points[i].lerp(points[i+1],sample_frame-i)
		var index := skeleton.find_bone(name)
		var position := to_local(skeleton.to_global(skeleton.get_bone_global_pose(index).origin))
		var error := position.distance_to(target)
		chain_errors[name]=error
		contact_error=maxf(contact_error,error)
