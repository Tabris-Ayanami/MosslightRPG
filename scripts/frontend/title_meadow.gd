extends Node3D
## A lightweight, live 3D menu set with the same foliage vocabulary as the game.
const W = preload("res://scripts/woodland_art.gd")
const A = preload("res://scripts/reference_art.gd")
const RESTING = preload("res://scripts/frontend/resting_kirito.gd")
const FLIGHT = preload("res://scripts/frontend/sky_flight.gd")
var camera: Camera3D
var sleeper: Node3D
var tree: Node3D
var camera_home := Vector3(0,20,0)
var sky_material: ShaderMaterial
var journey := 0.0
var time := 0.0
var ascent := 0.0

func _ready() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode=Environment.BG_SKY
	var sky := Sky.new()
	sky.process_mode=Sky.PROCESS_MODE_REALTIME
	sky.radiance_size=Sky.RADIANCE_SIZE_256
	sky_material=ShaderMaterial.new()
	sky_material.shader=preload("res://shaders/frontend/sky.gdshader")
	sky.sky_material=sky_material
	env.sky=sky
	env.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color=Color("b9d3b3")
	env.ambient_light_energy=.25
	env.tonemap_mode=Environment.TONE_MAPPER_LINEAR
	environment.environment=env
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.name="AfternoonSun"
	sun.rotation_degrees=Vector3(-43,119,0)
	sun.light_color=Color("fff4ce")
	sun.light_energy=1.4
	sun.light_cull_mask=3
	sun.layers=3
	sun.shadow_enabled=true
	sun.directional_shadow_max_distance=100
	sun.directional_shadow_mode=DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.shadow_bias=.02
	add_child(sun)
	var ground := MeshInstance3D.new()
	ground.name="SunlitMeadow"
	var plane := PlaneMesh.new()
	plane.size=Vector2(1800,1800)
	ground.mesh=plane
	var soil := ShaderMaterial.new()
	soil.shader=preload("res://shaders/frontend/meadow.gdshader")
	ground.material_override=soil
	add_child(ground)
	# A second ground layer records only sunlight/shadows for the screen typography.
	# It shares the world, sun, animated leaf casters and camera with the main view.
	var shadow_ground := MeshInstance3D.new()
	shadow_ground.name="TypographyShadowReceiver"
	shadow_ground.mesh=plane
	shadow_ground.layers=2
	shadow_ground.position.y=.002
	shadow_ground.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shadow_mat := ShaderMaterial.new()
	shadow_mat.shader=preload("res://shaders/frontend/shadow_mask.gdshader")
	shadow_ground.material_override=shadow_mat
	add_child(shadow_ground)
	tree=W.tree(self,Vector3(8.5,0,-6.4),10.4,1208,true,0)
	tree.name="ShelteringTree"
	tree.get_node("TreeDecorations").visible=false
	for child in tree.get_children():
		if child is GeometryInstance3D: child.layers=3
	_grass()
	var rng := RandomNumberGenerator.new()
	rng.seed=87041
	for i in range(33):
		var at := Vector3(rng.randf_range(-14,15),.015,rng.randf_range(-10,13))
		# Intentional quiet space below the typography; flowers gather by the resting place.
		if at.x<-1 and at.z>0 and i%3!=0: continue
		W.flowers(self,at,850+i,[0,0,1,2,3][i%5],rng.randf_range(.4,1.15),rng.randi_range(5,12))
	W.flowers(self,Vector3(3.8,.01,3.1),900,0,.7,14)
	W.flowers(self,Vector3(5.4,.01,1.5),901,1,.7,8)
	W.flowers(self,Vector3(2.05,.03,.15),902,0,.65,14)
	W.flowers(self,Vector3(4.25,.03,2.1),903,3,.48,8)
	# Title cards face the vertical camera as well as the low horizon camera.
	for child in get_children():
		if child is MultiMeshInstance3D and child.name!="BreezeGrass":
			var flower_mesh: Mesh=child.multimesh.mesh
			if flower_mesh is QuadMesh:
				var flower_mat: ShaderMaterial=flower_mesh.material.duplicate()
				flower_mat.shader=preload("res://shaders/frontend/title_flower.gdshader")
				flower_mesh.material=flower_mat
	sleeper=RESTING.new()
	sleeper.name="RestingKirito"
	sleeper.position=Vector3(3.15,0,.8)
	add_child(sleeper)
	# The actor owns one sword prop throughout pickup, sheathing and walking.
	camera=Camera3D.new()
	camera.name="MeadowCamera"
	camera.projection=Camera3D.PROJECTION_PERSPECTIVE
	camera.fov=40
	camera.near=.05
	camera.far=2000
	camera.cull_mask=1
	add_child(camera)
	camera.current=true
	set_journey(0)

func _grass() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed=63114
	var grass := MultiMeshInstance3D.new()
	grass.name="BreezeGrass"
	grass.layers=3
	grass.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format=MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size=Vector2(.6,.62)
	quad.center_offset.y=.31
	var mat := ShaderMaterial.new()
	mat.shader=preload("res://shaders/frontend/title_grass.gdshader")
	mat.set_shader_parameter("leaf_texture",preload("res://assets/foliage/grassleaf.png"))
	mat.set_shader_parameter("meadow",Color("779348"))
	mat.set_shader_parameter("meadow_high",Color("a9bd59"))
	quad.material=mat
	mm.mesh=quad
	var transforms: Array[Transform3D]=[]
	for i in range(28000):
		var p := Vector3(rng.randf_range(-32,32),.015,rng.randf_range(-30,30)) if i<15500 else Vector3(rng.randf_range(-90,90),.015,rng.randf_range(-90,90))
		if Vector2(p.x,p.z).length()>87: continue
		var dist := Vector2((p.x-3.15)*1.3,(p.z-.8)*.55).length()
		if dist<1.10: continue
		var s := rng.randf_range(.42,.82)
		transforms.append(Transform3D(Basis.IDENTITY.scaled(Vector3(s,s,1)),p))
	mm.instance_count=transforms.size()
	for i in range(transforms.size()): mm.set_instance_transform(i,transforms[i])
	grass.multimesh=mm
	add_child(grass)

func set_journey(value: float) -> void:
	journey=clampf(value,0,1)
	# Keep yaw and pitch separate: slerping the top-down and sky orientations
	# creates an unintended Dutch roll halfway through the camera withdrawal.
	# One continuous camera ease starts with the get-up, instead of waiting for it.
	var motion := smoothstep(0,1,journey)
	var heading := atan2(-FLIGHT.FORWARD.x,-FLIGHT.FORWARD.z)*motion
	var yaw := Basis(Vector3.UP,heading)
	var distance := 78*motion
	var focus := Vector3.ZERO.lerp(FLIGHT.SUBJECT,motion)+FLIGHT.RIGHT*3.5*motion
	camera.position=focus+yaw.z*distance
	camera.position.y=lerpf(20,1,smoothstep(.25,1,motion))
	var sky_height := (1+78*tan(deg_to_rad(18)))*smoothstep(.42,1,motion)
	var pitch := atan2(sky_height-camera.position.y,distance)
	camera.basis=yaw*Basis(Vector3.RIGHT,pitch)
	camera.fov=lerpf(40,52,motion)
	if journey>=1: camera.transform=FLIGHT.camera_pose(0)
	# Each authored pose track already owns its easing. Do not ease the clock again.
	sleeper.apply_time(journey*FLIGHT.STORY.CHOICE_TIME)

func set_ascent(value: float) -> void:
	ascent=clampf(value,0,1)
	camera.transform=FLIGHT.camera_pose(ascent)
	camera.fov=lerpf(52,60,smoothstep(0,1,ascent))
	sleeper.apply_time(FLIGHT.STORY.CHOICE_TIME+ascent*FLIGHT.STORY.DEPARTURE_TIME)

func _process(delta: float) -> void:
	time+=delta
