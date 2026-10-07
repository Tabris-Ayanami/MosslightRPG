extends SceneTree
const RETARGET=preload("res://tools/retarget_title_assets.gd")
const VISUAL=preload("res://scripts/kirito_visual.gd")
var source: Node3D
var player: AnimationPlayer
var imported: AnimationPlayer
var headline: Label
func _initialize() -> void: call_deferred("run")
func find_kind(node: Node, kind: String) -> Node:
	if node.is_class(kind): return node
	for child in node.get_children():
		var found := find_kind(child,kind)
		if found: return found
	return null
func run() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode=Environment.BG_COLOR
	env.background_color=Color("c3cdc2")
	env.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color=Color.WHITE
	env.ambient_light_energy=.6
	env_node.environment=env
	stage.add_child(env_node)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-48,-28,0)
	sun.shadow_enabled=true
	sun.light_energy=1.3
	stage.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size=Vector2(100,100)
	ground.mesh=plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color=Color("859c83")
	ground.material_override=mat
	stage.add_child(ground)
	var camera := Camera3D.new()
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=9
	stage.add_child(camera)
	camera.look_at_from_position(Vector3(6,5.4,10),Vector3(0,1.15,0))
	var actor := Node3D.new()
	actor.position.x=2
	stage.add_child(actor)
	var hero=VISUAL.new()
	hero.name="PerformanceHero"
	actor.add_child(hero)
	hero.rotation.y=PI
	hero.scale=Vector3.ONE*1.78
	hero.animator.stop()
	hero.animator.active=false
	player=AnimationPlayer.new()
	actor.add_child(player)
	player.add_animation_library("",load("res://assets/animations/retargeted/quaternius-title.res"))
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	document.append_from_file(RETARGET.SOURCE2,state)
	source=document.generate_scene(state)
	stage.add_child(source)
	source.position.x=-2
	source.scale=Vector3.ONE*1.99
	imported=find_kind(source,"AnimationPlayer")
	headline=Label.new()
	headline.add_theme_font_override("font",load("res://assets/ui/fonts/NotoSansSC.ttf"))
	headline.add_theme_font_size_override("font_size",25)
	headline.add_theme_color_override("font_color",Color("263c35"))
	headline.position=Vector2(32,25)
	root.add_child(headline)
	var snapshots := "--snapshots" in OS.get_cmdline_user_args()
	for pair in [["GetUp","LayToIdle",3.2],["Idle","Idle_No_Loop",2.0],["Walk","LayToIdle",2.6]]:
		var clip: String=pair[0]
		player.play(clip)
		player.pause()
		imported.play(pair[1])
		imported.pause()
		var duration: float=player.get_animation(clip).length
		headline.text="Quaternius 原始素材        /        桐人重定向    ·    "+clip
		headline.text+="\n素材验证：接地尚待修正，衣摆尚未重新烘焙"
		source.visible=clip=="GetUp"
		if clip!="GetUp": headline.text="桐人重定向    ·    "+clip+"    /    身体动作测试，衣摆尚未重新烘焙"
		var frame_count: int=roundi(pair[2]*30)
		for frame in range(frame_count+1):
			var t := float(frame)/frame_count
			player.seek(t*duration,true)
			imported.seek(t*imported.get_animation(pair[1]).length,true)
			await process_frame
			if snapshots and frame in [0,roundi(frame_count*.25),roundi(frame_count*.5),roundi(frame_count*.75),frame_count]:
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png("res://.work/motion-assets/"+clip+"-%03d.png"%frame)
	for i in range(10): await process_frame
	headline.queue_free()
	stage.queue_free()
	for i in range(5): await process_frame
	quit()
