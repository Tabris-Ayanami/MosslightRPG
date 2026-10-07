extends Control
signal start_pressed
signal new_pressed
signal settings_pressed
signal exit_pressed
signal combat_pressed
const A=preload("res://scripts/frontend/ui_art.gd")
const TYPE=preload("res://scripts/frontend/title_type.gd")
var typography: Control
var selected := 0
var logical_size := Vector2(1280,720)
var buttons: Array[Button]=[]
var combat_button: Button
func _ready() -> void:
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR
	typography=TYPE.new()
	add_child(typography)
	for i in range(4):
		var b := Button.new()
		b.name=["StartGame","NewAdventure","Settings","Exit"][i]
		b.rotation=TYPE.option_rotation(i)
		b.position=TYPE.option_position(i)+Vector2(-28,-63 if i<2 else -47).rotated(b.rotation)
		b.size=Vector2(302 if i<2 else 150,78 if i<2 else 62)
		b.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
		A.invisible_button(b)
		add_child(b)
		b.mouse_entered.connect(select.bind(i))
		b.focus_entered.connect(select.bind(i))
		b.pressed.connect(_activate.bind(i))
		buttons.append(b)
	combat_button = Button.new()
	combat_button.name = "CombatArena"
	combat_button.text = "战斗演练场"
	combat_button.position = Vector2(1060, 651)
	combat_button.size = Vector2(160, 38)
	combat_button.tooltip_text = "四职业、技能与装备测试"
	combat_button.pressed.connect(func() -> void: combat_pressed.emit())
	add_child(combat_button)
	get_viewport().size_changed.connect(resize_ui)
	resize_ui()
func _activate(index: int) -> void:
	[start_pressed,new_pressed,settings_pressed,exit_pressed][index].emit()
func set_meadow_texture(texture: Texture2D, surface: Texture2D=null) -> void:
	var shader := ShaderMaterial.new()
	shader.shader=preload("res://shaders/frontend/shadow_type.gdshader")
	shader.set_shader_parameter("meadow_texture",texture)
	typography.material=shader
	var ground: ShaderMaterial=shader.duplicate()
	ground.set_shader_parameter("ground_lettering",true)
	ground.set_shader_parameter("meadow_surface",surface)
	typography.ground_options.material=ground

func release_meadow_textures() -> void:
	typography.material=null
	typography.ground_options.material=null
func select(index: int) -> void:
	selected=index
	typography.selected=index
func resize_ui() -> void:
	var window := get_viewport().get_visible_rect().size
	var factor := minf(window.x/1280.0,window.y/720.0)
	scale=Vector2.ONE*factor
	position=Vector2((window.x-1280*factor)*.5,0)
	logical_size=Vector2(1280,720)
	size=logical_size
	queue_redraw()
func set_enabled(enabled: bool) -> void:
	combat_button.disabled = not enabled
	for button in buttons:
		button.disabled=not enabled
		button.mouse_filter=Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
func _draw() -> void:
	A.text(self,Vector2(72,52),"S W O R D   A R T   O N L I N E",15,A.PAPER,600)
	A.text(self,Vector2(76,225),"A I N C R A D   /   风 与 光 的 序 章",12,A.PAPER,500)
	A.text(self,Vector2(66,684),"LINK START",11,Color(A.PAPER,.8),600)
	draw_line(Vector2(160,679),Vector2(208,679),Color(A.PAPER,.55),1)
	A.text(self,Vector2(220,684),"在风停下之前，再休息一会。",11,Color(A.PAPER,.8))
