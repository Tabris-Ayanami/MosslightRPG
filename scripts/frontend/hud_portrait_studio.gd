extends SubViewport
## A neutral bust of the HUD's current body, independent of gameplay transforms,
## animation, health and controller ownership. Render only when appearance changes.
var source_actor_id := 0
var source_definition_id := ""
var render_revision := 0
var appearance_key := 0
var visual: Node3D
var camera: Camera3D

func _ready() -> void:
	name="PortraitStudio"
	own_world_3d=true
	transparent_bg=true
	size=Vector2i(256,256)
	msaa_3d=Viewport.MSAA_4X
	render_target_update_mode=SubViewport.UPDATE_DISABLED
	var environment:=WorldEnvironment.new()
	var studio:=Environment.new()
	studio.background_mode=Environment.BG_COLOR
	studio.background_color=Color("eee5cf")
	studio.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	studio.ambient_light_color=Color("f5eee0")
	studio.ambient_light_energy=.85
	environment.environment=studio
	add_child(environment)
	var key_light:=DirectionalLight3D.new()
	key_light.rotation_degrees=Vector3(-28,145,0)
	key_light.light_energy=1.05
	add_child(key_light)
	camera=Camera3D.new()
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	add_child(camera)

func sync_actor(actor: Node) -> void:
	if not is_instance_valid(actor) or not is_instance_valid(actor.get("animation")):
		clear_actor()
		return
	var source: Node3D=actor.animation
	var equipment: Dictionary=source.equipment
	var next_key:=hash([source.get_instance_id(),actor.definition.visual,equipment])
	if source_actor_id==actor.get_instance_id() and next_key==appearance_key: return
	_discard_visual()
	source_actor_id=actor.get_instance_id()
	source_definition_id=actor.definition_id
	appearance_key=next_key
	render_revision+=1
	# Only a visual adapter is instantiated: no AI, collision, input or resource
	# components are copied from the controlled actor into the portrait viewport.
	visual=source.get_script().new()
	visual.name="PortraitBody"
	visual.equipment=equipment.duplicate(true)
	add_child(visual)
	var style: Dictionary=actor.definition.visual
	var body_scale:=float(style.get("scale",1.0))
	visual.setup(style.kind=="kirito",Color(style.get("color","#ffffff")),body_scale)
	visual.play_locomotion(false)
	visual.update_pose(.2,Vector3.FORWARD,"NORMAL","NONE",0)
	visual.rotation=Vector3.ZERO
	# A bust includes clothing/headgear but no held weapons or combat effects.
	for field in ["_weapon","_dual_weapon","_shield","_spell_glow","_blade_trail","_second_blade_trail","_charge_aura","_release_flash"]:
		var accessory: Node3D=visual.get(field)
		if is_instance_valid(accessory): accessory.hide()
	var head: Vector3=visual._head.global_position+Vector3.UP*.04*body_scale
	var skeleton: Skeleton3D=visual.get("skeleton")
	if is_instance_valid(skeleton):
		var bone:=skeleton.find_bone("J_Bip_C_Head")
		if bone>=0: head=skeleton.global_transform*skeleton.get_bone_global_pose(bone).origin
	var is_kirito: bool=style.kind=="kirito"
	var center:=head+Vector3.UP*(.065 if is_kirito else -.065)*body_scale
	camera.size=(.54 if is_kirito else .78)*body_scale
	camera.look_at_from_position(center+Vector3(.17,.035,-3.0)*body_scale,center)
	visual.process_mode=Node.PROCESS_MODE_DISABLED
	render_target_update_mode=SubViewport.UPDATE_ONCE
	_settle_capture.call_deferred(render_revision)

func clear_actor() -> void:
	if source_actor_id==0: return
	source_actor_id=0
	source_definition_id=""
	appearance_key=0
	render_revision+=1
	_discard_visual()
	render_target_update_mode=SubViewport.UPDATE_ONCE

func _discard_visual() -> void:
	if not is_instance_valid(visual): return
	remove_child(visual)
	visual.queue_free()
	visual=null

func _settle_capture(revision: int) -> void:
	# Skinned meshes finish registering after the first frame. A revision guard
	# prevents a pending capture from an earlier body overwriting a rapid switch.
	await get_tree().process_frame
	await get_tree().process_frame
	if revision==render_revision and is_inside_tree():
		render_target_update_mode=SubViewport.UPDATE_ONCE
