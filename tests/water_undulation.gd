extends SceneTree
## GPU/CPU agreement, wave-aware aiming, buoyancy, and world-anchored zoom.
const Surface = preload("res://scripts/water_surface.gd")
var game: Node
var checks := 0
var failed := 0
var probe: SubViewport
var probe_camera: Camera3D

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok: failed+=1
	print("PASS " if ok else "FAIL ",label)

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func probe_image() -> Image:
	await ticks(4)
	await RenderingServer.frame_post_draw
	return probe.get_texture().get_image()

func agreement(image: Image) -> Vector2:
	var errors := Vector2.ZERO
	for y in range(12,128,23):
		for x in range(12,128,23):
			var ray: Vector3=probe_camera.project_ray_origin(Vector2(x+.5,y+.5))
			var expected: Vector3=Surface.field(Vector2(ray.x,ray.z),game.weather.clock,game.weather.wind_strength)
			var color: Color=image.get_pixel(x,y).srgb_to_linear()
			var actual := (Vector3(color.r,color.g,color.b)-Vector3.ONE*.5)/Vector3(4,3,3)
			errors.x=maxf(errors.x,absf(actual.x-expected.x))
			errors.y=maxf(errors.y,Vector2(actual.y-expected.y,actual.z-expected.z).length())
	return errors

func setup_probe() -> void:
	probe=SubViewport.new()
	probe.size=Vector2i(128,128)
	probe.world_3d=World3D.new()
	probe.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	root.add_child(probe)
	probe_camera=Camera3D.new()
	probe_camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	probe_camera.size=12
	probe.add_child(probe_camera)
	probe_camera.look_at_from_position(Vector3(0,10,0),Vector3.ZERO,Vector3.FORWARD)
	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size=Vector2(40,40)
	mesh.mesh=plane
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code="""shader_type spatial;
render_mode unshaded, fog_disabled;
#include "res://shaders/reference_common.gdshaderinc"
#include "res://shaders/water_flow.gdshaderinc"
varying vec3 wp;
void vertex() { wp=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz; }
void fragment() { ALBEDO=vec3(.5)+water_long_waves(wp.xz)*vec3(4.0,3.0,3.0); }
"""
	material.shader=shader
	mesh.material_override=material
	probe.add_child(mesh)

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Water undulation acceptance requires a real GPU.")
		quit(1)
		return
	root.size=Vector2i(1280,720)
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.sound.muted=true
	game.hud.hide()
	game.combat_world.encounters_started=true
	game.set_process(false)
	game.weather.set_process(false)
	game.water_interactions.set_process(false)
	game.weather.set_weather(0,true)
	game.weather.set_wind(0,true)
	for actor: Node in game.combat_world.units(): actor.set_physics_process(false)
	setup_probe()
	game.weather.clock=12
	game.weather._apply_environment()
	var first := await probe_image()
	var errors := agreement(first)
	check(errors.x<.002 and errors.y<.004,"GPU wave height / slope match buoyancy: %.5f m / %.5f"%[errors.x,errors.y])
	game.weather.clock=14.6
	game.weather._apply_environment()
	var moved := await probe_image()
	check(first.get_data()!=moved.get_data(),"wave peaks propagate while the camera stands still")
	game.weather.clock=12
	game.weather._apply_environment()
	var restored := await probe_image()
	check(first.get_data()==restored.get_data(),"restoring the wave clock restores the exact GPU field")
	probe_camera.size=24
	errors=agreement(await probe_image())
	check(errors.x<.002 and errors.y<.004,"zoom preserves world-space height and phase")
	game.weather.set_wind(2,true)
	errors=agreement(await probe_image())
	check(errors.x<.002 and errors.y<.004,"wind changes keep CPU and GPU heights synchronized")
	var peak := 0.0
	for z in range(-20,21):
		for x in range(-20,21): peak=maxf(peak,absf(Surface.field(Vector2(x,z),12,7).x))
	check(peak<.070,"calm-style long waves remain below seven centimetres even in strong wind")
	var lake: MeshInstance3D=game.reference_map.get_node("Lake")
	check(lake.mesh.subdivide_width>=255 and lake.mesh.subdivide_depth>=255,"production lake has enough vertices for geometric undulation")
	var origin: Vector3=game.GARDEN_ORIGIN+Vector3(3,9,12)
	var direction := Vector3(.2,-1,.11).normalized()
	var point: Variant=game.water_ray_hit(origin,direction)
	check(point is Vector3 and absf(point.y-game.water_surface_at(point))<.0001,"aim ray hits the animated wave surface")
	check(game.water_ray_hit(origin,Vector3.RIGHT)==null and game.water_ray_hit(origin,Vector3.UP)==null,"horizontal and away-facing rays do not report water hits")
	check(not is_finite(game.water_surface_at(lake.global_position+Vector3(150,0,0))),"animated waves do not create water outside the lake")
	game.weather.set_wind(0,true)
	game.player.restore(game.GARDEN_ORIGIN+Vector3(-3,-.1,16))
	game.player.set_physics_process(true)
	await ticks(40)
	var hp: float=game.player.resources.current("HP")
	var buoyancy_error := 0.0
	for i in range(90):
		game.weather.clock+=1.0/30.0
		game.weather._apply_environment()
		await ticks(1)
		buoyancy_error=maxf(buoyancy_error,absf(game.player.global_position.y-(game.water_surface_at(game.player.global_position)-.70)))
	check(game.player.swimming and buoyancy_error<.04,"swimmer follows rising and falling waves: %.4f m error"%buoyancy_error)
	check(game.player.resources.current("HP")==hp,"surface undulation preserves swimmer health")
	print("WATER_UNDULATION_RESULT ",checks-failed,"/",checks)
	game.queue_free()
	probe.queue_free()
	await ticks(5)
	quit(1 if failed else 0)
