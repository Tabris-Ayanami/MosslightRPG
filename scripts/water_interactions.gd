extends Node3D
## Surface waves are composited by the lake shader. Only airborne droplets use
## geometry, so a bridge/bank can occlude every part of a contact normally.
const MAX_EVENTS := 24
const MAX_DROPLETS := 64
var game: Node
var events: Array[Dictionary]=[]
var droplets: Array[Dictionary]=[]
var actors: Dictionary={}
var rings_emitted := 0
var splashes_emitted := 0
var _sequence := 0
var _mesh: MultiMeshInstance3D

func setup(host: Node) -> void:
	game=host
	name="WaterInteractions"
	_mesh=MultiMeshInstance3D.new()
	_mesh.name="ContactDroplets"
	_mesh.layers=2
	_mesh.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := QuadMesh.new()
	mesh.size=Vector2.ONE*.055
	var material := ShaderMaterial.new()
	material.shader=preload("res://shaders/water_droplet.gdshader")
	mesh.material=material
	var multi := MultiMesh.new()
	multi.transform_format=MultiMesh.TRANSFORM_3D
	multi.use_custom_data=true
	multi.mesh=mesh
	multi.instance_count=MAX_DROPLETS
	multi.visible_instance_count=0
	_mesh.multimesh=multi
	_mesh.custom_aabb=AABB(Vector3(-200,-8,-200),Vector3(400,30,400))
	add_child(_mesh)
	_upload()

func _process(delta: float) -> void:
	if not is_instance_valid(game) or game.paused: return
	advance(delta)

func advance(delta: float) -> void:
	for i in range(events.size()-1,-1,-1):
		events[i].age+=delta
		if events[i].age>=1.85: events.remove_at(i)
	for i in range(droplets.size()-1,-1,-1):
		droplets[i].age+=delta
		if droplets[i].age>=droplets[i].life: droplets.remove_at(i)
	var seen: Dictionary={}
	for actor: Node in game.combat_world.units():
		var id := actor.get_instance_id()
		seen[id]=true
		_track(actor,delta)
	for id in actors.keys():
		if not seen.has(id): actors.erase(id)
	_upload()

func _track(actor: Node, delta: float) -> void:
	var at: Vector3=actor.global_position
	var surface: float=game.water_surface_at(at)
	var wet: bool=is_finite(surface) and actor.wading and not actor.dead and actor.is_visible_in_tree()
	var previous: Dictionary=actors.get(actor.get_instance_id(),{})
	var stride := float(previous.get("stride",0))
	var direction: Vector3=actor.facing
	var stroke := int(actor.animation.water_motion.stroke_id)
	var burst: bool=actor.animation.water_motion.burst
	if not previous.is_empty():
		var distance: float=Vector2(at.x-previous.at.x,at.z-previous.at.z).length()
		# Loads/teleports do not leave trails across the entire map.
		if distance<3.5 and at.distance_squared_to(game.camera.global_position)<10000:
			var speed := distance/maxf(delta,.001)
			if distance>.002: direction=(at-previous.at)*Vector3(1,0,1)
			if wet and not previous.wet:
				contact(Vector3(at.x,surface,at.z),direction,0,clampf(.6+speed*.12,.6,1.3),12)
			elif wet and actor.swimming and burst:
				if not previous.get("burst",false):
					contact(Vector3(at.x,surface,at.z),direction,4,.90,10)
				stride+=distance
				if stride>.34:
					stride=fmod(stride,.34)
					var wake: Vector3=at-direction.normalized()*.25
					contact(Vector3(wake.x,surface,wake.z),direction,4,.65,2)
			elif wet and actor.swimming and actor.animation.water_motion.active and stroke!=previous.stroke:
				var kind := 1 if speed>.10 else 2
				for hand: Vector3 in actor.animation.water_contact_points():
					contact(Vector3(hand.x,surface,hand.z),direction,kind,.65 if kind==1 else .32,4 if kind==1 else 0)
			elif wet and not actor.swimming and distance>.002:
				stride+=distance
				if stride>.56:
					stride=fmod(stride,.56)
					contact(Vector3(at.x,surface,at.z),direction,3,.38,3)
			elif not wet and previous.wet and is_finite(surface):
				contact(Vector3(previous.at.x,surface,previous.at.z),direction,3,.35,4)
	actors[actor.get_instance_id()]={"at":at,"wet":wet,"stroke":stroke,"stride":stride,"burst":burst}

func contact(at: Vector3, direction: Vector3, kind: int, energy: float, splash_count := 0) -> void:
	_sequence+=1
	var forward := Vector2(direction.x,direction.z).normalized()
	if forward.length_squared()<.01: forward=Vector2(0,-1)
	if events.size()>=MAX_EVENTS: events.pop_front()
	events.append({"at":at,"age":0.0,"energy":energy,"direction":forward,"kind":kind,"seed":fposmod(_sequence*.61803398875,1.0)})
	rings_emitted+=1
	if splash_count>0:
		splashes_emitted+=1
		for i in range(splash_count):
			if droplets.size()>=MAX_DROPLETS: droplets.pop_front()
			var angle := TAU*fposmod(float(i)*.61803398875+_sequence*.137,1.0)
			var strength := .45+fposmod(float(i)*.754877666+_sequence*.273,1.0)*.55
			droplets.append({"at":at+Vector3(0,.025,0),"velocity":Vector3(cos(angle)*strength,1.0+strength*energy,sin(angle)*strength),"age":0.0,"life":.32+strength*.16})

func clear() -> void:
	events.clear()
	droplets.clear()
	actors.clear()
	_upload()

func _upload() -> void:
	if not is_instance_valid(game) or not is_instance_valid(_mesh): return
	var data := PackedVector4Array()
	var shapes := PackedVector4Array()
	data.resize(MAX_EVENTS)
	shapes.resize(MAX_EVENTS)
	for i in range(events.size()):
		var e: Dictionary=events[i]
		data[i]=Vector4(e.at.x,e.at.z,e.age,e.energy)
		shapes[i]=Vector4(e.direction.x,e.direction.y,e.kind,e.seed)
	game.water_material.set_shader_parameter("water_event_count",events.size())
	game.water_material.set_shader_parameter("water_events",data)
	game.water_material.set_shader_parameter("water_event_shapes",shapes)
	game.water_material.set_shader_parameter("sun_direction",game.garden_sun.global_basis.z.normalized())
	_mesh.multimesh.visible_instance_count=droplets.size()
	for i in range(droplets.size()):
		var d: Dictionary=droplets[i]
		var position: Vector3=d.at+d.velocity*d.age+Vector3(0,-4.2,0)*d.age*d.age
		_mesh.multimesh.set_instance_transform(i,Transform3D(Basis.IDENTITY,to_local(position)))
		_mesh.multimesh.set_instance_custom_data(i,Color(d.age/d.life,0,0,0))
