extends RefCounted
const CONTENT_ART=preload("res://scripts/frontend/content_art.gd")
const A=preload("res://scripts/frontend/ui_art.gd")
const F=preload("res://scripts/frontend/field_guide_art.gd")
const DATA=preload("res://scripts/frontend/prototype_content.gd")
const KEYS=preload("res://scripts/frontend/journal_bindings.gd")
const CONTROLS=preload("res://scripts/frontend/journal_controls.gd")
const RACES=preload("res://rpg/race_catalog.gd")

static func heading(c: CanvasItem,p: Vector2,title: String,subtitle: String,right := false) -> void:
	var x := 641 if right else 42
	F.text(c,p+Vector2(x,43),title,26,F.INK,600)
	F.text(c,p+Vector2(x+123,41),subtitle,14,F.SOFT)

static func draw(ui: Control,c: CanvasItem,p: Vector2) -> void:
	F.book(c,p)
	match ui.panel:
		"character": character(ui,c,p)
		"bag": inventory(ui,c,p)
		"skills": skills(ui,c,p)
		"journal": journal(ui,c,p)
		"settings": settings(ui,c,p)
		"new":
			heading(c,p,"新的冒险","晨光正好")
			F.landscape(c,p+Vector2(70,340),377)
			F.text(c,p+Vector2(643,191),"向有风的地方",34,F.INK,600)
			F.text(c,p+Vector2(644,248),"穿过花与树影，去遇见新的风景。",18,F.SOFT)
	if ui.has_rpg() and ui.rpg_feedback_failed and ui.panel in ["character","bag","skills"] and not ui.rpg_note.is_empty():
		F.text(c,p+Vector2(642,66),ui.rpg_note.left(30),14,F.SAGE)

static func character(ui: Control,c: CanvasItem,p: Vector2) -> void:
	var live: bool=ui.has_rpg()
	if ui.character_tab==2:
		traits(ui,c,p)
		return
	if ui.character_tab==1:
		heading(c,p,"职业","" )
		heading(c,p,"备战","",true)
		ui.CAREERS.draw(ui,c,p)
		if ui.loadout_slot>=0:
			var slot: String=["Ⅰ","Ⅱ"][ui.loadout_slot] if ui.loadout_passive else KEYS.label(ui.loadout_slot)
			F.text(c,p+Vector2(648,107),"被动 · "+slot if ui.loadout_passive else ["A","B"][ui.preparation_set]+"  ·  "+slot,27,F.INK,600)
		else:
			for group in range(2):
				var y := 88+group*163
				F.text(c,p+Vector2(648,y),["A","B"][group],27,F.INK,600)
				var weapon: String=ui.rpg.loadout.weapon_at(group).get("name","未装备武器") if live else ["逐风之剑","旅人短弓"][group]
				F.text(c,p+Vector2(692,y-2),weapon,17,F.SOFT)
			F.text(c,p+Vector2(648,443),"常驻特性" if live else "被动",20,F.INK)
		return
	heading(c,p,"角色","" )
	heading(c,p,"装备","",true)
	F.text(c,p+Vector2(964,41),"护甲  "+str(ui.rpg_state.stats.Armor if live else 12),16,F.SOFT)
	var name: String=ui.rpg_state.name if live else "桐人"
	var name_size := 31
	while name_size>14 and F.font(600).get_string_size(name,HORIZONTAL_ALIGNMENT_LEFT,-1,name_size).x>133: name_size-=1
	while name.length()>1 and F.font(600).get_string_size(name,HORIZONTAL_ALIGNMENT_LEFT,-1,name_size).x>133: name=name.left(-2)+"…"
	F.text(c,p+Vector2(45,94),name,name_size,F.INK,600)
	F.text(c,p+Vector2(184,93),"Lv. %02d"%(ui.rpg_state.level if live else 1),15,F.SOFT)
	F.text(c,p+Vector2(270,93),(ui.rpg_state.career+" ›") if live else "剑士",22,F.INK,600)
	F.text(c,p+Vector2(45,128),"种族  "+(ui.rpg_state.race if live else RACES.display_name(RACES.DEFAULT_ID)),15,F.SOFT)
	F.text(c,p+Vector2(270,135),"生命",17,F.SOFT)
	F.text(c,p+Vector2(379,135),"%d / %d"%[ui.rpg_state.resources.HP.current,ui.rpg_state.resources.HP.max] if live else "320 / 320",18,F.INK)
	F.pen(c,p+Vector2(270,145),p+Vector2(477,145),Color(F.SAGE,.6),2)
	F.text(c,p+Vector2(270,172),"经验",16,F.SOFT)
	F.text(c,p+Vector2(382,172),("等级已满" if ui.rpg_state.level>=ui.rpg_state.max_level else "%d / %d"%[ui.rpg_state.experience,ui.rpg_state.next_level]) if live else "28 / 100",15,F.SOFT)
	var xp_ratio: float=clampf(float(ui.rpg_state.experience)/maxf(1,ui.rpg_state.next_level),0,1) if live else .28
	F.pen(c,p+Vector2(270,182),p+Vector2(477,182),Color(F.LINE,.5),2)
	F.pen(c,p+Vector2(270,182),p+Vector2(270+207*xp_ratio,182),F.SAGE,2.5)
	F.text(c,p+Vector2(270,211),"体力",17,F.SOFT)
	var stamina_max: int=maxi(0,int(ui.rpg_state.resources.Stamina.max)) if live else 7
	var stamina: int=int(ui.rpg_state.resources.Stamina.current) if live else 5
	var stamina_step: float=minf(24.0,144.0/maxi(1,stamina_max-1))
	var stamina_radius: float=minf(4.9,stamina_step*.34)
	for i in range(stamina_max):
		var at := p+Vector2(327+i*stamina_step,205)
		if i<stamina: F.wash(c,at,Vector2.ONE*stamina_radius*1.1,Color("ba9860"))
		F.ring(c,at,stamina_radius,Color(F.SOFT,.86 if i<stamina else .5),.9)
	F.text(c,p+Vector2(270,241),"能量 %s / %s"%[ui.RPG_VIEW.number(ui.rpg_state.resources.Energy.current),ui.RPG_VIEW.number(ui.rpg_state.resources.Energy.max)] if live else "能量  50 / 60",14,F.SOFT)
	for i in range(6):
		var value: String=str(ui.rpg_state.stats[["STR","DEX","CON","INT","PER","CHA"][i]]) if live else ["18","16","14","10","12","11"][i]
		F.text(c,p+Vector2(276,292+i*39),["力量","敏捷","体质","智力","感知","魅力"][i],20,F.INK)
		F.text(c,p+Vector2(448,292+i*39),value,21,F.INK)
	if ui.equipment_picker:
		var equip: Dictionary=ui.equipment_entries()[ui.selected_equipment]
		F.text(c,p+Vector2(653,96),equip.slot,23,F.INK,600)

static func inventory(ui: Control,c: CanvasItem,p: Vector2) -> void:
	heading(c,p,"行囊","")
	F.text(c,p+Vector2(44,85),"%02d 件随身物品"%ui._displayed_items().size(),16,F.SOFT)
	var item: Dictionary=ui.item_at(ui.selected_item)
	F.text(c,p+Vector2(661,81),item.name,32,F.INK,600)
	F.text(c,p+Vector2(662,113),item.type+" · 持有 "+(item.count if item.count!="" else "1"),17,F.SOFT)
	if not CONTENT_ART.draw(c,item.get("texture"),p+Vector2(767,221),94): F.item(c,item.kind,p+Vector2(767,221),94,item.color)
	F.hatch(c,Rect2(p+Vector2(729,315),Vector2(83,5)),Color(F.INK,.12),5)
	F.sprig(c,p+Vector2(1070,484),24,Color(F.SAGE,.3))
	var notes=preload("res://scripts/frontend/trait_notes.gd")
	var y: float=notes.paragraph(c,p+Vector2(661,364),item.note,430,20,31)
	if not item.stat.is_empty(): notes.paragraph(c,Vector2(p.x+675,minf(y+23,p.y+493)),item.stat,410,17,27,F.SAGE)
	if ui.discard_confirm: F.text(c,p+Vector2(901,135),"确定不再带着？",18,F.SOFT)

static func traits(ui: Control,c: CanvasItem,p: Vector2) -> void:
	heading(c,p,"特性","")
	var list: Array=ui.traits()
	if list.is_empty():
		F.text(c,p+Vector2(65,145),"尚未获得特性",23,F.SOFT)
		F.text(c,p+Vector2(663,186),"在职业与旅途中，慢慢积累。",22,F.SOFT)
		return
	var entry: Dictionary=list[clampi(ui.selected_trait,0,list.size()-1)]
	F.text(c,p+Vector2(662,85),entry.kind,16,F.SAGE)
	F.text(c,p+Vector2(659,138),entry.name,36,F.INK,600)
	var notes=preload("res://scripts/frontend/trait_notes.gd")
	var y: float=notes.paragraph(c,p+Vector2(662,177),entry.source,421,17,27,F.SOFT)
	y=notes.paragraph(c,Vector2(p.x+663,maxf(p.y+225,y+21)),entry.condition,415,20,31,F.SAGE)
	notes.paragraph(c,Vector2(p.x+663,y+23),entry.effects,417,21,34)
	F.sprig(c,p+Vector2(1038,481),32,Color(F.SAGE,.3))

static func twig(c: CanvasItem,from: Vector2,to: Vector2,color: Color,curve := 8.0) -> void:
	var delta := to-from
	var normal := delta.normalized().orthogonal()
	var start := from+delta.normalized()*26
	var end := to-delta.normalized()*26
	for pass_index in range(2):
		var path := PackedVector2Array()
		for j in range(24):
			var t := float(j)/23
			path.append(start.lerp(end,t)+normal*(sin(t*PI)*curve+sin(t*21+from.y)*.55+pass_index*1.3))
		c.draw_polyline(path,Color(color,color.a*(1.0 if pass_index==0 else .29)),.9,true)

static func skills(ui: Control,c: CanvasItem,p: Vector2) -> void:
	heading(c,p,"技能","")
	heading(c,p,"研习", "",true)
	var root := p+Vector2(260,280)
	for radius in [92.0,188.0]:
		for arc in range(8): c.draw_arc(root,radius,arc*TAU/8+.035,arc*TAU/8+.70,24,Color(F.SOFT,.10),.75,true)
	var start: int=ui.skill_page*12 if ui.has_rpg() else 0
	for i in range(start,mini(start+12,ui.skills().size())):
		var skill: Dictionary=ui.skill_at(i)
		var parent: int=skill.parent
		var from: Vector2=root if parent<0 else p+ui.skill_at(parent).pos
		twig(c,from,p+skill.pos,Color(F.INK,.65 if ui.learned_skills.has(i) else .26),-9 if i%2==0 else 9)
	for pair: Vector2i in [Vector2i(3,4),Vector2i(4,5),Vector2i(6,7),Vector2i(7,8),Vector2i(9,10),Vector2i(10,11)]:
		if not ui.has_rpg(): twig(c,p+ui.skill_at(pair.x).pos,p+ui.skill_at(pair.y).pos,Color(F.SOFT,.20),6)
	F.wash(c,root,Vector2(29,27),Color(F.SAGE,.35))
	F.ring(c,root,29,F.INK,1.1)
	F.ring(c,root,25,Color(F.SOFT,.35),.8)
	F.sprig(c,root+Vector2(-8,12),23,F.INK)
	F.text(c,p+Vector2(59,508),"已习得 · %02d"%ui.learned_skills.size() if ui.has_rpg() else "技能点 · %02d"%ui.skill_points,18,F.SOFT)
	var skill: Dictionary=ui.skill_at(ui.selected_skill)
	F.wash(c,p+Vector2(860,158),Vector2(65,49),Color(F.SAGE,.23))
	F.ring(c,p+Vector2(860,153),51,Color(F.SOFT,.26),.7)
	if CONTENT_ART.draw(c,skill.get("texture"),p+Vector2(860,153),34): pass
	elif skill.kind in ["flower","feather"]: F.item(c,skill.kind,p+Vector2(860,153),32)
	else: A.icon(c,skill.kind,p+Vector2(860,153),34,F.INK)
	F.centered(c,p+Vector2(860,242),skill.name,32,F.INK,600)
	F.centered(c,p+Vector2(860,270),skill.type,18,F.SOFT)
	var lines: PackedStringArray=skill.note.split("\n")
	for i in range(mini(lines.size(),2)): F.text(c,p+Vector2(648,319+i*29),lines[i].left(27),19,F.INK)
	F.text(c,p+Vector2(648,388),"消耗  "+skill.cost,16,F.SOFT)
	F.text(c,p+Vector2(911,388),"冷却  "+skill.cooldown,16,F.SOFT)
	var prepared: PackedStringArray=[]
	if skill.passive:
		var slot: int=ui.passive_slots.find(ui.selected_skill)
		if slot>=0: prepared.append(["Ⅰ","Ⅱ"][slot])
	else:
		for group in range(2):
			var slots: Array[int]=ui.group_slots(group)
			for slot in range(slots.size()):
				if slots[slot]==ui.selected_skill: prepared.append(["A","B"][group]+" · "+KEYS.label(slot))
	var message := ""
	if not prepared.is_empty(): message="已备战  "+" / ".join(prepared)
	elif ui.learned_skills.has(ui.selected_skill): message=""
	elif not ui.can_learn(ui.selected_skill): message=skill.get("reason","尚未满足研习条件") if ui.has_rpg() else ("技能点不足" if ui.skill_points<=0 else "先习得「"+ui.skill_at(skill.parent).name+"」")
	else: message="已具备研习条件 · 免费学习" if ui.has_rpg() else "花一点时间，把它记下来。"
	if not ui.ink_open and ui.ink_progress<=0: F.centered(c,p+Vector2(860,428),message,15,F.SOFT)
	if ui.ink_open or ui.ink_progress>0: ink_choices(ui,c,p)

static func ink_choices(ui: Control,c: CanvasItem,p: Vector2) -> void:
	var t: float=ui.ink_progress
	var expanded := smoothstep(0,1,t)
	var source := p+Vector2(873,476)
	var centers: Array[Vector2]=CONTROLS.ink_centers(ui)
	centers.append(Vector2(1052,476))
	for i in range(centers.size()):
		var to := p+centers[i]
		var at := source.lerp(to,expanded)
		F.wash(c,at,Vector2(26+sin(PI*t)*15,18+sin(PI*t)*8),Color(F.INK,.22+sin(PI*t)*.63))
		for j in range(5):
			var phase := (j+1)*1.83+i*.65
			var drip := at+Vector2(cos(phase)*29,sin(phase)*18)*sin(PI*t)
			c.draw_circle(drip,1.0+j*.25,Color(F.INK,sin(PI*t)*.25))
	var alpha := 1-smoothstep(.07,.58,t)
	F.text(c,source+Vector2(-27-expanded*19,9-expanded*6),"备",27,Color(F.INK,alpha))
	F.text(c,source+Vector2(0+expanded*25,9+expanded*4),"战",27,Color(F.INK,alpha))
	if not ui.skill_at(ui.selected_skill).passive:
		for group in range(2): F.text(c,p+Vector2(696,459+group*49),["A :","B :"][group],21,Color(F.INK,smoothstep(.42,.94,t)))

static func journal(ui: Control,c: CanvasItem,p: Vector2) -> void:
	heading(c,p,"日志","")
	heading(c,p,"旅途备忘" if ui.has_rpg() and ui.journey_memo_open else "任务", "",true)
	if ui.has_rpg():
		var active := 0
		var completed := 0
		for entry in ui.quest_records:
			if entry.status=="rewarded": completed+=1
			else: active+=1
		F.text(c,p+Vector2(45,94),"进行中 %02d  /  已完成 %02d"%[active,completed],17,F.SOFT)
		if ui.quest_records.size()<3: F.landscape(c,p+Vector2(74,490),365)
		if ui.quest_records.is_empty():
			F.text(c,p+Vector2(69,163),"还没有记下新的委托。",23,F.INK)
			F.text(c,p+Vector2(69,210),"去村口走走，与村民交谈。",19,F.SOFT)
			F.sprig(c,p+Vector2(372,366),55,Color(F.SAGE,.45))
			if not ui.journey_memo_open:
				F.text(c,p+Vector2(645,155),"旅途中的约定",28,F.INK)
				F.text(c,p+Vector2(645,207),"接下委托后，目标与进展会记在这里。",18,F.SOFT)
		elif not ui.journey_memo_open:
			F.text(c,p+Vector2(645,516),"与委托人交谈，交付任务并领取奖励。",16,F.SOFT)
		return
	F.text(c,p+Vector2(45,92),"未完的故事  /  02",16,F.SOFT)
	for i in range(DATA.QUESTS.size()):
		F.text(c,p+Vector2(57,196+i*110),DATA.QUESTS[i].tag,16,F.SOFT)
		if ui.tracked_quest==i: F.text(c,p+Vector2(382,196+i*110),"追踪中",15,F.SAGE)
	F.landscape(c,p+Vector2(67,471),373)
	var quest: Dictionary=DATA.QUESTS[ui.selected_quest]
	F.text(c,p+Vector2(643,113),quest.tag,16,F.SAGE)
	F.text(c,p+Vector2(643,154),quest.title,30,F.INK,600)
	var lines: PackedStringArray=quest.body.split("\n")
	for i in range(lines.size()): F.text(c,p+Vector2(643,198+i*26),lines[i],18,F.SOFT)
	for i in range(3):
		var at := p+Vector2(653,294+i*49)
		F.ring(c,at,5,Color(F.SOFT,.7),.8)
		if i==0: F.stroke(c,at,6,[Vector2(-.6,0),Vector2(-.1,.5),Vector2(.8,-.5)],F.INK,1.0)
		F.text(c,at+Vector2(22,6),quest.steps[i],19,F.INK if i==1 else F.SOFT)

static func settings(ui: Control,c: CanvasItem,p: Vector2) -> void:
	heading(c,p,"设置","")
	if not ui.save_note.is_empty():
		F.text(c,p+Vector2(62,116),ui.save_note,16,F.SAGE)
	if ui.game_mode:
		F.text(c,p+Vector2(62,151),"返回标题和正常关闭窗口时也会保存。",16,F.SOFT)
	heading(c,p,["声音","按键","画面"][ui.settings_tab], "",true)
	F.landscape(c,p+Vector2(74,388),372)
	F.sprig(c,p+Vector2(102,326),43,Color(F.SAGE,.55))
	F.sprig(c,p+Vector2(406,365),34,Color(F.SAGE,.4))
	if ui.settings_tab==0:
		for i in range(3):
			F.text(c,p+Vector2(645,141+i*91),["整体音量","音乐","音效与环境"][i],22,F.INK)
			F.text(c,p+Vector2(1038,184+i*91),str(roundi(ui.preview_levels[i])),18,F.SOFT)
	elif ui.settings_tab==1:
		F.text(c,p+Vector2(62,231),"快速：按住瞄准，松开释放。",18,F.INK)
		F.text(c,p+Vector2(62,264),"精准：点按选取，再次点按释放。",18,F.INK)
		F.text(c,p+Vector2(62,297),"两种模式均可右键取消施法。",18,F.SOFT)
		for i in range(5):
			F.text(c,p+Vector2(645,146+i*55),["主动槽位一","主动槽位二","主动槽位三","Z  跳跃","C  蹲下 / 站起"][i],20,F.INK)
		F.text(c,p+Vector2(62,199),"C 选取自身；Z 选取跳跃落点。",16,F.SOFT)
		F.text(c,p+Vector2(645,411),ui.binding_note,17,F.SOFT)
	else:
		F.text(c,p+Vector2(646,332),"伤害跳字",23,F.INK)
		F.text(c,p+Vector2(646,378),"从敌人血条上方飘起的伤害数字",16,F.SOFT)
