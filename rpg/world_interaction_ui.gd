extends CanvasLayer
const Menu = preload("res://rpg/world_action_menu.gd")
const Feed = preload("res://rpg/event_feed.gd")
const Readiness = preload("res://rpg/interaction_readiness.gd")
const Picker = preload("res://rpg/interaction_picker.gd")
var game: Node
var menu: Control
var feed: Control
var target: Node3D
var pointed_object: Node3D
var pointer_capture := false

func _ready() -> void:
	layer=15
	process_mode=Node.PROCESS_MODE_ALWAYS
	process_priority=20 # project after the camera has completed its pixel snap
	menu=Menu.new()
	menu.pixel_font=preload("res://rpg/dialogue_skins.gd").font()
	menu.show_selected_when_closed=true
	menu.expand_on_hover=false
	add_child(menu)
	menu.activated.connect(_activate)
	menu.hide()
	feed=Feed.new()
	add_child(feed)

func _process(delta: float) -> void:
	if not is_instance_valid(game) or not is_instance_valid(game.player): return
	var screen:=get_viewport().get_visible_rect().size
	var factor:=clampf(minf(screen.x/1280.0,screen.y/720.0),.75,2.0)
	var pointer:=get_viewport().get_mouse_position()
	feed.scale=Vector2.ONE*factor
	feed.position=Vector2(screen.x-326*factor,screen.y*.43)
	feed.visible=not game.paused
	feed.tick(delta,pointer,game.paused)
	update_context(delta,pointer)

func update_context(delta: float, pointer: Vector2) -> void:
	var screen:=get_viewport().get_visible_rect().size
	var factor:=clampf(minf(screen.x/1280.0,screen.y/720.0),.75,2.0)
	var actor: Node=game.controlled_actor()
	pointed_object=null
	if game.paused or not game.player.is_physics_processing() or not is_instance_valid(actor) or actor.dead:
		menu.hide()
		target=null
		pointer_capture=false
		return
	var next: Node3D=actor.ladder.active_ladder if actor.ladder.active else game.nearest_interactable()
	if not actor.ladder.active:
		if not Readiness.can_manage(actor): next=null
		elif not game.camera_dragging:
			# An already-open list can keep focus while the cursor crosses from
			# the object into its text. A closed label never opens other choices.
			if menu.visible and menu.expanded>.08 and menu.hit_test(pointer) and game.interactions.within_reach(target,actor):
				next=target
			else:
				pointed_object=Picker.pointed_at(game,pointer)
				if is_instance_valid(pointed_object): next=pointed_object
	if not is_instance_valid(next):
		menu.hide()
		target=null
		return
	var changed:=target!=next
	target=next
	menu.force_open=pointed_object==target
	var entries: Array[Dictionary]=game.interactions.actions(target)
	if actor.ladder.active: entries=[{"id":"leave_ladder","label":"松开木梯"}]
	menu.set_entries(entries,changed)
	menu.title=str(target.get("display_name")) if target.get("display_name")!=null else ""
	menu.key_text=interaction_key()
	var anchor: Vector3=game.interactions.anchor(target)
	if game.camera.is_position_behind(anchor):
		menu.hide()
		return
	var point: Vector2=game.world_to_screen(anchor)
	if not Rect2(Vector2(20,20)*factor,screen-Vector2(40,40)*factor).has_point(point):
		menu.hide()
		return
	menu.scale=Vector2.ONE*factor
	var x:=point.x+26*factor
	if x+menu.size.x*factor>screen.x-20*factor: x=point.x-304*factor
	menu.position=Vector2(x,point.y-Menu.BADGE.y*factor)
	menu.show()
	menu.tick(delta,pointer)
	if menu.expanded==0 and not menu.force_open and menu.selected!=0:
		# Leaving the object returns F to the safe default action.
		menu.scroll_by(-menu.selected)

func interaction_key() -> String:
	for event in InputMap.action_get_events("interact"):
		if event is InputEventKey:
			return OS.get_keycode_string(event.physical_keycode if event.physical_keycode else event.keycode)
	return "F"

func blocks_pointer(point: Vector2) -> bool:
	return not game.paused and (pointer_capture or menu.hit_test(point) or feed.hit_test(point))

func handle_pointer(event: InputEvent) -> bool:
	if not event is InputEventMouseButton or game.paused: return false
	# Releasing an existing orbit must work even if the pointer crosses a menu.
	if game.camera_dragging and event.button_index==MOUSE_BUTTON_MIDDLE and not event.pressed:
		game._end_camera_orbit()
		get_viewport().set_input_as_handled()
		return true
	if game.camera_dragging: return false
	# Resolve the object at the event's position too: a quick move + wheel must
	# not use the previous frame's target or accidentally zoom the camera.
	update_context(0,event.position)
	var hit: bool=feed.handle_pointer(event)
	if not hit and event.button_index in [MOUSE_BUTTON_WHEEL_DOWN,MOUSE_BUTTON_WHEEL_UP] and is_instance_valid(pointed_object) and pointed_object==target and menu.visible:
		if event.pressed: menu.scroll_by(1 if event.button_index==MOUSE_BUTTON_WHEEL_DOWN else -1)
		hit=true
	if not hit: hit=menu.handle_pointer(event)
	var weapon: bool=event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT]
	var captured:=pointer_capture
	if weapon:
		if event.pressed and hit: pointer_capture=true
		elif not event.pressed: pointer_capture=false
	if hit or captured:
		game.controlled_actor().combat.clear_pointer_intent()
		get_viewport().set_input_as_handled()
		return true
	return false

func _input(event: InputEvent) -> void:
	handle_pointer(event)

func activate() -> bool:
	if not is_instance_valid(target) or not menu.visible: return false
	menu.activate_selected()
	return true

func _activate(id: String) -> void:
	if is_instance_valid(target): game.interactions.execute(target,id)
