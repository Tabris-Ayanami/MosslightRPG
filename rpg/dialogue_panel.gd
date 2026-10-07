extends CanvasLayer
## Dialogue Manager owns the text and branches; the host owns pause and the world anchor.
signal opened
signal closed
const ART = preload("res://scripts/frontend/ui_art.gd")
const Menu = preload("res://rpg/world_action_menu.gd")
const Skins = preload("res://rpg/dialogue_skins.gd")
const Bubble = preload("res://rpg/speech_bubble.gd")
const Reveal = preload("res://rpg/dialogue_reveal.gd")
const GlyphEffect = preload("res://rpg/dialogue_glyph_effect.gd")
const MOVE_ACTIONS := ["move_up","move_down","move_left","move_right"]
@export var hold_to_leave_seconds := 1.0
var exit_progress := 0.0
var _movement_held: Dictionary = {}
var _typing := Reveal.new()
var _glyph := GlyphEffect.new()
var _appear := 0.0
var _choices_alpha := 0.0
var choice_bubble: Control
var choice_name: Label
var exit_ring: Control
var dialogue_resource: Resource
var dialogue_line: RefCounted
var last_error := ""
var _bridge: RefCounted
var _game: WeakRef
var _anchor: WeakRef
var _open := false
var _busy := false
var _generation := 0
var _selected := -1
var _focus_before: WeakRef
var _response_ids: Array[String] = []
var _allowed: Array[bool] = []
var surface: Control
var paper: Control
var speaker: Label
var body: RichTextLabel
var menu: Control
var close_button: Button
var _reveal := 0.0

func setup(game: Node) -> void:
	_game=weakref(game) if is_instance_valid(game) else null

func _ready() -> void:
	layer=40
	process_mode=Node.PROCESS_MODE_ALWAYS
	surface=Control.new()
	surface.name="WorldConversation"
	surface.mouse_filter=Control.MOUSE_FILTER_STOP
	add_child(surface)
	paper=Bubble.new()
	paper.name="SpeakerBubble"
	surface.add_child(paper)
	speaker=Label.new()
	speaker.add_theme_font_override("font",Skins.font())
	speaker.add_theme_font_size_override("font_size",12)
	speaker.mouse_filter=Control.MOUSE_FILTER_IGNORE
	paper.add_child(speaker)
	body=RichTextLabel.new()
	body.bbcode_enabled=true
	body.selection_enabled=false
	body.scroll_active=true
	body.visible_characters_behavior=TextServer.VC_CHARS_AFTER_SHAPING
	body.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	body.add_theme_font_override("normal_font",Skins.font())
	body.add_theme_font_override("bold_font",Skins.font())
	body.add_theme_font_size_override("normal_font_size",18)
	body.add_theme_font_size_override("bold_font_size",18)
	body.add_theme_constant_override("line_separation",6)
	body.mouse_filter=Control.MOUSE_FILTER_STOP
	body.gui_input.connect(_surface_input)
	_glyph.reveal=_typing
	body.install_effect(_glyph)
	paper.add_child(body)
	choice_bubble=Bubble.new()
	choice_bubble.name="PlayerChoiceBubble"
	choice_bubble.skin_id="player_bubble"
	surface.add_child(choice_bubble)
	choice_name=Label.new()
	choice_name.text="桐人"
	choice_name.add_theme_font_override("font",Skins.font())
	choice_name.add_theme_font_size_override("font_size",12)
	choice_name.add_theme_color_override("font_color",Color("68796e"))
	choice_bubble.add_child(choice_name)
	menu=Menu.new()
	menu.pixel_font=Skins.font()
	menu.text_outline=false
	menu.show_selected_when_closed=true
	menu.activated.connect(_menu_activated)
	menu.selection_changed.connect(func(index: int): _selected=index)
	paper.add_child(menu)
	close_button=Button.new()
	close_button.text="×"
	close_button.flat=true
	close_button.add_theme_font_override("font",Skins.font())
	close_button.add_theme_font_size_override("font_size",16)
	close_button.tooltip_text="离开交谈 · Esc"
	close_button.pressed.connect(close)
	paper.add_child(close_button)
	exit_ring=preload("res://rpg/dialogue_exit_ring.gd").new()
	surface.add_child(exit_ring)
	get_viewport().size_changed.connect(_resize)
	get_window().focus_exited.connect(_cancel_movement)
	_resize()
	hide()

func start(resource: Resource, bridge: RefCounted, title: String = "start", source: Node3D = null) -> bool:
	if _open or not is_node_ready() or resource==null or bridge==null or not resource.has_method("get_next_dialogue_line"):
		last_error="当前无法开始交谈。"
		return false
	dialogue_resource=resource
	_bridge=bridge
	_anchor=weakref(source) if is_instance_valid(source) else null
	dialogue_line=null
	_generation+=1
	_open=true
	_busy=true
	last_error=""
	var previous:=get_viewport().gui_get_focus_owner()
	_focus_before=weakref(previous) if is_instance_valid(previous) else null
	speaker.text="交谈"
	body.text="稍候……"
	body.visible_characters=-1
	_typing.finished=true
	_appear=0
	_cancel_movement()
	_clear_choices()
	_set_busy(true)
	_resize()
	show()
	opened.emit()
	_fetch.call_deferred(title,_generation)
	return true

func is_open() -> bool:
	return _open

func close(resume_movement := false) -> void:
	if not _open: return
	var held:=_movement_held.duplicate() if resume_movement else {}
	_open=false
	_busy=false
	_generation+=1
	dialogue_line=null
	dialogue_resource=null
	_bridge=null
	_anchor=null
	_typing.finished=true
	_typing.arrivals.clear()
	_cancel_movement()
	_clear_choices()
	body.text=""
	speaker.text=""
	hide()
	var previous: Variant=_focus_before.get_ref() if _focus_before!=null else null
	_focus_before=null
	if is_instance_valid(previous) and previous is Control and previous.is_visible_in_tree(): previous.grab_focus()
	closed.emit()
	# Host cleanup releases all actions; reapply only movement still held at completion.
	for action in held:
		if held[action]: Input.action_press(action)

func _exit_tree() -> void:
	close()
	_game=null

func _fetch(next_id: String, generation: int) -> void:
	if not _open or generation!=_generation: return
	var resource: Resource=dialogue_resource
	var state: RefCounted=_bridge
	var line: Variant=await resource.get_next_dialogue_line(next_id,[state])
	if not _open or generation!=_generation: return
	if line==null:
		close()
		return
	dialogue_line=line
	speaker.text=line.character if not str(line.character).is_empty() else "旅人"
	body.text="[spoken]"+str(line.text)+"[/spoken]"
	body.scroll_to_line(0)
	var skin:=Skins.resolve(_speaker_skin())
	_typing.start(body.get_parsed_text(),line,str(skin.voice))
	body.visible_characters=0
	_choices_alpha=0.0
	_clear_choices()
	var entries: Array[Dictionary]=[]
	for response in line.responses:
		var index:=_response_ids.size()
		_response_ids.append(str(response.next_id))
		_allowed.append(bool(response.is_allowed))
		entries.append({"id":str(index),"label":str(response.text),"enabled":bool(response.is_allowed)})
		if _selected<0 and response.is_allowed: _selected=index
	if entries.is_empty(): entries=[{"id":"continue","label":"继续"}]
	menu.set_entries(entries,true)
	menu.selected=maxi(0,_selected)
	_set_busy(false)
	var parent: Node=choice_bubble if not _response_ids.is_empty() else paper
	if menu.get_parent()!=parent: menu.reparent(parent,false)
	menu.force_open=not _response_ids.is_empty()
	_resize()

func _set_busy(value: bool) -> void:
	_busy=value
	menu.busy=value
	if value: menu.set_entries([{"id":"wait","label":"稍候……","enabled":false}])

func _activate() -> void:
	if not _open or _busy or dialogue_line==null: return
	if not _typing.finished:
		_typing.finish()
		body.visible_characters=_typing.characters
		return
	if not _response_ids.is_empty():
		_choose(menu.selected)
	else: _request(str(dialogue_line.next_id))

func _menu_activated(_id: String) -> void:
	_activate()

func _choose(index: int) -> void:
	if not _open or _busy or index<0 or index>=_allowed.size() or not _allowed[index]: return
	_request(_response_ids[index])

func _request(next_id: String) -> void:
	_set_busy(true)
	_fetch.call_deferred(next_id,_generation)

func _move_selection(direction: int) -> void:
	if _busy or not _typing.finished or _response_ids.is_empty(): return
	for step in range(1,_response_ids.size()+1):
		var index:=posmod(menu.selected+direction*step,_response_ids.size())
		if _allowed[index]:
			menu._scroll_slide=signf(float(direction))*menu.ROW
			menu.selected=index
			_selected=index
			return

func _input(event: InputEvent) -> void:
	if not _open or not event is InputEventKey: return
	get_viewport().set_input_as_handled()
	for action in MOVE_ACTIONS:
		if InputMap.has_action(action) and event.is_action(action): _movement_held[action]=event.pressed
	if not event.pressed or event.echo: return
	var code: int=event.keycode if event.keycode!=KEY_NONE else event.physical_keycode
	if code==KEY_ESCAPE: close()
	elif code in [KEY_DOWN,KEY_UP,KEY_TAB]: _move_selection(-1 if code==KEY_UP or (code==KEY_TAB and event.shift_pressed) else 1)
	elif (InputMap.has_action("interact") and event.is_action_pressed("interact")) or (not InputMap.has_action("interact") and code==KEY_F) or code in [KEY_ENTER,KEY_KP_ENTER] or (code==KEY_SPACE and _response_ids.is_empty()): _activate()

func _surface_input(event: InputEvent) -> void:
	if _open and event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT and (_response_ids.is_empty() or not _typing.finished):
		get_viewport().set_input_as_handled()
		_activate()

func _clear_choices() -> void:
	_selected=-1
	_response_ids.clear()
	_allowed.clear()
	menu.set_entries([])

func _cancel_movement() -> void:
	_movement_held.clear()
	exit_progress=0.0
	if is_instance_valid(exit_ring):
		exit_ring.progress=0
		exit_ring.queue_redraw()

func _tick_exit(delta: float) -> void:
	var vertical:=int(_movement_held.get("move_down",false))-int(_movement_held.get("move_up",false))
	var horizontal:=int(_movement_held.get("move_right",false))-int(_movement_held.get("move_left",false))
	if vertical!=0 or horizontal!=0: exit_progress=minf(1,exit_progress+delta/maxf(.1,hold_to_leave_seconds))
	else: exit_progress=0
	exit_ring.progress=exit_progress
	exit_ring.queue_redraw()
	if exit_progress>=1: close(true)

func _process(delta: float) -> void:
	if not _open: return
	if _anchor!=null and not is_instance_valid(_anchor.get_ref()):
		close()
		return
	_tick_exit(delta)
	if not _open: return
	if not _busy:
		_typing.tick(delta)
		body.visible_characters=_typing.characters
	_appear=move_toward(_appear,1,delta/.15)
	_choices_alpha=move_toward(_choices_alpha,1 if _typing.finished and not _busy and not _response_ids.is_empty() else 0,delta/.18)
	paper.modulate.a=smoothstep(0,1,_appear)
	choice_bubble.modulate.a=smoothstep(0,1,_choices_alpha)
	_resize()
	menu.tick(delta,get_viewport().get_mouse_position())

func _game_node() -> Node:
	return _game.get_ref() if _game!=null else null

func _speaker_actor() -> Node3D:
	var game:=_game_node()
	var source: Node3D=_anchor.get_ref() if _anchor!=null else null
	if is_instance_valid(game) and is_instance_valid(game.get("player")) and dialogue_line!=null:
		if str(dialogue_line.character) in ["桐人","主角",str(game.player.display_name)]: return game.player
	return source

func _speaker_skin() -> String:
	var game:=_game_node()
	return Skins.for_actor(_speaker_actor(),game.get("player") if is_instance_valid(game) else null)

func _project_head(actor: Node3D, fallback: Vector2) -> Vector2:
	var game:=_game_node()
	if not is_instance_valid(game) or not is_instance_valid(actor): return fallback
	return game.world_to_screen(actor.global_position+Vector3.UP*1.95)

func _place(bubble: Control, head: Vector2, factor: float, fraction: float, screen: Vector2) -> void:
	var at:=head-Vector2(bubble.size.x*fraction,bubble.size.y+22)*factor
	at.x=clampf(at.x,16*factor,screen.x-(bubble.size.x+16)*factor)
	at.y=clampf(at.y,16*factor,screen.y-(bubble.size.y+32)*factor)
	bubble.position=at.round()
	bubble.tail=(head-bubble.position)/factor
	bubble.queue_redraw()

func _resize() -> void:
	if surface==null: return
	var screen:=get_viewport().get_visible_rect().size
	var factor:=clampf(minf(screen.x/1280.0,screen.y/720.0),.75,2.0)
	surface.size=screen
	paper.scale=Vector2.ONE*factor
	choice_bubble.scale=Vector2.ONE*factor
	var skin:=Skins.resolve(_speaker_skin())
	paper.skin_id=_speaker_skin()
	speaker.add_theme_color_override("font_color",Color(skin.accent).darkened(.18))
	body.add_theme_color_override("default_color",Color(skin.ink))
	close_button.add_theme_color_override("font_color",Color(skin.edge))
	speaker.position=Vector2(20,13)
	speaker.size=Vector2(360,20)
	body.position=Vector2(20,38)
	body.size.x=378
	var body_height:=clampf(float(body.get_content_height())+8,54,140)
	body.size.y=body_height
	var responses:=not _response_ids.is_empty()
	paper.size=Vector2(420,body_height+58+(0 if responses else 40))
	close_button.position=Vector2(384,9)
	close_button.size=Vector2(23,23)
	if responses:
		choice_bubble.size=Vector2(342,142 if _response_ids.size()>2 else 122)
		choice_name.position=Vector2(20,12)
		choice_name.size=Vector2(305,20)
		menu.position=Vector2(17,74 if _response_ids.size()>2 else 52)-Menu.BADGE+Vector2(22,0)
		menu.text_color=Color("40514c")
		menu.secondary_color=Color("627365")
	else:
		menu.position=Vector2(18,paper.size.y-28)-Menu.BADGE
		menu.text_color=Color(skin.ink)
		menu.secondary_color=Color(skin.accent)
	menu.visible=not _busy and (not responses or _typing.finished)
	menu.busy=_busy
	choice_bubble.visible=responses and _choices_alpha>0
	var game:=_game_node()
	var source:=_speaker_actor()
	paper.visible=not is_instance_valid(source) or not game.camera.is_position_behind(source.global_position+Vector3.UP*1.95)
	var head:=_project_head(source,screen*Vector2(.44,.54))
	_place(paper,head,factor,1.02,screen)
	if is_instance_valid(game) and is_instance_valid(game.get("player")):
		exit_ring.game=game
		choice_name.text=str(game.player.display_name)
		if is_instance_valid(game.get("world_ui")): menu.key_text=game.world_ui.interaction_key()
		var player_head:=_project_head(game.player,screen*Vector2(.53,.65))
		_place(choice_bubble,player_head,factor,.13,screen)
		if responses and paper.get_global_rect().grow(8*factor).intersects(choice_bubble.get_global_rect()):
			var right_edge:=paper.get_global_rect().end.x+12*factor
			if right_edge+choice_bubble.size.x*factor<screen.x-16*factor: choice_bubble.position.x=right_edge
			else: choice_bubble.position.x=maxf(16*factor,paper.position.x-(choice_bubble.size.x+12)*factor)
			choice_bubble.tail=(player_head-choice_bubble.position)/factor
			choice_bubble.queue_redraw()
	else:
		_place(choice_bubble,screen*Vector2(.55,.7),factor,.1,screen)
