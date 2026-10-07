extends Control
## The same illustrated presenter supports a live RPG actor and an unbound art fixture.
signal modal_changed(open: bool)
signal begin_adventure
signal return_to_title
signal save_requested
const A=preload("res://scripts/frontend/ui_art.gd")
const F=preload("res://scripts/frontend/field_guide_art.gd")
const CONTENT=preload("res://scripts/frontend/prototype_content.gd")
const BINDINGS=preload("res://scripts/frontend/journal_bindings.gd")
const GUIDE_BUTTON=preload("res://scripts/frontend/guide_button.gd")
const MOTION=preload("res://scripts/frontend/book_motion.gd")
const PAGES=preload("res://scripts/frontend/journal_spreads.gd")
const CONTROLS=preload("res://scripts/frontend/journal_controls.gd")
const PRINT=preload("res://shaders/frontend/journal_print.gdshader")
const MINIMAP=preload("res://scripts/frontend/traveller_map.gd")
const CHART=preload("res://scripts/frontend/unfolded_map.gd")
const RPG_VIEW=preload("res://scripts/frontend/rpg_view_model.gd")
const CAREERS=preload("res://scripts/frontend/career_tree.gd")
const HUD_SLOT=preload("res://scripts/frontend/hud_slot.gd")
const HUD_MOVEMENT=preload("res://scripts/frontend/hud_movement_button.gd")
const HUD_WEAPONS=preload("res://scripts/frontend/hud_weapon_art.gd")
const ENERGY_BAR=preload("res://scripts/frontend/hud_energy_bar.gd")
const PREFERENCES=preload("res://rpg/game_preferences.gd")
const BOOK_SIZE=Vector2(1120,550)
const OPEN_SECONDS=.68
const CLOSE_SECONDS=.52
const TURN_SECONDS=.92
var minimap: Control
var unfolded_map: Control
var game_mode := false
var panel := ""
var panel_rect := Rect2()
var logical_size := Vector2(1280,720)
var selected_item := 2
var selected_quest := 0
var tracked_quest := 0
var quest_records: Array[Dictionary]=[]
var selected_quest_id := ""
var tracked_quest_id := ""
var quest_list_scroll := 0
var quest_detail_scroll := 0
var journey_memo_open := false
var journey_memo_scroll := 0
var quest_buttons: Dictionary={}
const TRACKED_QUEST_FLAG := "journal.tracked_quest"
var inventory_tab := 0
var selected_trait := 0
var trait_page := 0
var discard_confirm := false
var character_tab := 0
var settings_tab := 0
var save_note := ""
var selected_equipment := 0
var selected_skill := 0
var skill_points := 4
var learned_skills: Dictionary={0:true,1:true,2:true,7:true,11:true}
var active_slots: Array[int]=[0,1,2]
var reserve_slots: Array[int]=[2,0,1]
var passive_slots: Array[int]=[7,11]
var loadout_slot := -1
var loadout_passive := false
var ink_open := false
var ink_progress := 0.0
var awaiting_binding := -1
var binding_note := ""
var binding_signature := ""
var region_name := "风息原野"
var region_subtitle := "风经过的地方，故事才刚刚开始"
var region_clock := 0.0
var elapsed := 0.0
var hud_alpha := 1.0
var book_age := 0.0
var transition := ""
var motion_ready := false
var pending_close := false
var close_action := ""
var motion_ticket := 0
var hud_buttons: Control
var modal: Control
var portrait: TextureRect
var portrait_studio: SubViewport
var paper_doll: TextureRect
var backdrop: ColorRect
var cover: BindingCanvas
var paper: BookCanvas
var book_surface: SubViewportContainer
var book_view: SubViewport
var shield: Control
var motion: Control
var focus_before_modal: Control
var preview_levels := PREFERENCES.AUDIO_DEFAULTS.duplicate()
var preview_choice := 0
var quick_buttons: Dictionary={}
var movement_buttons: Dictionary={}
var item_buttons: Dictionary={}
var skill_buttons: Dictionary={}
var ink_buttons: Dictionary={}
var rpg: Node
var rpg_state: Dictionary={}
var display_name := "桐人"
var rpg_note := ""
var rpg_feedback_failed := false
var inventory_page := 0
var equipment_page := 0
var equipment_choice_page := 0
var skill_page := 0
var hud_resource_id := ""
var _weapon_focus := 0.0
var quick_picker := false
var equipment_picker := false
var career_picker := false
var career_forget_confirm := false
var preparation_set := 0
var fixture_careers: Array[String]=[]
var career_nodes: Array[Dictionary]=[]
var career_buttons: Dictionary={}
var career_signature := ""
var career_age := 0.0
var career_page := 0
var career_context := ""
var career_detail_id := ""
var career_focus_key := ""
var career_focus_pending := false
var loadout_choice_page := 0
var _rpg_refresh_pending := false
var _rpg_connections: Array[Dictionary]=[]
var _hud_draw_state: Array=[]
var _hud_hint_clock := 0.0

class BindingCanvas extends Control:
	var ui: Control
	func _draw() -> void:
		if is_instance_valid(ui) and ui.panel!="": ui.F.book_cover(self,ui.panel_rect.position)

class BookCanvas extends Control:
	var ui: Control
	func _draw() -> void:
		if is_instance_valid(ui) and ui.panel!="": ui._draw_book(self)

func bind_rpg(actor: Node, actor_name := "桐人") -> void:
	for entry in _rpg_connections:
		if is_instance_valid(entry.source) and entry.source.is_connected(entry.signal,entry.callback):
			entry.source.disconnect(entry.signal,entry.callback)
	_rpg_connections.clear()
	rpg=actor
	display_name=actor_name if not actor_name.strip_edges().is_empty() else "桐人"
	rpg_state.clear()
	quest_records.clear()
	selected_quest_id=""
	tracked_quest_id=""
	selected_quest=0
	tracked_quest=0
	quest_list_scroll=0
	quest_detail_scroll=0
	journey_memo_open=false
	journey_memo_scroll=0
	rpg_note=""
	rpg_feedback_failed=false
	hud_resource_id=""
	if not is_instance_valid(rpg):
		if is_instance_valid(portrait_studio): portrait_studio.clear_actor()
		return
	_weapon_focus=float(rpg.loadout.current_set)
	for component in [rpg.loadout,rpg.inventory,rpg.progression,rpg.stats]:
		component.changed.connect(_queue_rpg_refresh)
		_rpg_connections.append({"source":component,"signal":"changed","callback":_queue_rpg_refresh})
	rpg.resources.resource_changed.connect(_rpg_resource_changed)
	_rpg_connections.append({"source":rpg.resources,"signal":"resource_changed","callback":_rpg_resource_changed})
	var quests: RefCounted=quest_service()
	if is_instance_valid(quests):
		quests.changed.connect(_queue_rpg_refresh)
		_rpg_connections.append({"source":quests,"signal":"changed","callback":_queue_rpg_refresh})
	preparation_set=rpg.loadout.current_set
	var host: Node = rpg.arena.host
	if is_instance_valid(host) and host.get("economy") != null:
		host.economy.changed.connect(_queue_rpg_refresh)
		_rpg_connections.append({"source":host.economy,"signal":"changed","callback":_queue_rpg_refresh})
	_sync_rpg()

func has_rpg() -> bool: return is_instance_valid(rpg) and not rpg_state.is_empty()
func quest_service() -> RefCounted:
	if not is_instance_valid(rpg): return null
	var host: Node=rpg.get("game")
	return host.get("quests") if is_instance_valid(host) else null

func quest_at(index: int) -> Dictionary:
	return quest_records[index] if index>=0 and index<quest_records.size() else {}

func quest_status_label(status: String) -> String:
	return {"active":"进行中","ready":"可交付","rewarded":"已完成"}.get(status,"尚未接取")

func _sync_quests() -> void:
	quest_records.clear()
	var quests: RefCounted=quest_service()
	if not is_instance_valid(quests): return
	for entry in quests.entries(false):
		if entry.status in ["active","ready","rewarded"]: quest_records.append(entry)
	var host: Node=rpg.get("game")
	var tracked: Variant=host.world_state.get_flag(TRACKED_QUEST_FLAG,"")
	tracked_quest_id=tracked if tracked is String else ""
	selected_quest=-1
	tracked_quest=-1
	for i in range(quest_records.size()):
		if quest_records[i].id==selected_quest_id: selected_quest=i
		if quest_records[i].id==tracked_quest_id and quest_records[i].status!="rewarded": tracked_quest=i
	if selected_quest<0 and not quest_records.is_empty():
		selected_quest=tracked_quest if tracked_quest>=0 else 0
		selected_quest_id=quest_records[selected_quest].id
		quest_detail_scroll=0
	if quest_records.is_empty(): selected_quest_id=""
	if tracked_quest<0: tracked_quest_id=""

func tracked_quest_summary() -> Dictionary:
	var entry: Dictionary=quest_at(tracked_quest)
	if entry.is_empty():
		var first_steps := _first_steps_summary()
		if not first_steps.is_empty(): return first_steps
		return {"title":"尚未追踪任务","detail":"与村民交谈，记下新的委托。" if quest_records.is_empty() else "打开日志，选择要追踪的任务。"}
	if entry.status=="ready": return {"title":entry.title,"detail":"目标已完成 · 返回委托人处交付"}
	for objective in entry.objectives:
		if not objective.complete:
			var host: Node=rpg.get("game")
			if is_instance_valid(host) and is_instance_valid(host.combat_world) and host.combat_world.has_method("encounter_hint"):
				# Progress contains counters, while event metadata belongs to the
				# quest definition. Match by stable objective ID, not list index.
				for target in quest_service().definition(entry.id).get("objectives",[]):
					if target.id!=objective.id or target.get("event","")!="enemy_defeated": continue
					var hint: String=host.combat_world.encounter_hint(str(target.get("subject","")))
					if not hint.is_empty(): return {"title":entry.title,"detail":hint}
			return {"title":entry.title,"detail":"%s  %d/%d"%[objective.label,objective.current,objective.target]}
	return {"title":entry.title,"detail":quest_status_label(entry.status)}

func _first_steps_summary() -> Dictionary:
	var quests: RefCounted=quest_service()
	if not has_rpg() or quests==null or quests.status("village_patrol")!="available": return {}
	if rpg.loadout.level==0: return {"title":"选择你的道路","detail":"打开角色书页，选择基础职业。"}
	if rpg.loadout.learned_skills.is_empty(): return {"title":"研习第一个招式","detail":"打开技能页，免费研习招式。"}
	for id: String in rpg.loadout.sets[rpg.loadout.current_set].skills:
		if not id.is_empty(): return {"title":"寻找守望人艾琳","detail":"沿北桥前往风铃村，找守望人艾琳。"}
	return {"title":"备战第一个招式","detail":"技能页点「备战」，选择当前武器组槽位。"}

func _quest_scroll_changed(value: float,detail: bool) -> void:
	if detail: quest_detail_scroll=int(value)
	else: quest_list_scroll=int(value)
func items() -> Array: return rpg_state.items if has_rpg() else CONTENT.ITEMS
func skills() -> Array: return rpg_state.skills if has_rpg() else CONTENT.SKILLS
func traits() -> Array: return rpg_state.get("traits",[]) if has_rpg() else preload("res://scripts/frontend/trait_notes.gd").fixtures()
func _select_trait(index: int) -> void:
	selected_trait=index
	_build_modal.call_deferred()
func equipment_entries() -> Array: return rpg_state.equipment if has_rpg() else CONTENT.EQUIPMENT
func group_slots(group: int) -> Array[int]:
	if not has_rpg(): return active_slots if group==0 else reserve_slots
	var result: Array[int]=[]
	for id in rpg.loadout.sets[group].skills: result.append(skill_index(id))
	return result
func item_at(index: int) -> Dictionary:
	return items()[index] if index>=0 and index<items().size() else {"id":"","name":"行囊暂空","kind":"bag","type":"物品","category":"","count":"0","color":F.SAGE,"note":"选择职业后领取随行物资。","stat":""}
func skill_at(index: int) -> Dictionary:
	return skills()[index] if index>=0 and index<skills().size() else {"id":"","name":"空招式槽","kind":"","type":"尚未备战","note":"先选择职业，再研习招式。","cost":"—","cooldown":"—","passive":false,"parent":-1,"pos":Vector2(260,188),"reason":"先选择职业"}
func skill_index(id: String) -> int:
	for i in range(skills().size()):
		if skills()[i].get("id","")==id: return i
	return -1
func _rpg_resource_changed(id: String,current: float,maximum: float) -> void:
	# Recovery changes every physics tick. It must not rebuild inventory, career
	# options and all buttons (or interrupt a held button/tooltip) each time.
	if rpg_state.has("resources") and rpg_state.resources.has(id):
		rpg_state.resources[id].current=current
		rpg_state.resources[id].max=maximum
		rpg_state.resources[id].unlimited=rpg.resources.unlimited.get(id,false)
	_refresh()
func _queue_rpg_refresh() -> void:
	if _rpg_refresh_pending: return
	_rpg_refresh_pending=true
	_sync_rpg.call_deferred()
func _sync_rpg() -> void:
	_rpg_refresh_pending=false
	if not is_instance_valid(rpg): return
	var item_id: String=item_at(selected_item).get("id","")
	var skill_id: String=skill_at(selected_skill).get("id","")
	rpg_state=RPG_VIEW.build(rpg,display_name)
	_sync_quests()
	CAREERS.refresh(self)
	selected_item=clampi(selected_item,0,maxi(0,items().size()-1))
	for i in range(items().size()):
		if items()[i].id==item_id: selected_item=i; break
	selected_skill=maxi(0,skill_index(skill_id))
	learned_skills.clear()
	for i in range(skills().size()):
		if skills()[i].learned: learned_skills[i]=true
	active_slots.clear()
	for id in rpg.loadout.sets[preparation_set].skills: active_slots.append(skill_index(id))
	passive_slots=[-1,-1]
	var passive_index := 0
	for i in range(skills().size()):
		if skills()[i].passive and passive_index<2:
			passive_slots[passive_index]=i
			passive_index+=1
	if is_instance_valid(hud_buttons): _rebuild_hud_buttons()
	if panel!="" and transition=="": _build_modal.call_deferred()
	_refresh()

func _operation(success: bool, reason: String, message: String) -> void:
	rpg_note=message if success else reason
	rpg_feedback_failed=not success
	_queue_rpg_refresh()

func _select_career() -> void:
	career_picker=true
	equipment_picker=false
	if character_tab!=1: _select_character_tab(1)
	else: _build_modal.call_deferred()

func _choose_career(id: String) -> void:
	career_forget_confirm=false
	if not has_rpg():
		fixture_careers.append(id)
		CAREERS.refresh(self)
		_build_modal.call_deferred()
		return
	var first: bool=rpg.loadout.career_ids.is_empty()
	var success: bool=rpg.progression.choose_career(id)
	_operation(success,rpg.progression.last_error,"")
	if success:
		career_picker=false
		if first: _open_skill_study.call_deferred()

func _request_forget_career() -> void:
	if not has_rpg(): return
	var reason: String=rpg.progression.can_forget_career()
	if not reason.is_empty():
		_operation(false,reason,"")
		return
	career_forget_confirm=true
	_build_modal.call_deferred()
	_refresh()

func _cancel_forget_career() -> void:
	career_forget_confirm=false
	_build_modal.call_deferred()
	_refresh()

func _confirm_forget_career() -> void:
	if not has_rpg() or not career_forget_confirm: return
	career_forget_confirm=false
	var success: bool=rpg.progression.forget_career()
	if success:
		career_picker=true
		career_detail_id=""
		career_focus_key=""
		career_focus_pending=true
	_operation(success,rpg.progression.last_error,"已回归平民，等级与经验保留。请选择新的职业。")

func _open_skill_study() -> void:
	if not has_rpg(): return
	_sync_rpg()
	for index in range(skills().size()):
		if can_learn(index):
			selected_skill=index
			skill_page=index/12
			break
	show_panel("skills")

func _inspect_career(id: String) -> void:
	career_detail_id=id
	paper.queue_redraw()

func _focus_career(key: String,id: String) -> void:
	career_focus_key=key
	_inspect_career(id)

func _change_career_page(step: int) -> void:
	if transition!="": return
	var next := clampi(career_page+step,0,CAREERS.page_count(self)-1)
	if next==career_page: return
	_turn_page.call_deferred(func(): CAREERS.change_page(self,next),step)

func _inventory_action(kind: String, index := -1) -> void:
	if kind=="discard":
		discard_confirm=true
		_build_modal.call_deferred()
		return
	if kind=="cancel_discard":
		discard_confirm=false
		_build_modal.call_deferred()
		return
	if not has_rpg(): return
	var item: Dictionary=item_at(selected_item)
	var id: String=item.id
	match kind:
		"confirm_discard":
			_operation(rpg.inventory.discard_item(id),rpg.inventory.last_error,"已丢弃一件「"+item.name+"」。")
			discard_confirm=false
		"use": _operation(rpg.inventory.use_item(id),rpg.inventory.last_error,"已使用「"+item.name+"」。")
		"quick": quick_picker=true; _build_modal.call_deferred()
		"assign_quick":
			_operation(rpg.inventory.assign_quick_slot(index,id),rpg.inventory.last_error,"已放入快捷槽 %d。"%(index+1))
			quick_picker=false
		"weapon": _operation(rpg.loadout.equip_weapon(index,id),rpg.loadout.last_error,"已装备到武器 "+["A","B"][index]+"。")
		"equipment":
			var slot: String=item.get("slot","")
			if slot=="ring": slot="ring1" if index==0 else "ring2"
			_operation(rpg.loadout.equip_item(slot,id),rpg.loadout.last_error,"装备已穿戴。")

func _change_page(kind: String, step: int) -> void:
	match kind:
		"inventory": inventory_page=maxi(0,inventory_page+step)
		"equipment": equipment_page=maxi(0,equipment_page+step)
		"equipment_choice": equipment_choice_page=maxi(0,equipment_choice_page+step)
		"loadout_choice": loadout_choice_page=maxi(0,loadout_choice_page+step)
		"traits": trait_page=maxi(0,trait_page+step)
		"skills": skill_page=maxi(0,skill_page+step)
	_rebuild_hud_buttons.call_deferred()
	_build_modal.call_deferred()

func _select_preparation_set(index: int) -> void:
	preparation_set=index
	loadout_slot=-1
	_sync_rpg()

func _equipment_choices() -> Array[int]:
	var result: Array[int]=[]
	var equipped: Dictionary=equipment_entries()[selected_equipment]
	for i in range(items().size()):
		var item: Dictionary=items()[i]
		if equipped.weapon and item.category=="weapon": result.append(i)
		elif not equipped.weapon and item.category=="equipment" and (item.slot==equipped.key or item.slot=="ring" and equipped.key in ["ring1","ring2"]): result.append(i)
	return result

func _equip_choice(index: int) -> void:
	var slot: Dictionary=equipment_entries()[selected_equipment]
	var id: String=item_at(index).id
	var success: bool=rpg.loadout.equip_weapon(int(slot.key),id) if slot.weapon else rpg.loadout.equip_item(slot.key,id)
	_operation(success,rpg.loadout.last_error,"装备已穿戴。")
	if success: equipment_picker=false

func _cancel_equipment_choice() -> void:
	equipment_picker=false
	career_picker=false
	_build_modal.call_deferred()

func _unequip_selected() -> void:
	var slot: Dictionary=equipment_entries()[selected_equipment]
	var success: bool=rpg.loadout.equip_weapon(int(slot.key),"") if slot.weapon else rpg.loadout.equip_item(slot.key,"")
	_operation(success,rpg.loadout.last_error,"装备已收回行囊。")
	if success: equipment_picker=false

func _clear_skill_slot() -> void:
	if not has_rpg() or loadout_slot<0: return
	var success: bool=rpg.loadout.assign_skill(preparation_set,loadout_slot,"")
	_operation(success,rpg.loadout.last_error,"招式槽已清空，已学技艺保留。")
	if success: loadout_slot=-1

func _quick_slot_input(event: InputEvent,index: int) -> void:
	if not has_rpg() or not event is InputEventMouseButton or event.button_index!=MOUSE_BUTTON_RIGHT or not event.pressed: return
	if hud_actor().input_router.cancel_cast_from_pointer():
		get_viewport().set_input_as_handled()
		return
	_operation(hud_actor().inventory.assign_quick_slot(index,""),hud_actor().inventory.last_error,"快捷槽 %d 已清空。"%(index+1))
	rpg.arena.notify(rpg_note)
	get_viewport().set_input_as_handled()

func hud_actor() -> Node:
	return rpg.arena.controlled_actor() if has_rpg() else null

func _hud_action(kind: String,index: int) -> void:
	if not has_rpg(): return
	var controlled: Node = hud_actor()
	if not controlled.is_human_controlled() or controlled.control_input_blocked(): return
	if kind=="skill": controlled.skill_casting.press(index,"hud")
	elif kind=="movement": controlled.movement_actions.press("jump" if index==0 else "crouch","hud")
	elif kind=="quick": _operation(controlled.inventory.use_quick_slot(index),controlled.inventory.last_error,"已使用快捷物品。")
	elif kind=="weapon": controlled.combat.weapon_action("PRIMARY_TAP" if index==0 else "SECONDARY_TAP")
	if kind=="quick": rpg.arena.notify(rpg_note)

func _ready() -> void:
	PREFERENCES.apply_audio_preferences()
	preview_levels=PREFERENCES.get_audio_levels()
	BINDINGS.restore_preferences()
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR
	portrait=TextureRect.new()
	portrait.mouse_filter=Control.MOUSE_FILTER_IGNORE
	portrait.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	portrait.material=ShaderMaterial.new()
	portrait.material.shader=preload("res://shaders/frontend/round_portrait.gdshader")
	add_child(portrait)
	portrait.visible=game_mode
	hud_buttons=Control.new()
	hud_buttons.mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(hud_buttons)
	minimap=MINIMAP.new()
	add_child(minimap)
	minimap.requested_map.connect(show_panel.bind("map"))
	minimap.visible=false
	backdrop=ColorRect.new()
	backdrop.mouse_filter=Control.MOUSE_FILTER_IGNORE
	backdrop.material=ShaderMaterial.new()
	backdrop.material.shader=preload("res://shaders/frontend/book_backdrop.gdshader")
	backdrop.visible=false
	add_child(backdrop)
	shield=Control.new()
	shield.mouse_filter=Control.MOUSE_FILTER_STOP
	shield.mouse_force_pass_scroll_events=false
	shield.visible=false
	add_child(shield)
	book_surface=SubViewportContainer.new()
	book_surface.mouse_filter=Control.MOUSE_FILTER_STOP
	book_surface.mouse_force_pass_scroll_events=false
	book_surface.focus_mode=Control.FOCUS_NONE
	book_surface.visible=false
	book_surface.material=ShaderMaterial.new()
	book_surface.material.shader=PRINT
	add_child(book_surface)
	book_view=SubViewport.new()
	book_view.name="InkAndPaper"
	book_view.disable_3d=true
	book_view.transparent_bg=true
	book_view.render_target_update_mode=SubViewport.UPDATE_DISABLED
	book_surface.add_child(book_view)
	cover=BindingCanvas.new()
	cover.ui=self
	cover.z_index=-3
	cover.mouse_filter=Control.MOUSE_FILTER_IGNORE
	book_view.add_child(cover)
	paper=BookCanvas.new()
	paper.z_index=-1
	paper.ui=self
	paper.texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	paper.mouse_filter=Control.MOUSE_FILTER_IGNORE
	book_view.add_child(paper)
	paper_doll=TextureRect.new()
	paper_doll.mouse_filter=Control.MOUSE_FILTER_IGNORE
	paper_doll.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	paper_doll.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	paper_doll.material=ShaderMaterial.new()
	paper_doll.material.shader=preload("res://shaders/frontend/journal_portrait.gdshader")
	paper_doll.visible=false
	book_view.add_child(paper_doll)
	modal=Control.new()
	modal.mouse_filter=Control.MOUSE_FILTER_STOP
	book_view.add_child(modal)
	motion=MOTION.new()
	motion.material=book_surface.material
	motion.visible=false
	add_child(motion)
	unfolded_map=CHART.new()
	unfolded_map.visible=false
	add_child(unfolded_map)
	unfolded_map.closed.connect(close_panel)
	unfolded_map.dismissed.connect(_finish_close)
	get_viewport().size_changed.connect(resize_ui)
	binding_signature=BINDINGS.signature()
	resize_ui()

func resize_ui() -> void:
	var window := get_viewport().get_visible_rect().size
	var factor := minf(window.x/1280.0,window.y/720.0)
	scale=Vector2.ONE*factor
	logical_size=window/factor
	size=logical_size
	minimap.position=Vector2(logical_size.x-229,37)
	unfolded_map.size=logical_size
	modal.size=logical_size
	backdrop.size=logical_size
	shield.size=logical_size
	cover.size=logical_size
	cover.queue_redraw()
	paper.size=logical_size
	book_view.size=Vector2i(logical_size)
	book_surface.size=logical_size
	panel_rect=Rect2((logical_size-BOOK_SIZE)*.5-Vector2(0,6),BOOK_SIZE)
	paper_doll.position=panel_rect.position+Vector2(29,112)
	paper_doll.size=Vector2(224,407)
	motion.size=logical_size
	motion.canvas_size=logical_size
	motion.book_rect=panel_rect
	book_surface.material.set_shader_parameter("sheet_origin",panel_rect.position)
	book_surface.material.set_shader_parameter("canvas_size",logical_size)
	_rebuild_hud_buttons()
	if panel!="": _build_modal()
	_refresh()

func _guide(parent: Control,role: String,kind: String,rect: Rect2,action: Callable=Callable(),caption := "",selected := false) -> Button:
	var b := GUIDE_BUTTON.new()
	b.role=role
	if role in ["bookmark","top_bookmark","close"]: b.z_index=-2
	b.kind=kind
	b.position=rect.position
	b.size=rect.size
	b.caption=caption
	b.selected=selected
	parent.add_child(b)
	if parent==hud_buttons: b.focus_mode=Control.FOCUS_NONE
	if action.is_valid(): b.pressed.connect(action)
	return b

func _button(title: String,rect: Rect2,action: Callable,selected := false,font_size := 20,role := "text") -> Button:
	var b := _guide(modal,role,"",rect,action,"",selected)
	b.text=title
	b.label_size=font_size
	return b

func hud_slot_rect(index: int) -> Rect2:
	return Rect2(logical_size.x*.5-191+index*54+(4 if index>=3 else 0),logical_size.y-57,48,50)

func hud_movement_rect(index: int) -> Rect2:
	return Rect2(hud_slot_rect(0).position+Vector2(-31,index*26),Vector2(24,24))

func hud_movement_tooltip(index: int) -> String:
	var kind := "jump" if index==0 else "crouch"
	var key := "Z" if index==0 else "C"
	var detail := "跳跃：选择落点沿弧线跳过去。\n每 2 米一圈：0 / 1 / 2… 点体力；外圈随体力恢复扩展。" if index==0 else "蹲下 / 站起：切换自身姿态，蹲行速度减半。"
	detail += "\n" + ("按住 %s 选取，松开确认" % key if PREFERENCES.get_cast_mode("move_"+kind)==PREFERENCES.CAST_QUICK else "点按 %s 选取，再按一次或左键确认" % key)
	return detail+"\n右键取消 · 设置中可独立选择施法模式"

func hud_weapon_rect(index: int) -> Rect2:
	var first_width: float=lerpf(146,88,_weapon_focus)
	return Rect2(122 if index==0 else 129+first_width,125,first_width if index==0 else 234-first_width,24)

func hud_skill_icon(action: Dictionary) -> String:
	if action.is_empty(): return ""
	if action.get("attack_kind", "") == "GRAB" or action.get("grab", false): return "fist"
	return "sword" if action.get("presentation_type", "") == "WEAPON_ACTION" else "crystal"

func hud_skill_tooltip(action: Dictionary, slot := -1) -> String:
	if action.is_empty(): return "未备战技能"
	var detail := "%s\n%s\n%s · 冷却 %s 秒" % [action.get("name", "技能"), RPG_VIEW.description(action), RPG_VIEW.costs(action.get("costs", {})), RPG_VIEW.number(float(action.get("cooldown", 0)))]
	if float(action.get("range", 0)) > 0: detail += "\n范围 %s 米" % RPG_VIEW.number(float(action.range))
	if slot >= 0:
		detail += "\n" + ("按住 %s 瞄准，松开释放" % BINDINGS.label(slot) if PREFERENCES.get_cast_mode(String(BINDINGS.ACTIONS[slot]))==PREFERENCES.CAST_QUICK else "点按 %s 选取，再按一次或左键释放" % BINDINGS.label(slot))
		detail += "\n点击图标选取，左键确认 · 右键取消"
	return detail

func hud_weapon_icon(index: int) -> String:
	var controlled: Node = hud_actor()
	if controlled.innate_actions.is_empty(): return RPG_VIEW.icon(controlled.loadout.weapon_at(index))
	if index == 1 and not controlled.shield_definition().is_empty(): return "shield"
	var action: Dictionary = controlled.action_for("PRIMARY_TAP" if index == 0 else "SECONDARY_TAP")
	return {"UNARMED":"fist", "SINGLE_BLADE":"sword", "TWO_HANDED":"greatsword", "HEAVY_2H":"axe", "POLEARM":"spear", "BOW":"bow", "CROSSBOW":"bow", "STAFF_OR_ORB":"staff", "CASTER":"staff"}.get(action.get("animation_family", ""), "orb" if action.get("presentation_type", "") == "CASTER_ACTION" else "fist")

func hud_resource() -> String:
	return "Energy"

func hud_energy_rect() -> Rect2:
	return Rect2(121, 85, 183, 14)

func hud_energy_ratio() -> float:
	return ENERGY_BAR.ratio(hud_actor().resources.current("Energy"), hud_actor().resources.max_value("Energy")) if has_rpg() else .72

func _rebuild_hud_buttons() -> void:
	quick_buttons.clear()
	movement_buttons.clear()
	for child in hud_buttons.get_children(): child.free()
	portrait.position=Vector2(31,29)
	portrait.size=Vector2(72,72)
	var face := Button.new()
	face.position=Vector2(25,24)
	face.size=Vector2(88,90)
	face.tooltip_text="角色 · 职业 · 装备"
	face.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	face.mouse_force_pass_scroll_events=false
	face.focus_mode=Control.FOCUS_NONE
	A.invisible_button(face)
	hud_buttons.add_child(face)
	face.pressed.connect(show_panel.bind("character"))
	var journal := Button.new()
	journal.position=Vector2(28,178)
	journal.size=Vector2(150,35)
	journal.focus_mode=Control.FOCUS_NONE
	journal.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	journal.mouse_force_pass_scroll_events=false
	A.invisible_button(journal)
	hud_buttons.add_child(journal)
	journal.pressed.connect(show_panel.bind("journal"))
	for i in range(2):
		var id: String=["settings","journal"][i]
		var b := _guide(hud_buttons,"utility",id,Rect2(logical_size.x-57,91+i*46,42,42),show_panel.bind(id))
		b.tooltip_text=["设置  Esc","冒险手记  X"][i]
	for i in range(2):
		var movement := HUD_MOVEMENT.new()
		movement.kind="jump" if i==0 else "crouch"
		movement.position=hud_movement_rect(i).position
		movement.size=hud_movement_rect(i).size
		movement.tooltip_text=hud_movement_tooltip(i)
		movement.pressed.connect(_hud_action.bind("movement",i))
		hud_buttons.add_child(movement)
		movement_buttons["move_"+movement.kind]=movement
	for i in range(7):
		var b := HUD_SLOT.new()
		b.position=hud_slot_rect(i).position
		b.size=hud_slot_rect(i).size
		var action: StringName=BINDINGS.ACTIONS[i] if i<3 else BINDINGS.QUICK_ACTIONS[i-3]
		b.caption=BINDINGS.action_label(action,BINDINGS.label(i) if i<3 else str(i-2))
		b.kind=skill_at(active_slots[i]).kind if i<3 else ["potion","potion","crystal","apple"][i-3]
		if has_rpg():
			if i<3:
				var skill: Dictionary=hud_actor().skill_at(i)
				var id: String=skill.get("id", "")
				b.kind=hud_skill_icon(skill)
				b.content_icon=hud_actor().loadout.database.get_content_icon("skills",id)
				b.tooltip_text=hud_skill_tooltip(skill,i)
				b.disabled=id.is_empty()
				b.pressed.connect(_hud_action.bind("skill",i))
			else:
				var id: String=hud_actor().inventory.quickslots[i-3]
				var definition: Dictionary=hud_actor().inventory.definition(id)
				b.kind=RPG_VIEW.icon(definition) if not id.is_empty() else ""
				b.content_icon=hud_actor().loadout.database.get_content_icon("items",id)
				b.quantity=str(hud_actor().inventory.count(id)) if not id.is_empty() else ""
				b.tooltip_text=definition.get("name","空快捷槽")+"\n左键使用 · 右键清空此槽"
				# An exhausted assignment remains right-clickable so the user can clear it.
				b.pressed.connect(_hud_action.bind("quick",i-3))
				b.gui_input.connect(_quick_slot_input.bind(i-3))
		hud_buttons.add_child(b)
		quick_buttons[action]=b
	hud_buttons.visible=game_mode and panel==""

func bind_map(world: Node3D,player: Node3D) -> void:
	if is_instance_valid(world): minimap.bind_world(world,player)
	else:
		unfolded_map.chart.material.set_shader_parameter("atlas",null)
		unfolded_map.chart.texture=null
		minimap.clear_world()

func set_game_mode(enabled: bool) -> void:
	game_mode=enabled
	minimap.visible=enabled
	if not enabled: bind_map(null,null)
	portrait.visible=enabled
	hud_buttons.visible=enabled and panel==""
	queue_redraw()

func show_region(title: String,subtitle := "") -> void:
	region_name=title
	region_subtitle=subtitle
	region_clock=6.2
	queue_redraw()

func is_animating() -> bool: return transition!="" or (is_instance_valid(unfolded_map) and unfolded_map.animating())

func show_panel(next: String) -> void:
	if transition!="" or panel==next: return
	if next=="map":
		if not game_mode: return
		if panel!="": close_panel(true)
		panel="map"
		hud_buttons.visible=false
		backdrop.visible=true
		backdrop.material.set_shader_parameter("amount",1.0)
		shield.visible=true
		unfolded_map.present(minimap)
		modal_changed.emit(true)
		return
	if panel=="map": close_panel(true)
	if panel!="":
		var order := ["character","bag","skills","journal","settings","new"]
		_turn_page.call_deferred(_set_panel.bind(next),1 if order.find(next)>order.find(panel) else -1)
		return
	focus_before_modal=get_viewport().gui_get_focus_owner()
	panel=next
	book_age=0
	_reset_transients()
	hud_buttons.visible=false
	backdrop.visible=true
	shield.visible=true
	book_view.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	_build_modal()
	modal_changed.emit(true)
	transition="opening"
	motion_ready=false
	motion.progress=0
	motion.mode="open"
	motion_ticket+=1
	_prepare_motion.call_deferred(motion_ticket)

func _set_panel(next: String) -> void:
	panel=next
	_reset_transients()

func _reset_transients() -> void:
	career_forget_confirm=false
	journey_memo_open=false
	ink_open=false
	ink_progress=0
	awaiting_binding=-1
	binding_note=""
	loadout_slot=-1
	quick_picker=false
	discard_confirm=false
	equipment_picker=false

func _prepare_motion(ticket: int) -> void:
	await get_tree().process_frame
	if DisplayServer.get_name()!="headless": await RenderingServer.frame_post_draw
	else: await get_tree().process_frame
	if ticket!=motion_ticket or panel=="": return
	motion.current=book_view.get_texture()
	motion.visible=true
	motion_ready=true
	motion.queue_redraw()

func _turn_page(change: Callable,direction := 1) -> void:
	if transition!="" or panel=="": return
	var image: Image=book_view.get_texture().get_image() if DisplayServer.get_name()!="headless" else null
	if image and not image.is_empty(): motion.previous=ImageTexture.create_from_image(image)
	else: motion.previous=null
	book_surface.visible=false
	transition="turning"
	motion_ready=false
	motion.mode="turn"
	motion.direction=direction
	motion.progress=0
	motion.current=motion.previous
	motion.visible=true
	motion.queue_redraw()
	change.call()
	_build_modal()
	motion_ticket+=1
	_prepare_motion.call_deferred(motion_ticket)

func close_panel(immediate := false) -> void:
	if panel=="": return
	if panel=="map":
		if immediate: _finish_close()
		else: unfolded_map.dismiss()
		return
	if immediate:
		_finish_close()
		return
	if transition=="closing": return
	if transition=="turning" or (transition=="opening" and not motion_ready):
		pending_close=true
		return
	book_surface.visible=false
	motion.current=book_view.get_texture()
	motion.mode="open"
	if transition!="opening": motion.progress=1
	motion.visible=true
	motion_ready=true
	transition="closing"

func _finish_close() -> void:
	unfolded_map.visible=false
	motion_ticket+=1
	panel=""
	transition=""
	motion_ready=false
	pending_close=false
	motion.release()
	book_surface.visible=false
	book_view.render_target_update_mode=SubViewport.UPDATE_DISABLED
	backdrop.visible=false
	shield.visible=false
	paper_doll.visible=false
	item_buttons.clear()
	skill_buttons.clear()
	ink_buttons.clear()
	career_buttons.clear()
	_reset_transients()
	for node in modal.get_children(): node.queue_free()
	book_view.gui_release_focus()
	hud_buttons.visible=game_mode
	modal_changed.emit(false)
	if game_mode: get_viewport().gui_release_focus()
	if is_instance_valid(focus_before_modal) and focus_before_modal.is_visible_in_tree(): focus_before_modal.grab_focus()
	_refresh()
	var action := close_action
	close_action=""
	if action=="title": return_to_title.emit()
	elif action=="begin": begin_adventure.emit()

func request_escape() -> void:
	if career_forget_confirm:
		_cancel_forget_career()
	elif awaiting_binding>=0:
		awaiting_binding=-1
		binding_note=""
		_build_modal.call_deferred()
	elif ink_open or ink_progress>0: _cancel_ink()
	elif loadout_slot>=0:
		loadout_slot=-1
		_build_modal.call_deferred()
	else: close_panel()

func _build_modal() -> void:
	if panel in ["","map"]: return
	CAREERS.capture_focus(self)
	quest_buttons.clear()
	item_buttons.clear()
	skill_buttons.clear()
	ink_buttons.clear()
	career_buttons.clear()
	for node in modal.get_children(): node.free()
	CAREERS.refresh(self)
	cover.queue_redraw()
	CONTROLS.build(self)
	paper_doll.visible=panel=="character" and character_tab==0
	CAREERS.animate(self,0.0)
	_refresh()

func _inventory_slot_rect(index: int) -> Rect2:
	return Rect2(panel_rect.position+Vector2(39+(index%5)*90,117+(index/5)*92),Vector2(84,84))

func _switch_panel(id: String) -> void: show_panel.call_deferred(id)

func _select_inventory_tab(index: int) -> void:
	if index==inventory_tab: return
	_turn_page.call_deferred(func():
		inventory_tab=index
		inventory_page=0
		var items := _displayed_items()
		if not selected_item in items and not items.is_empty(): selected_item=items[0]
	,1 if index>inventory_tab else -1)

func _select_character_tab(index: int) -> void:
	if index==character_tab: return
	_turn_page.call_deferred(func(): character_tab=index; loadout_slot=-1; equipment_picker=false; career_picker=index==1,1 if index>character_tab else -1)

func _select_settings_tab(index: int) -> void:
	if index==settings_tab: return
	_turn_page.call_deferred(func(): settings_tab=index; awaiting_binding=-1; binding_note="",1 if index>settings_tab else -1)

func _select_equipment(index: int) -> void:
	selected_equipment=index
	equipment_choice_page=0
	if has_rpg(): equipment_picker=true; career_picker=false
	_build_modal.call_deferred()

func _select_skill(index: int) -> void:
	selected_skill=index
	ink_open=false
	ink_progress=0
	_build_modal.call_deferred()

func can_learn(index: int) -> bool:
	if has_rpg(): return index>=0 and index<skills().size() and not skill_at(index).passive and rpg.progression.can_learn(skill_at(index).id).is_empty()
	var parent: int=skill_at(index).parent
	return not learned_skills.has(index) and skill_points>0 and (parent<0 or learned_skills.has(parent))

func _learn_skill() -> void:
	if not can_learn(selected_skill): return
	if has_rpg():
		_operation(rpg.progression.learn_skill(skill_at(selected_skill).id),rpg.progression.last_error,"已研习「"+skill_at(selected_skill).name+"」。")
		return
	learned_skills[selected_skill]=true
	skill_points-=1
	_build_modal.call_deferred()

func _open_ink() -> void:
	if not learned_skills.has(selected_skill): return
	ink_open=true
	ink_progress=0
	_build_modal.call_deferred()

func _cancel_ink() -> void:
	ink_open=false
	for b: Button in ink_buttons.values(): b.disabled=true

func _place_skill(skill: int,slot: int,passive: bool,group := -1) -> bool:
	if not learned_skills.has(skill) or bool(skill_at(skill).passive)!=passive: return false
	if group<0: group=preparation_set
	if has_rpg():
		if passive: return false
		var success: bool=rpg.loadout.assign_skill(group,slot,skill_at(skill).id)
		_operation(success,rpg.loadout.last_error,"")
		return success
	var slots: Array[int]=passive_slots if passive else group_slots(group)
	if slot<0 or slot>=slots.size(): return false
	var old := slots.find(skill)
	if old>=0 and old!=slot: slots[old]=slots[slot]
	slots[slot]=skill
	_rebuild_hud_buttons()
	return true

func _assign_ink(slot: int) -> void:
	var passive: bool=skill_at(selected_skill).passive
	if _place_skill(selected_skill,slot if passive else slot%3,passive,0 if passive else slot/3): _cancel_ink()

func _open_loadout(slot: int,passive: bool,group := 0) -> void:
	preparation_set=group
	loadout_choice_page=0
	if has_rpg() and passive:
		if passive_slots[slot]>=0: selected_skill=passive_slots[slot]; show_panel("skills")
		return
	loadout_slot=slot
	loadout_passive=passive
	_build_modal.call_deferred()

func _select_loadout(skill: int) -> void:
	_place_skill(skill,loadout_slot,loadout_passive)
	loadout_slot=-1
	_build_modal.call_deferred()

func _cancel_loadout() -> void:
	loadout_slot=-1
	_build_modal.call_deferred()

func _bind_key(slot: int) -> void:
	awaiting_binding=slot
	binding_note="请按下新的按键，Esc 取消。"
	_build_modal.call_deferred()

func capture_binding(event: InputEventKey) -> bool:
	if awaiting_binding<0 or not event.pressed or event.echo: return false
	if event.keycode==KEY_ESCAPE:
		awaiting_binding=-1
		binding_note=""
	elif BINDINGS.assign(awaiting_binding,event):
		binding_note="已写下新的按键。"
		awaiting_binding=-1
		_refresh_bindings()
	else: binding_note=BINDINGS.last_error
	_build_modal.call_deferred()
	return true

func _refresh_bindings() -> void:
	binding_signature=BINDINGS.signature()
	_rebuild_hud_buttons()
	if panel!="" and transition=="": _build_modal.call_deferred()

func _select_item(index: int) -> void:
	selected_item=index
	discard_confirm=false
	_build_modal.call_deferred()
	if has_rpg():
		rpg_note=""
		quick_picker=false
	for key: int in item_buttons:
		item_buttons[key].selected=key==index
		item_buttons[key].queue_redraw()
	_refresh()

func _select_quest(index: int) -> void:
	journey_memo_open=false
	if has_rpg():
		var entry: Dictionary=quest_at(index)
		if entry.is_empty(): return
		selected_quest_id=entry.id
		quest_detail_scroll=0
	selected_quest=index
	_build_modal.call_deferred()

func _show_journey_memo(open: bool) -> void:
	if panel!="journal" or not transition.is_empty(): return
	_turn_page.call_deferred(func(): journey_memo_open=open,1 if open else -1)

func _journey_memo_scroll_changed(value: float) -> void:
	journey_memo_scroll=roundi(value)

func _track_quest() -> void:
	if has_rpg():
		var entry: Dictionary=quest_at(selected_quest)
		if entry.is_empty() or entry.status=="rewarded": return
		var host: Node=rpg.get("game")
		var id: String="" if tracked_quest_id==entry.id else entry.id
		host.world_state.set_flag(TRACKED_QUEST_FLAG,id)
		_queue_rpg_refresh()
		return
	tracked_quest=selected_quest
	_build_modal.call_deferred()

func _set_level(value: float,index: int) -> void:
	var result: Error=PREFERENCES.set_audio_level(index,value)
	preview_levels=PREFERENCES.get_audio_levels()
	save_note="音量设置已保存。" if result==OK else "设置保存失败，音量保持原值。"
	if result!=OK: _build_modal.call_deferred()
	_refresh()

func _toggle_cast_mode(index: int) -> void:
	var action: String = PREFERENCES.CAST_ACTIONS[index]
	var mode := PREFERENCES.CAST_PRECISE if PREFERENCES.get_cast_mode(action)==PREFERENCES.CAST_QUICK else PREFERENCES.CAST_QUICK
	var result: Error = PREFERENCES.set_cast_mode(action,mode)
	var key_label := BINDINGS.label(index) if index<3 else ("Z" if index==3 else "C")
	binding_note = "%s：%s" % [key_label,"按住选取，松开确认。" if mode==PREFERENCES.CAST_QUICK else "点按选取，再按一次或左键确认。"] if result==OK else "施法模式保存失败，原设置仍然有效。"
	_build_modal.call_deferred()

func _reset_settings_tab() -> void:
	var success := false
	if settings_tab==0:
		success=PREFERENCES.reset_audio()==OK
		preview_levels=PREFERENCES.get_audio_levels()
	elif settings_tab==1:
		success=BINDINGS.reset_defaults() and PREFERENCES.reset_cast_modes()==OK
		if success:
			awaiting_binding=-1
			binding_note="已恢复按键与 Q / E / R / Z / C 快速施法。"
			_refresh_bindings()
	else: success=PREFERENCES.set_damage_numbers(true)==OK
	save_note="本页设置已恢复默认。" if success else "设置保存失败，原设置仍然有效。"
	_build_modal.call_deferred()
	_refresh()

func _select_layout(index: int) -> void:
	preview_choice=index
	_build_modal.call_deferred()

func _toggle_damage_numbers() -> void:
	var result: Error=PREFERENCES.set_damage_numbers(not PREFERENCES.get_damage_numbers())
	if result!=OK: save_note="设置保存失败，请稍后重试。"
	_build_modal.call_deferred()
	_refresh()

func _save_journey() -> void:
	save_requested.emit()
	_refresh()

func _return() -> void:
	close_action="title"
	close_panel()

func _begin() -> void:
	close_action="begin"
	close_panel()

func _displayed_items() -> Array[int]:
	var result: Array[int]=[]
	for i in range(items().size()):
		if has_rpg():
			var category: String=items()[i].category
			if inventory_tab==0 or inventory_tab==1 and category=="weapon" or inventory_tab==2 and category=="equipment" or inventory_tab==3 and category=="consumable" or inventory_tab==4 and category not in ["weapon","equipment","consumable"]: result.append(i)
			continue
		var type: String=items()[i].type
		if inventory_tab==0 or (inventory_tab==1 and type in ["单手剑","弓"]) or (inventory_tab==2 and type=="素材") or (inventory_tab==3 and type in ["食物","补给"]) or (inventory_tab==4 and type=="任务物品"): result.append(i)
	return result

func blocks_world_pointer(at: Vector2) -> bool:
	if panel!="": return true
	if not game_mode: return false
	var local := get_global_transform().affine_inverse()*at
	if local.distance_to(Vector2(logical_size.x-147,119))<88: return true
	for child in hud_buttons.get_children():
		if child is Button and child.is_visible_in_tree() and child.get_global_rect().has_point(at): return true
	return false

func _refresh() -> void:
	queue_redraw()
	if is_instance_valid(paper): paper.queue_redraw()

func _process(delta: float) -> void:
	elapsed+=delta
	if region_clock>0:
		region_clock=maxf(0,region_clock-delta)
		queue_redraw()
	hud_buttons.modulate.a=hud_alpha
	portrait.modulate.a=hud_alpha
	if is_instance_valid(portrait_studio): portrait_studio.sync_actor(hud_actor())
	if BINDINGS.signature()!=binding_signature: _refresh_bindings()
	var focus: float=float(hud_actor().loadout.current_set) if has_rpg() else 0.0
	if _weapon_focus != focus:
		_weapon_focus=lerpf(_weapon_focus,focus,1.0-exp(-delta*12.0))
		if absf(_weapon_focus-focus)<.0001: _weapon_focus=focus
		queue_redraw()
	hud_resource_id=hud_resource()
	if panel=="map": backdrop.material.set_shader_parameter("amount",unfolded_map.open_amount())
	if has_rpg():
		minimap.player_node=hud_actor()
		for i in range(2):
			var id := "move_jump" if i==0 else "move_crouch"
			if movement_buttons.has(id):
				var button: Button=movement_buttons[id]
				button.selected=hud_actor().movement_actions.selection==("jump" if i==0 else "crouch") or i==1 and hud_actor().movement_actions.crouching
				button.disabled=not hud_actor().is_human_controlled() or hud_actor().movement_actions.airborne
				button.tooltip_text=hud_movement_tooltip(i)
		for i in range(7):
			var action: StringName=BINDINGS.ACTIONS[i] if i<3 else BINDINGS.QUICK_ACTIONS[i-3]
			var definition: Dictionary=hud_actor().skill_at(i) if i<3 else hud_actor().inventory.definition(hud_actor().inventory.quickslots[i-3])
			var id: String=definition.get("id", "")
			if quick_buttons.has(action):
				quick_buttons[action].cooldown=float(hud_actor().combat.cooldowns.get(id,0.0)) if i<3 else float(hud_actor().inventory.cooldowns.get(id,0.0))
				quick_buttons[action].kind=hud_skill_icon(definition) if i<3 else RPG_VIEW.icon(definition)
				quick_buttons[action].tooltip_text=hud_skill_tooltip(definition,i) if i<3 else definition.get("name", "空槽")
				quick_buttons[action].aiming=i<3 and hud_actor().skill_casting.slot==i
				quick_buttons[action].disabled=(id.is_empty() if i<3 else false) or not hud_actor().is_human_controlled()
				if i>=3: quick_buttons[action].quantity=str(hud_actor().inventory.count(id)) if not id.is_empty() else ""
	if panel!="" and panel!="map":
		book_view.render_target_update_mode=SubViewport.UPDATE_ALWAYS
		book_age+=delta
		if panel=="character" and character_tab==1 and transition=="": CAREERS.animate(self,delta)
		if motion_ready and transition!="":
			var direction := -1.0 if transition=="closing" else 1.0
			var duration := CLOSE_SECONDS if transition=="closing" else (TURN_SECONDS if transition=="turning" else OPEN_SECONDS)
			motion.progress=clampf(motion.progress+delta*direction/duration,0,1)
			motion.queue_redraw()
			backdrop.material.set_shader_parameter("amount",motion.progress if transition!="turning" else 1.0)
			if transition=="closing" and motion.progress<=0: _finish_close()
			elif transition!="closing" and motion.progress>=1:
				transition=""
				motion.release()
				book_surface.visible=true
				if panel=="journal": _build_modal.call_deferred()
				if pending_close: pending_close=false; close_panel()
		if ink_open or ink_progress>0:
			ink_progress=move_toward(ink_progress,1.0 if ink_open else 0.0,delta/ .58)
			for b: Button in ink_buttons.values():
				b.reveal=ink_progress
				b.disabled=not ink_open or ink_progress<.85 or b.get_meta("blocked",false)
				b.queue_redraw()
			if ink_progress<=0: _build_modal.call_deferred()
			paper.queue_redraw()
	# Resource/quest/loadout signals invalidate normal HUD changes. Controlled
	# companions have their own resources, so also observe the displayed actor.
	if has_rpg():
		var actor: Node=hud_actor()
		var state: Array=[actor, actor.resources.current("HP"), actor.resources.max_value("HP"),
			actor.resources.current("Energy"), actor.resources.max_value("Energy"), actor.loadout.level, actor.progression.experience]
		if state != _hud_draw_state:
			_hud_draw_state=state
			queue_redraw()
	_hud_hint_clock+=delta
	if _hud_hint_clock>=1.0:
		_hud_hint_clock=0.0
		queue_redraw() # Encounter respawn hints may change without a quest event.

func _input(event: InputEvent) -> void:
	if game_mode and panel=="" and event is InputEventKey and event.pressed and not event.echo:
		for action in movement_buttons:
			if event.is_action_pressed(action): movement_buttons[action].pulse=1.0
		for action: StringName in BINDINGS.ACTIONS+BINDINGS.QUICK_ACTIONS:
			if InputMap.has_action(action) and event.is_action_pressed(action) and quick_buttons.has(action): quick_buttons[action].pulse=1.0
		if quick_buttons.has(event.keycode): quick_buttons[event.keycode].pulse=1.0

func _draw() -> void:
	if game_mode: _draw_hud()

func _draw_book(c: CanvasItem) -> void: PAGES.draw(self,c,panel_rect.position)

func _exit_tree() -> void:
	bind_rpg(null)
	bind_map(null,null)
	motion_ticket+=1
	if is_instance_valid(paper): paper.ui=null
	if is_instance_valid(cover): cover.ui=null
	if is_instance_valid(portrait): portrait.texture=null
	if is_instance_valid(paper_doll): paper_doll.texture=null
	if is_instance_valid(motion): motion.release()
	if is_instance_valid(book_surface): book_surface.material=null

func _draw_hud() -> void:
	var live := has_rpg()
	draw_arc(Vector2(67,65),38,0,TAU,72,Color("d9dec1"),2,true)
	draw_arc(Vector2(67,65),41,.2,2.65,40,Color(A.PAPER,.30),1,true)
	var hud_name: String=(rpg_state.name if hud_actor()==rpg else hud_actor().display_name) if live else "桐人"
	var name_size := 20
	while name_size>12 and A.font(700).get_string_size(hud_name,HORIZONTAL_ALIGNMENT_LEFT,-1,name_size).x>94: name_size-=1
	while hud_name.length()>1 and A.font(700).get_string_size(hud_name,HORIZONTAL_ALIGNMENT_LEFT,-1,name_size).x>94: hud_name=hud_name.left(-2)+"…"
	A.text(self,Vector2(122,49),hud_name,name_size,A.PAPER,700)
	var experience_ratio: float=clampf(float(hud_actor().progression.experience)/maxf(1,hud_actor().progression.to_next_level()),0,1) if live else .28
	draw_line(Vector2(224,42),Vector2(288,42),Color(A.PAPER,.26),3,true)
	draw_line(Vector2(224,42),Vector2(224+64*experience_ratio,42),Color("d1cc97"),3,true)
	A.text(self,Vector2(300,48),"Lv. %02d"%hud_actor().loadout.level if live else "Lv. 01",13,A.PAPER,600)
	var health_outline:=PackedVector2Array([Vector2(128,63),Vector2(365,63),Vector2(358,85),Vector2(121,85)])
	draw_colored_polygon(health_outline,Color("293d31"))
	var health_ratio: float=clampf(hud_actor().resources.current("HP")/maxf(1,hud_actor().resources.max_value("HP")),0,1) if live else 1.0
	if health_ratio>0:
		var right: float=124+238*health_ratio
		var interior:=PackedVector2Array([Vector2(129,66),Vector2(362,66),Vector2(357,82),Vector2(124,82)])
		var clip:=PackedVector2Array([Vector2(124,66),Vector2(right,66),Vector2(right,82),Vector2(124,82)])
		for filled in Geometry2D.intersect_polygons(interior,clip):
			if filled.size()>=3: draw_colored_polygon(filled,Color("82ac73"))
	health_outline.append(health_outline[0])
	draw_polyline(health_outline,Color(A.PAPER,.55),1,true)
	A.text(self,Vector2(134,78),"HP",10,Color("f4f1d9"),700)
	var hp_label: String="%d / %d"%[hud_actor().resources.current("HP"),hud_actor().resources.max_value("HP")] if live else "320 / 320"
	var hp_width: float=A.font(700).get_string_size(hp_label,HORIZONTAL_ALIGNMENT_LEFT,-1,10).x
	A.text(self,Vector2(351-hp_width,78),hp_label,10,Color("f4f1d9"),700)
	ENERGY_BAR.draw_bar(self,hud_energy_rect(),hud_actor().resources.current("Energy") if live else 43.2,hud_actor().resources.max_value("Energy") if live else 60.0)
	for i in range(2):
		HUD_WEAPONS.draw(self,hud_weapon_icon(i) if live else ["sword","bow"][i],hud_weapon_rect(i),1.0-_weapon_focus if i==0 else _weapon_focus)

	A.icon(self,"journal",Vector2(43,195),12,A.PAPER)
	A.text(self,Vector2(65,201),"冒险手记",13,A.PAPER,600)
	A.text(self,Vector2(128,200),"  X  ›",11,Color("c7d5b9"))
	draw_line(Vector2(32,214),Vector2(243,214),Color(A.PAPER,.28),1)
	var quest: Dictionary=tracked_quest_summary() if live else {"title":CONTENT.QUESTS[tracked_quest].title,"detail":CONTENT.QUESTS[tracked_quest].steps[1]}
	A.text(self,Vector2(34,240),quest.title.left(18),17,A.PAPER,700)
	A.diamond(self,Vector2(39,259),3.5,Color("dcd4a2"),false)
	A.text(self,Vector2(52,264),quest.detail.left(26),12,A.PAPER)
	_minimap(Vector2(logical_size.x-147,119))
	if live and is_instance_valid(rpg.arena.host) and is_instance_valid(rpg.arena.host.get("rest_service")):
		A.text(self,Vector2(logical_size.x-245,33),rpg.arena.host.rest_service.date_text(),12,A.PAPER,600)
	if region_clock>0:
		var alpha := minf(smoothstep(0,.95,6.2-region_clock),smoothstep(0,1.5,region_clock))
		var center := Vector2(logical_size.x*.5,117-8*(1-alpha))
		A.centered(self,center+Vector2(0,2),region_name,38,Color(.1,.23,.17,alpha*.3),700)
		A.centered(self,center,region_name,38,Color("faf9ed",alpha),700)
		draw_line(center+Vector2(-63,17),center+Vector2(63,17),Color(A.PAPER,alpha*.6),1)
		if region_subtitle!="": A.centered(self,center+Vector2(0,43),region_subtitle,12,Color(A.PAPER,alpha*.92))

func _minimap(p: Vector2) -> void:
	draw_circle(p+Vector2(0,2),87,Color(.10,.19,.15,.50))
	draw_arc(p,84,0,TAU,96,Color("d6c79e"),2,true)
	draw_arc(p,88,0,TAU,96,Color("b8a681",.46),1,true)
	A.centered(self,p+Vector2(0,-93),"N",11,A.PAPER,600)
	var night := false
	if has_rpg() and is_instance_valid(rpg.arena.host) and is_instance_valid(rpg.arena.host.get("rest_service")):
		var minute: int=rpg.arena.host.rest_service.clock().minute
		night=minute<360 or minute>=1200
	A.icon(self,"moon" if night else "sun",p+Vector2(-48,105),10,Color("e4d8a2"))
	A.centered(self,p+Vector2(8,109),region_name,12,A.PAPER,600)

