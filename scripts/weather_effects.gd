extends Node3D
## Actual world-space precipitation; the pixel viewport renders these with the scene.
var rain: GPUParticles3D
var rain_impacts: GPUParticles3D
var snow: GPUParticles3D
var rain_process: ParticleProcessMaterial
var snow_process: ParticleProcessMaterial
var collision_field: GPUParticlesCollisionHeightField3D
var bolt: MeshInstance3D
var lanterns: Array[OmniLight3D] = []
var lantern_material: StandardMaterial3D
var game: Node
var collider_center := Vector3(INF,0,0)

func setup(owner_game: Node) -> void:
	game = owner_game
	rain = _particles(false)
	snow = _particles(true)
	rain_process = rain.process_material
	snow_process = snow.process_material
	rain_impacts = _rain_impacts()
	rain.sub_emitter = rain.get_path_to(rain_impacts)
	rain_process.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_AT_COLLISION
	rain_process.sub_emitter_amount_at_collision = 1
	rain_process.sub_emitter_keep_velocity = false
	collision_field = GPUParticlesCollisionHeightField3D.new()
	collision_field.name = "WeatherRoofAndGroundCollision"
	collision_field.size = Vector3(128,48,144)
	collision_field.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_512
	collision_field.heightfield_mask = 1
	collision_field.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_WHEN_MOVED
	add_child(collision_field)
	collision_field.visible = false
	bolt = MeshInstance3D.new()
	bolt.name = "LightningBolt"
	bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bolt.layers = 8
	var light_material := StandardMaterial3D.new()
	light_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	light_material.albedo_color = Color("dbeaff")
	light_material.emission_enabled = true
	light_material.emission = Color("bfd8ff")
	light_material.emission_energy_multiplier = 1.8
	bolt.material_override = light_material
	bolt.visible = false
	add_child(bolt)
	_create_lanterns()

func _particles(is_snow: bool) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "Snow" if is_snow else "Rain"
	particles.emitting = false
	particles.amount = 5000 if is_snow else 12000
	particles.amount_ratio = 0
	particles.lifetime = 12.0 if is_snow else 2.3
	particles.preprocess = 0
	particles.fixed_fps = 30
	particles.local_coords = false
	particles.visibility_aabb = AABB(Vector3(-80,-40,-80),Vector3(160,90,160))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.layers = 8 # Exclude precipitation from the planar reflection camera.
	particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD if is_snow else GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(52,14,60)
	process.direction = Vector3.DOWN
	process.spread = 9 if is_snow else 2
	process.initial_velocity_min = 1.4 if is_snow else 19.0
	process.initial_velocity_max = 2.6 if is_snow else 25.0
	process.gravity = Vector3(0,-.10 if is_snow else -7.0,0)
	process.scale_min = .65
	process.scale_max = 1.35
	process.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	if is_snow:
		process.turbulence_enabled = true
		process.turbulence_noise_strength = .65
		process.turbulence_noise_scale = 3.0
		process.turbulence_influence_min = .12
		process.turbulence_influence_max = .3
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0,.07,.86,1])
	gradient.colors = PackedColorArray([Color(1,1,1,0),Color.WHITE,Color.WHITE,Color(1,1,1,0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process.color_ramp = ramp
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(.13,.13) if is_snow else Vector2(.045,.66)
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/weather_precipitation.gdshader")
	material.set_shader_parameter("snowflake",is_snow)
	material.render_priority = 12
	quad.material = material
	particles.draw_pass_1 = quad
	add_child(particles)
	return particles

func _rain_impacts() -> GPUParticles3D:
	# Collision sub-emission puts each splash on the actual ground or roof.
	# The water shader supplies lake ripples, where the height field sees the bed.
	var particles := GPUParticles3D.new()
	particles.name = "RainGroundImpacts"
	particles.emitting = false
	particles.amount = 3072
	particles.lifetime = .42
	particles.fixed_fps = 30
	particles.local_coords = false
	particles.visibility_aabb = AABB(Vector3(-80,-40,-80),Vector3(160,90,160))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.layers = 8
	var process := ParticleProcessMaterial.new()
	process.gravity = Vector3.ZERO
	process.initial_velocity_min = 0.0
	process.initial_velocity_max = 0.0
	process.scale_min = .7
	process.scale_max = 1.2
	particles.process_material = process
	var plane := PlaneMesh.new()
	plane.size = Vector2(.64,.64)
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/rain_impact.gdshader")
	material.render_priority = 13
	plane.material = material
	particles.draw_pass_1 = plane
	add_child(particles)
	return particles

func update_effects(rain_amount: float, snow_amount: float, wind: Vector2, strength: float, darkness: float, flash: float) -> void:
	# Keep emission near the view; existing particles stay in world coordinates.
	var center: Vector3 = game.smooth_target
	center.y = 16.0
	rain.global_position = center
	rain_impacts.global_position = center
	snow.global_position = center
	rain.amount_ratio = rain_amount
	snow.amount_ratio = snow_amount
	rain.emitting = rain_amount > .005
	snow.emitting = snow_amount > .005
	rain.visible = rain_amount > .001
	rain_impacts.visible = rain_amount > .001
	snow.visible = snow_amount > .001
	rain_process.direction = Vector3(wind.x*strength*.11,-1,wind.y*strength*.11).normalized()
	rain_process.gravity = Vector3(wind.x*strength*.45,-7,wind.y*strength*.45)
	snow_process.gravity = Vector3(wind.x*strength*.13,-.10,wind.y*strength*.13)
	var next: Vector3 = Vector3(snappedf(center.x,8),7,snappedf(center.z,8))
	if next != collider_center:
		collider_center = next
		collision_field.global_position = next
	collision_field.visible = rain.emitting or snow.emitting
	bolt.visible = flash > .12
	for lantern in lanterns:
		lantern.light_energy = darkness*1.35
		lantern.visible = darkness > .02
	lantern_material.emission_energy_multiplier = darkness*3.0

func show_lightning(at: Vector3, rng: RandomNumberGenerator) -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var p := at+Vector3(0,23,0)
	for i in range(10):
		var next := at+Vector3(rng.randf_range(-.85,.85),23.0-(i+1)*2.3,rng.randf_range(-.4,.4))
		_bolt_segment(mesh,p,next,.06 if i < 6 else .038)
		if i == 3 or i == 6:
			_bolt_segment(mesh,p,p+Vector3(rng.randf_range(-3,3),-3.0,1),.022)
		p = next
	mesh.surface_end()
	bolt.mesh = mesh
	bolt.visible = true

func _bolt_segment(mesh: ImmediateMesh, a: Vector3, b: Vector3, width: float) -> void:
	var side: Vector3 = game.camera.global_basis.x*width
	for p: Vector3 in [a-side,a+side,b+side,a-side,b+side,b-side]:
		mesh.surface_add_vertex(p)

func _create_lanterns() -> void:
	lantern_material = StandardMaterial3D.new()
	lantern_material.albedo_color = Color("e8c28a")
	lantern_material.emission_enabled = true
	lantern_material.emission = Color("ffc576")
	lantern_material.emission_energy_multiplier = 0
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("4d4637")
	# Lighting belongs to the village; the garden and forest retain moonlight only.
	for p: Vector3 in [Vector3(3.5,2.2,-28),Vector3(-5,2.2,-34),Vector3(5,2.2,-46),Vector3(-3,2.2,-50)]:
		var post := MeshInstance3D.new()
		var pole := BoxMesh.new()
		pole.size = Vector3(.10,1.65,.10)
		post.mesh = pole
		post.material_override = wood
		add_child(post)
		post.global_position = game.GARDEN_ORIGIN+p+Vector3(0,.825,0)
		var lamp := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(.26,.33,.26)
		lamp.mesh = box
		lamp.material_override = lantern_material
		post.add_child(lamp)
		lamp.position.y = .94
		var cap := MeshInstance3D.new()
		var roof := CylinderMesh.new()
		roof.top_radius = 0
		roof.bottom_radius = .24
		roof.height = .18
		roof.radial_segments = 4
		cap.mesh = roof
		cap.material_override = wood
		post.add_child(cap)
		cap.position.y = 1.18
		var light := OmniLight3D.new()
		light.name = "DuskLantern"
		light.light_color = Color("ffbd72")
		light.omni_range = 5.8
		light.omni_attenuation = 1.8
		light.light_energy = 0
		post.add_child(light)
		light.position.y = 1.0
		lanterns.append(light)
