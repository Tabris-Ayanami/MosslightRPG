extends SceneTree
## Isolated material/framing proof; the gameplay integration lives in tests/hud_portrait.gd.
const Studio=preload("res://scripts/frontend/hud_portrait_studio.gd")
const Pencil=preload("res://shaders/frontend/round_portrait.gdshader")
class DisplayActor extends Node3D:
	var animation: Node3D
	var definition: Dictionary
	var definition_id: String
func _initialize() -> void: call_deferred("run")
func run() -> void:
	root.size=Vector2i(1280,720)
	var canvas:=Control.new()
	canvas.scale=Vector2.ONE*1.5
	root.add_child(canvas)
	var background:=ColorRect.new()
	background.color=Color("5b735a")
	background.size=Vector2(1280,720)
	canvas.add_child(background)
	var index:=0
	for spec in [["hero","桐人",true,"#ffffff",1.0],["soldier","士兵",false,"#6D956C",1.0],["ogre","巨人",false,"#A87F69",1.5]]:
		var actor:=DisplayActor.new()
		actor.definition_id=spec[0]
		actor.definition={"visual":{"kind":"kirito" if spec[2] else "procedural","color":spec[3],"scale":spec[4]}}
		root.add_child(actor)
		actor.animation=(load("res://combat/kirito_combat_visual.gd") if spec[2] else load("res://combat/animation_controller.gd")).new()
		actor.add_child(actor.animation)
		actor.animation.setup(spec[2],Color(spec[3]),spec[4])
		var studio:=Studio.new()
		root.add_child(studio)
		studio.sync_actor(actor)
		for size in [72,256]:
			var image:=TextureRect.new()
			image.position=Vector2(72+index*400,72 if size==72 else 240)
			image.size=Vector2.ONE*size
			image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
			image.texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR
			image.texture=studio.get_texture()
			image.material=ShaderMaterial.new()
			image.material.shader=Pencil
			canvas.add_child(image)
		var label:=Label.new()
		label.text=spec[1]+" · 铅笔头像"
		label.position=Vector2(70+index*400,165)
		label.add_theme_font_override("font",load("res://assets/ui/fonts/NotoSansSC.ttf"))
		label.add_theme_font_size_override("font_size",22)
		canvas.add_child(label)
		index+=1
	for i in range(8): await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/hud-portrait"))
	root.get_texture().get_image().save_png("res://docs/hud-portrait/material-preview.png")
	print("PORTRAIT_MATERIAL_PREVIEW complete")
	quit()
