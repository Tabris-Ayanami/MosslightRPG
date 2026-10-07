@static_unload
extends RefCounted
## A retained pencil drawing: new paths grow; discarded paths are erased.
const F=preload("res://scripts/frontend/field_guide_art.gd")
const PAGE_SIZE := 4
static var fixture_database: Dictionary={}

static func catalog(ui: Control) -> Dictionary:
	if fixture_database.is_empty(): fixture_database=JSON.parse_string(FileAccess.get_file_as_string("res://data/combat/careers.json"))
	return ui.rpg.loadout.database.careers if ui.has_rpg() else fixture_database

static func chain(ui: Control) -> Array:
	return ui.rpg.loadout.career_ids if ui.has_rpg() else ui.fixture_careers

static func options(ui: Control) -> Array:
	var db := catalog(ui)
	var selected := chain(ui)
	if not selected.is_empty(): return db.get(selected.back(), {}).get("next_careers", []).duplicate()
	var result: Array=[]
	for id in db:
		if int(db[id].get("required_level",1))==1: result.append(id)
	return result

static func page_count(ui: Control) -> int:
	return maxi(1,ceili(options(ui).size()/float(PAGE_SIZE)))

static func layout(ui: Control) -> Array[Dictionary]:
	var db := catalog(ui)
	var selected := chain(ui)
	var context := str(ui.rpg.get_instance_id()) if ui.has_rpg() else "fixture"
	context += ":"+str(selected)
	if context!=ui.career_context:
		ui.career_context=context
		ui.career_page=0
		ui.career_focus_key=""
		ui.career_detail_id=""
	ui.career_page=clampi(ui.career_page,0,page_count(ui)-1)
	var result: Array[Dictionary]=[]
	var parent := "origin"
	# The drawing shows the current step and its parent. Every ancestor remains
	# available in the focusable, horizontally scrollable path above the drawing.
	var recent := selected.slice(maxi(0,selected.size()-2))
	for i in range(recent.size()):
		var id: String=recent[i]
		result.append(node(db[id],Vector2(260,440 if recent.size()>1 and i==0 else 310),parent,true,""))
		parent=id
	var ids := options(ui).slice(ui.career_page*PAGE_SIZE,(ui.career_page+1)*PAGE_SIZE)
	for i in range(ids.size()):
		var id: String=ids[i]
		var x := 260.0+(i-(ids.size()-1)*.5)*120
		var y := 180.0 if not selected.is_empty() else 232.0
		var reason: String=ui.rpg.progression.can_choose_career(id) if ui.has_rpg() else ""
		result.append(node(db[id],Vector2(x,y),parent,false,reason))
	return result

static func change_page(ui: Control,next: int) -> void:
	ui.career_page=clampi(next,0,page_count(ui)-1)
	# The book turn itself retires the previous page. Do not superimpose its old
	# candidate controls on the next page's identical card positions.
	var retained: Array[Dictionary]=[]
	for item: Dictionary in ui.career_nodes:
		if item.chosen and not item.retiring: retained.append(item)
	ui.career_nodes=retained
	ui.career_signature=""
	ui.career_focus_key=""
	ui.career_focus_pending=true
	ui.career_detail_id=""

static func capture_focus(ui: Control) -> void:
	if ui.panel!="character" or ui.character_tab!=1: return
	if ui.career_focus_pending: return
	for control in ui.modal.find_children("*","Button",true,false):
		if control.has_focus() and control.has_meta("career_focus_key"):
			ui.career_focus_key=str(control.get_meta("career_focus_key"))
			ui.career_focus_pending=true
			return

static func fit_name(value: String) -> String:
	return fit_text(value,20,103)

static func fit_text(value: String,font_size: int,width: float) -> String:
	if F.font().get_string_size(value,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x<=width: return value
	while value.length()>1 and F.font().get_string_size(value+"…",HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x>width:
		value=value.left(-1)
	return value+"…"

static func build_controls(ui: Control,p: Vector2) -> void:
	if ui.career_forget_confirm:
		var cancel: Button=ui._button("保留当前职业",Rect2(p+Vector2(48,405),Vector2(190,43)),ui._cancel_forget_career,false,21)
		cancel.name="CareerForgetCancel"
		var confirm: Button=ui._button("遗忘并回归平民",Rect2(p+Vector2(264,405),Vector2(224,43)),ui._confirm_forget_career,false,21)
		confirm.name="CareerForgetConfirm"
		confirm.tooltip_text=ui.rpg.progression.can_forget_career()
		confirm.disabled=not confirm.tooltip_text.is_empty()
		cancel.grab_focus.call_deferred()
		return
	var focus_targets: Dictionary={}
	var first: Button
	for item: Dictionary in ui.career_nodes:
		var b: Button=ui._guide(ui.modal,"career",item.kind,Rect2(p+item.pos-Vector2(53,44),Vector2(106,111)),ui._choose_career.bind(item.id),"Lv. %d"%item.level,item.chosen)
		b.text=fit_name(item.name)
		if ui.has_rpg(): b.content_icon=ui.rpg.loadout.database.get_content_icon("careers",item.id)
		# Locked choices remain keyboard-inspectable. Progression is the authority
		# for choosing; activating one exposes the same reason without mutating it.
		b.disabled=item.chosen or item.retiring
		b.modulate.a=.62 if not item.reason.is_empty() else 1.0
		b.tooltip_text=item.name+(" · "+item.reason if not item.reason.is_empty() else "")
		b.material=ShaderMaterial.new()
		b.material.shader=preload("res://shaders/frontend/career_ink.gdshader")
		ui.career_buttons[item.id]=b
		if not b.disabled:
			bind_focus(ui,b,item.id,item.id,focus_targets)
			if first==null: first=b
	var selected := chain(ui)
	if not selected.is_empty():
		if ui.has_rpg():
			var forget: Button=ui._button("遗忘职业",Rect2(p+Vector2(43,478),Vector2(130,37)),ui._request_forget_career,false,19)
			forget.name="CareerForget"
			forget.tooltip_text=ui.rpg.progression.can_forget_career()
			forget.disabled=not forget.tooltip_text.is_empty()
			if forget.tooltip_text.is_empty(): forget.tooltip_text="保留等级与经验，回归平民后重新就职"
		var scroll := ScrollContainer.new()
		scroll.name="CareerPath"
		scroll.position=p+Vector2(43,56)
		scroll.size=Vector2(449,37)
		scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_AUTO
		scroll.vertical_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
		scroll.follow_focus=true
		scroll.mouse_force_pass_scroll_events=false
		ui.modal.add_child(scroll)
		var bar := scroll.get_h_scroll_bar()
		bar.custom_minimum_size.y=5
		var track := StyleBoxFlat.new()
		track.bg_color=Color(F.LINE,.16)
		var grabber := StyleBoxFlat.new()
		grabber.bg_color=Color(F.SAGE,.5)
		for corner in ["corner_radius_top_left","corner_radius_top_right","corner_radius_bottom_left","corner_radius_bottom_right"]: grabber.set(corner,3)
		bar.add_theme_stylebox_override("scroll",track)
		for state in ["grabber","grabber_highlight","grabber_pressed"]: bar.add_theme_stylebox_override(state,grabber)
		var path := HBoxContainer.new()
		path.add_theme_constant_override("separation",3)
		scroll.add_child(path)
		var names: Array=[""]+selected
		for id: String in names:
			var caption: String="旅人" if id.is_empty() else str(catalog(ui)[id].name)
			var b: Button=ui._button(caption+" ›" if id!=selected.back() else caption,Rect2(),ui._inspect_career.bind(id),id==selected.back(),16)
			b.reparent(path)
			b.custom_minimum_size=Vector2(F.font().get_string_size(b.text,HORIZONTAL_ALIGNMENT_LEFT,-1,16).x+14,27)
			b.tooltip_text=caption+" · 已选职业路径"
			bind_focus(ui,b,"path:"+id,id,focus_targets)
	var pages := page_count(ui)
	if pages>1:
		var previous: Button=ui._button("‹",Rect2(p+Vector2(340,479),Vector2(36,36)),ui._change_career_page.bind(-1),false,25)
		previous.name="CareerPreviousPage"
		previous.disabled=ui.career_page==0
		previous.tooltip_text="上一页职业"
		var count: Button=ui._button("%d / %d"%[ui.career_page+1,pages],Rect2(p+Vector2(377,479),Vector2(76,36)),Callable(),false,16)
		count.name="CareerPageCount"
		count.focus_mode=Control.FOCUS_NONE
		count.mouse_filter=Control.MOUSE_FILTER_IGNORE
		var following: Button=ui._button("›",Rect2(p+Vector2(454,479),Vector2(36,36)),ui._change_career_page.bind(1),false,25)
		following.name="CareerNextPage"
		following.disabled=ui.career_page>=pages-1
		following.tooltip_text="下一页职业"
		bind_focus(ui,previous,"previous","",focus_targets)
		bind_focus(ui,following,"next","",focus_targets)
	var desired: Button=focus_targets.get(ui.career_focus_key,first)
	if ui.career_focus_pending and desired!=null and not desired.disabled:
		desired.grab_focus.call_deferred()
	ui.career_focus_pending=false

static func bind_focus(ui: Control,button: Button,key: String,id: String,targets: Dictionary) -> void:
	button.set_meta("career_focus_key",key)
	button.focus_mode=Control.FOCUS_ALL
	button.focus_entered.connect(ui._focus_career.bind(key,id))
	button.mouse_entered.connect(ui._inspect_career.bind(id))
	targets[key]=button

static func node(data: Dictionary,pos: Vector2,parent: String,chosen: bool,reason: String) -> Dictionary:
	return {"id":data.id,"name":data.name,"pos":pos,"parent":parent,"chosen":chosen,"reason":reason,
		"kind":data.id,"level":data.get("required_level",1)}

static func refresh(ui: Control,force := false) -> void:
	var next := layout(ui)
	var signature := str(next)
	if not force and signature==ui.career_signature: return
	ui.career_signature=signature
	var old: Dictionary={}
	for item: Dictionary in ui.career_nodes:
		if not item.retiring or erase(item,ui.career_age)<.99: old[item.id]=item
	var result: Array[Dictionary]=[]
	for i in range(next.size()):
		var item: Dictionary=next[i]
		var previous: Dictionary=old.get(item.id,{})
		# A level/resource refresh can make a formerly locked branch available.
		# Retire only that branch's stale failure, leaving other feedback intact.
		if not previous.get("reason","").is_empty() and item.reason.is_empty() and ui.rpg_note==previous.reason:
			ui.rpg_note=""
			ui.rpg_feedback_failed=false
		item["from"]=position(previous,ui.career_age) if not previous.is_empty() else item.pos+Vector2(0,10)
		item["new"]=previous.is_empty()
		item["was_chosen"]=previous.get("chosen",false)
		item["retiring"]=false
		item["delay"]=i*.06 if previous.is_empty() else 0.0
		result.append(item)
		old.erase(item.id)
	for item: Dictionary in old.values():
		item["from"]=position(item,ui.career_age)
		item.pos=item["from"]
		item["new"]=false
		item["retiring"]=true
		item["delay"]=0.0
		result.append(item)
	ui.career_nodes=result
	ui.career_age=0.0

static func position(item: Dictionary,age: float) -> Vector2:
	return Vector2(item.get("from",item.pos)).lerp(item.pos,smoothstep(.10,.85,age))

static func grow(item: Dictionary,age: float) -> float:
	return smoothstep(item.delay,item.delay+.67,age) if item["new"] else 1.0

static func erase(item: Dictionary,age: float) -> float:
	return smoothstep(.07,.81,age) if item.retiring else 0.0

static func draw(ui: Control,c: CanvasItem,p: Vector2) -> void:
	if ui.career_forget_confirm:
		F.text(c,p+Vector2(48,158),"重新选择自己的道路",27,F.INK)
		F.text(c,p+Vector2(48,220),"保留等级、经验、背包与旅途进度。",19,F.SOFT)
		F.text(c,p+Vector2(48,258),"遗忘当前职业路线和已学职业技能。",19,F.SOFT)
		F.text(c,p+Vector2(48,296),"卸下武器，清空两组备战技能。",19,F.SOFT)
		F.text(c,p+Vector2(48,334),"重新就职后，属性按新职业计算。",19,F.SOFT)
		return
	var selected := chain(ui)
	var origin := Vector2(260,526 if selected.size()>1 else 486)
	var info := "选择一项职业，开启新的道路。" if selected.is_empty() else "已选路径 · 可横向滚动查看全部职业"
	if not selected.is_empty() and options(ui).is_empty(): info="已走到当前职业道路的终点。"
	if not ui.career_detail_id.is_empty() and catalog(ui).has(ui.career_detail_id):
		var data: Dictionary=catalog(ui)[ui.career_detail_id]
		var reason: String=ui.rpg.progression.can_choose_career(ui.career_detail_id) if ui.has_rpg() else ""
		var condition: String="已选职业" if ui.career_detail_id in selected else (reason if not reason.is_empty() else "可选择 · Lv. %d"%int(data.get("required_level",1)))
		info=fit_text(str(data.name),16,150)+" · "+fit_text(condition,16,280)
	F.text(c,p+Vector2(43,116 if not selected.is_empty() else 91),fit_text(info,16,449),16,F.SOFT)
	var positions := {"origin":origin}
	for item: Dictionary in ui.career_nodes: positions[item.id]=position(item,ui.career_age)
	for item: Dictionary in ui.career_nodes:
		var alpha := 1.0-erase(item,ui.career_age)
		if alpha<.001: continue
		var start: Vector2=positions.get(item.parent,origin)
		var end := position(item,ui.career_age)
		var t := grow(item,ui.career_age)
		var path := PackedVector2Array()
		var delta := end-start
		for i in range(45):
			var s := i/44.0*t
			var at := start+delta*s
			at.x+=sin(s*PI)*(end.x-260)*.11+sin(s*26)*.6
			path.append(p+at)
		var color := Color(F.INK if item.chosen else F.SOFT,alpha*(.85 if item.chosen else (.53 if item.reason.is_empty() else .22)))
		c.draw_polyline(path,color,1.3 if item.chosen else 1.0,true)
		for i in range(4):
			var fraction := .19+i*.14
			if t<fraction: continue
			var at: Vector2=start.lerp(end,fraction)
			var side := -1.0 if i%2==0 else 1.0
			F.pen(c,p+at,p+at+Vector2(side*(8+i*2),-8),Color(color,.35*alpha),.75)
	F.ring(c,p+origin,7,Color(F.INK,.5),.8)
	if selected.size()<2: F.centered(c,p+origin+Vector2(0,32),"旅人",17,F.SOFT)

static func animate(ui: Control,delta: float) -> void:
	if ui.career_age>=1.4 and delta>0: return
	ui.career_age+=delta
	for item: Dictionary in ui.career_nodes:
		if not ui.career_buttons.has(item.id): continue
		var button: Button=ui.career_buttons[item.id]
		button.position=ui.panel_rect.position+position(item,ui.career_age)-Vector2(53,44)
		button.reveal=grow(item,ui.career_age)
		button.material.set_shader_parameter("growth",button.reveal)
		button.material.set_shader_parameter("erasure",erase(item,ui.career_age))
		button.pencil_black=lerpf(1.0 if item.was_chosen else 0.0,1.0 if item.chosen else 0.0,smoothstep(0,.6,ui.career_age))
		button.queue_redraw()
	ui.paper.queue_redraw()
