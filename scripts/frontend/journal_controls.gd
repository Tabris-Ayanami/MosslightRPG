extends RefCounted
const F=preload("res://scripts/frontend/field_guide_art.gd")
const DATA=preload("res://scripts/frontend/prototype_content.gd")
const KEYS=preload("res://scripts/frontend/journal_bindings.gd")
const RETURN_GUIDANCE=preload("res://rpg/return_guidance.gd")

static func build(ui: Control) -> void:
	var p: Vector2=ui.panel_rect.position
	var close: Button=ui._guide(ui.modal,"close","close",Rect2(p+Vector2(1086,-35),Vector2(32,57)),ui.close_panel)
	close.tooltip_text="合上手记  Esc"
	for i in range(5):
		var id: String=["character","bag","skills","journal","settings"][i]
		if not ui.game_mode and id!="settings": continue
		var tab: Button=ui._guide(ui.modal,"bookmark",["person","bag","wind","journal","settings"][i],Rect2(p+Vector2(-73,34+i*94),Vector2(95,86)),ui._switch_panel.bind(id),["","B","K","X","Esc"][i],ui.panel==id)
		tab.text=["角色","背包","技能","日志","设置"][i]
	match ui.panel:
		"bag": inventory(ui,p)
		"character": character(ui,p)
		"skills": skills(ui,p)
		"settings": settings(ui,p)
		"journal":
			if ui.has_rpg(): journal(ui,p)
			else:
				for i in range(DATA.QUESTS.size()): ui._button(DATA.QUESTS[i].title,Rect2(p+Vector2(43,122+i*110),Vector2(412,50)),ui._select_quest.bind(i),i==ui.selected_quest,23)
				ui._button("正在追踪" if ui.selected_quest==ui.tracked_quest else "追踪此任务",Rect2(p+Vector2(644,451),Vector2(190,39)),ui._track_quest,ui.selected_quest==ui.tracked_quest)
		"new": ui._button("踏上旅途  →",Rect2(p+Vector2(733,343),Vector2(250,52)),ui._begin,true)

static func journal(ui: Control,p: Vector2) -> void:
	ui.quest_buttons.clear()
	var memo_button: Button=ui._button("旅途备忘",Rect2(p+Vector2(64,461),Vector2(202,39)),ui._show_journey_memo.bind(true),ui.journey_memo_open,22)
	memo_button.name="JourneyMemoButton"
	memo_button.disabled=ui.journey_memo_open
	var list := _quest_scroll(ui,p+Vector2(44,118),Vector2(424,320),false)
	list.get_parent().visible=not ui.quest_records.is_empty()
	for i in range(ui.quest_records.size()):
		var entry: Dictionary=ui.quest_records[i]
		var button := Button.new()
		button.name="Quest_"+entry.id
		button.custom_minimum_size=Vector2(0,100)
		button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
		button.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
		button.mouse_force_pass_scroll_events=true
		button.tooltip_text=entry.title
		var normal := StyleBoxFlat.new()
		normal.bg_color=Color(F.SAGE,.14 if i==ui.selected_quest else 0.0)
		var hover: StyleBoxFlat=normal.duplicate()
		hover.bg_color=Color(F.SAGE,.21)
		for state in ["normal","disabled"]: button.add_theme_stylebox_override(state,normal)
		for state in ["hover","pressed","focus"]: button.add_theme_stylebox_override(state,hover)
		list.add_child(button)
		var margin := MarginContainer.new()
		margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		for side in ["left","right"]: margin.add_theme_constant_override("margin_"+side,12)
		for side in ["top","bottom"]: margin.add_theme_constant_override("margin_"+side,7)
		margin.mouse_filter=Control.MOUSE_FILTER_IGNORE
		button.add_child(margin)
		var words := VBoxContainer.new()
		words.mouse_filter=Control.MOUSE_FILTER_IGNORE
		margin.add_child(words)
		var title: Label=_quest_label(words,entry.title,23,F.INK)
		title.max_lines_visible=2
		title.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
		var completed := 0
		for objective in entry.objectives:
			if objective.complete: completed+=1
		_quest_label(words,"%s  ·  目标 %d/%d%s"%[ui.quest_status_label(entry.status),completed,entry.objectives.size(),"  ·  追踪中" if entry.id==ui.tracked_quest_id else ""],16,F.SAGE if entry.status=="ready" else F.SOFT)
		button.pressed.connect(ui._select_quest.bind(i))
		ui.quest_buttons[entry.id]=button
	if ui.journey_memo_open:
		var memo := _quest_scroll(ui,p+Vector2(642,106),Vector2(424,343),true,true)
		for section in RETURN_GUIDANCE.describe(ui.rpg).sections:
			_quest_label(memo,section.title,24,F.INK)
			_quest_label(memo,section.body,20,F.SOFT)
		ui._button("返回任务",Rect2(p+Vector2(644,461),Vector2(202,39)),ui._show_journey_memo.bind(false),false,22)
		return
	var selected: Dictionary=ui.quest_at(ui.selected_quest)
	if selected.is_empty(): return
	var details := _quest_scroll(ui,p+Vector2(642,106),Vector2(424,343),true)
	_quest_label(details,ui.quest_status_label(selected.status),17,F.SAGE)
	_quest_label(details,selected.title,30,F.INK)
	_quest_label(details,selected.description,20,F.SOFT)
	_quest_label(details,"目标",22,F.INK)
	for objective in selected.objectives:
		_quest_label(details,"%s  %s   %d / %d"%["✓" if objective.complete else "○",objective.label,objective.current,objective.target],20,F.SAGE if objective.complete else F.INK)
	_quest_label(details,"已获奖励" if selected.status=="rewarded" else "委托奖励",22,F.INK)
	var reward_lines: PackedStringArray=[]
	var experience: int=int(selected.rewards.get("experience",0))
	if experience>0: reward_lines.append("经验  +%d"%experience)
	for item_id in selected.rewards.get("items",{}):
		var item: Dictionary=ui.rpg.inventory.definition(item_id)
		reward_lines.append("%s  ×%d"%[item.get("name",item_id),selected.rewards.items[item_id]])
	_quest_label(details,"\n".join(reward_lines) if not reward_lines.is_empty() else "这份约定没有额外奖励。",19,F.SOFT)
	if selected.status=="ready": _quest_label(details,"目标已经完成。返回委托人处报告进展。",19,F.SAGE)
	elif selected.status=="rewarded": _quest_label(details,"已交付，奖励已领取。",19,F.SAGE)
	if selected.status!="rewarded":
		ui._button("停止追踪" if selected.id==ui.tracked_quest_id else "追踪此任务",Rect2(p+Vector2(644,461),Vector2(202,39)),ui._track_quest,selected.id==ui.tracked_quest_id,22)

static func _quest_scroll(ui: Control,at: Vector2,extent: Vector2,detail: bool,memo := false) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name="JourneyMemo" if memo else ("QuestDetails" if detail else "QuestList")
	scroll.position=at
	scroll.size=extent
	scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_force_pass_scroll_events=false
	scroll.follow_focus=true
	ui.modal.add_child(scroll)
	var bar: VScrollBar=scroll.get_v_scroll_bar()
	bar.custom_minimum_size.x=6
	var track := StyleBoxFlat.new()
	track.bg_color=Color(F.LINE,.16)
	var grabber := StyleBoxFlat.new()
	grabber.bg_color=Color(F.SAGE,.5)
	grabber.corner_radius_top_left=3
	grabber.corner_radius_top_right=3
	grabber.corner_radius_bottom_left=3
	grabber.corner_radius_bottom_right=3
	bar.add_theme_stylebox_override("scroll",track)
	for state in ["grabber","grabber_highlight","grabber_pressed"]: bar.add_theme_stylebox_override(state,grabber)
	var box := VBoxContainer.new()
	box.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation",10)
	box.mouse_filter=Control.MOUSE_FILTER_PASS
	if memo:
		var margin := MarginContainer.new()
		margin.size_flags_horizontal=Control.SIZE_EXPAND_FILL
		margin.add_theme_constant_override("margin_right",16)
		margin.mouse_filter=Control.MOUSE_FILTER_PASS
		scroll.add_child(margin)
		margin.add_child(box)
	else: scroll.add_child(box)
	if memo: bar.value_changed.connect(ui._journey_memo_scroll_changed)
	else: bar.value_changed.connect(ui._quest_scroll_changed.bind(detail))
	scroll.set_deferred("scroll_vertical",ui.journey_memo_scroll if memo else (ui.quest_detail_scroll if detail else ui.quest_list_scroll))
	return box

static func _quest_label(parent: Control,value: String,font_size: int,color: Color) -> Label:
	var label := Label.new()
	label.text=value
	label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	label.mouse_filter=Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font",F.font())
	label.add_theme_font_size_override("font_size",font_size)
	label.add_theme_color_override("font_color",color)
	parent.add_child(label)
	return label

static func inventory(ui: Control,p: Vector2) -> void:
	var tabs: Array=["全部","武器","护具","补给","其他"] if ui.has_rpg() else ["全部","武器","素材","食物","任务"]
	for i in range(5): ui._button(tabs[i],Rect2(p+Vector2(636+i*88,-29),Vector2(82,47)),ui._select_inventory_tab.bind(i),i==ui.inventory_tab,19,"top_bookmark")
	var displayed: Array[int]=ui._displayed_items()
	if ui.has_rpg():
		ui.inventory_page=mini(ui.inventory_page,maxi(0,ceili(displayed.size()/15.0)-1))
		displayed=displayed.slice(ui.inventory_page*15,ui.inventory_page*15+15)
	for i in range(displayed.size()):
		var index: int=displayed[i]
		var item: Dictionary=ui.item_at(index)
		var b: Button=ui._guide(ui.modal,"item",item.kind,ui._inventory_slot_rect(i),ui._select_item.bind(index),"",index==ui.selected_item)
		b.quantity=item.count
		b.content_icon=item.get("texture")
		b.tint=item.color
		b.tooltip_text=item.name
		ui.item_buttons[index]=b
	page_buttons(ui,p+Vector2(291,463),"inventory",ui.inventory_page,ceili(ui._displayed_items().size()/15.0))
	var item: Dictionary=ui.item_at(ui.selected_item)
	var live: bool=ui.has_rpg()
	if live and item.id.is_empty(): return
	if item.get("category", "") == "currency": return
	if ui.discard_confirm:
		var confirm: Button=ui._button("丢弃一件",Rect2(p+Vector2(907,181),Vector2(150,38)),ui._inventory_action.bind("confirm_discard"),false,22)
		confirm.disabled=not live
		ui._button("还是留着",Rect2(p+Vector2(926,241),Vector2(150,38)),ui._inventory_action.bind("cancel_discard"),false,20)
		return
	if ui.quick_picker:
		for i in range(4): ui._button("快捷 %d"%(i+1),Rect2(p+Vector2(909+(i%2)*78,143+(i/2)*55),Vector2(80,37)),ui._inventory_action.bind("assign_quick",i),false,18)
	else:
		var category: String=item.get("category","consumable" if item.type in ["食物","消耗品","药剂"] else "material")
		if category=="consumable":
			var use: Button=ui._button("使用",Rect2(p+Vector2(923,146),Vector2(108,42)),ui._inventory_action.bind("use"),false,27)
			use.tooltip_text=ui.rpg.inventory.can_use(item.id) if live else "美术预览"
			use.disabled=live and not use.tooltip_text.is_empty()
			ui._button("放入快捷槽",Rect2(p+Vector2(927,212),Vector2(170,38)),ui._inventory_action.bind("quick"),false,20)
		elif category=="weapon":
			for i in range(2):
				var equip: Button=ui._button("装备至 "+["A","B"][i],Rect2(p+Vector2(909+i*16,151+i*60),Vector2(181,37)),ui._inventory_action.bind("weapon",i),false,22)
				equip.tooltip_text=ui.rpg.loadout.can_equip_set_weapon(i,item.id)
				equip.disabled=not equip.tooltip_text.is_empty()
		elif category=="equipment":
			for i in range(2 if item.slot=="ring" else 1):
				var slot: String=("ring1" if i==0 else "ring2") if item.slot=="ring" else item.slot
				var equip: Button=ui._button("穿戴"+("至戒指 %d"%(i+1) if item.slot=="ring" else ""),Rect2(p+Vector2(911+i*9,151+i*60),Vector2(181,37)),ui._inventory_action.bind("equipment",i),false,21)
				equip.tooltip_text=ui.rpg.loadout.can_equip_item(slot,item.id)
				equip.disabled=not equip.tooltip_text.is_empty()
	var discard: Button=ui._button("丢弃",Rect2(p+Vector2(919,274),Vector2(104,38)),ui._inventory_action.bind("discard"),false,19)
	discard.disabled=not ui.rpg.inventory.can_discard(item.id).is_empty() if live else item.type=="任务物品"
	discard.tooltip_text="丢弃一件；已装备的物品不能丢弃"

static func page_buttons(ui: Control,at: Vector2,kind: String,page: int,pages: int) -> void:
	if pages<=1: return
	var previous: Button=ui._button("‹",Rect2(at,Vector2(30,30)),ui._change_page.bind(kind,-1),false,25)
	previous.disabled=page<=0
	ui._button("%d / %d"%[page+1,pages],Rect2(at+Vector2(31,0),Vector2(70,30)),Callable(),false,16)
	var next: Button=ui._button("›",Rect2(at+Vector2(104,0),Vector2(30,30)),ui._change_page.bind(kind,1),false,25)
	next.disabled=page>=pages-1

static func character(ui: Control,p: Vector2) -> void:
	for i in range(3): ui._button(["面板","职业","特性"][i],Rect2(p+Vector2(643+i*145,-29),Vector2(135,47)),ui._select_character_tab.bind(i),i==ui.character_tab,21,"top_bookmark")
	if ui.character_tab==2:
		traits(ui,p)
		return
	if ui.character_tab==1:
		careers(ui,p)
		preparation(ui,p)
		return
	if ui.has_rpg():
		var career: Button=ui._guide(ui.modal,"hotspot","",Rect2(p+Vector2(269,65),Vector2(219,38)),ui._select_career)
		career.tooltip_text="职业与进阶"
	if ui.has_rpg() and ui.equipment_picker:
		var choices: Array[int]=ui._equipment_choices()
		var choice_pages: int=maxi(1,ceili(choices.size()/12.0))
		ui.equipment_choice_page=mini(ui.equipment_choice_page,choice_pages-1)
		choices=choices.slice(ui.equipment_choice_page*12,ui.equipment_choice_page*12+12)
		for i in range(choices.size()):
			var b: Button=ui._button(ui.item_at(choices[i]).name,Rect2(p+Vector2(642+(i%2)*222,115+(i/2)*51),Vector2(206,41)),ui._equip_choice.bind(choices[i]),false,19)
			var slot: Dictionary=ui.equipment_entries()[ui.selected_equipment]
			b.tooltip_text=ui.rpg.loadout.can_equip_set_weapon(int(slot.key),ui.item_at(choices[i]).id) if slot.weapon else ui.rpg.loadout.can_equip_item(slot.key,ui.item_at(choices[i]).id)
			b.disabled=not b.tooltip_text.is_empty()
		page_buttons(ui,p+Vector2(927,424),"equipment_choice",ui.equipment_choice_page,choice_pages)
		var remove: Button=ui._button("卸下",Rect2(p+Vector2(689,475),Vector2(135,37)),ui._unequip_selected,false,22)
		remove.disabled=ui.equipment_entries()[ui.selected_equipment].id.is_empty()
		ui._button("返回装备",Rect2(p+Vector2(912,475),Vector2(156,37)),ui._cancel_equipment_choice,false,20)
		return
	for i in range(ui.equipment_entries().size()):
		var equip: Dictionary=ui.equipment_entries()[i]
		var b: Button=ui._guide(ui.modal,"equip_small",equip.kind,Rect2(p+Vector2(637+(i%2)*223,80+(i/2)*86),Vector2(210,80)),ui._select_equipment.bind(i),equip.slot,i==ui.selected_equipment)
		b.text=equip.name
		b.content_icon=equip.get("texture")
		b.tooltip_text=equip.name+(" · "+equip.stat if not equip.stat.is_empty() else "")

static func careers(ui: Control,p: Vector2) -> void:
	ui.CAREERS.build_controls(ui,p)

static func preparation(ui: Control,p: Vector2) -> void:
	if ui.loadout_slot>=0:
		var choices: Array[int]=[]
		for i in range(ui.skills().size()):
			if ui.learned_skills.has(i) and bool(ui.skill_at(i).passive)==ui.loadout_passive: choices.append(i)
		var pages: int=maxi(1,ceili(choices.size()/12.0))
		ui.loadout_choice_page=mini(ui.loadout_choice_page,pages-1)
		choices=choices.slice(ui.loadout_choice_page*12,ui.loadout_choice_page*12+12)
		var slots: Array[int]=ui.passive_slots if ui.loadout_passive else ui.group_slots(ui.preparation_set)
		for i in range(choices.size()):
			var index: int=choices[i]
			ui._button(ui.skill_at(index).name,Rect2(p+Vector2(642+(i%2)*222,145+(i/2)*49),Vector2(203,40)),ui._select_loadout.bind(index),slots[ui.loadout_slot]==index,20)
		if ui.has_rpg() and choices.is_empty() and not ui.loadout_passive:
			var study: Button=ui._button("前往技能页 · 免费研习",Rect2(p+Vector2(660,213),Vector2(394,55)),ui._open_skill_study,false,24)
			study.name="LearnFirstPreparedSkill"
		page_buttons(ui,p+Vector2(929,440),"loadout_choice",ui.loadout_choice_page,pages)
		ui._button("取消",Rect2(p+Vector2(943,481),Vector2(126,39)),ui._cancel_loadout)
		if ui.has_rpg(): ui._button("清空此槽",Rect2(p+Vector2(674,481),Vector2(190,39)),ui._clear_skill_slot,false,21)
		return
	for group in range(2):
		var slots: Array[int]=ui.group_slots(group)
		for i in range(3):
			var skill: Dictionary=ui.skill_at(slots[i])
			var b: Button=ui._guide(ui.modal,"loadout",skill.kind,Rect2(p+Vector2(650+i*145,108+group*163),Vector2(124,106)),ui._open_loadout.bind(i,false,group),KEYS.label(i))
			b.text=skill.name
			b.content_icon=skill.get("texture")
	ui._button("查看特性  ›",Rect2(p+Vector2(661,458),Vector2(199,42)),ui._select_character_tab.bind(2),false,21)

static func traits(ui: Control,p: Vector2) -> void:
	var list: Array=ui.traits()
	ui.trait_page=mini(ui.trait_page,maxi(0,ceili(list.size()/7.0)-1))
	ui.selected_trait=clampi(ui.selected_trait,0,maxi(0,list.size()-1))
	for i in range(ui.trait_page*7,mini(list.size(),ui.trait_page*7+7)):
		var b: Button=ui._button(list[i].name,Rect2(p+Vector2(60,100+(i%7)*52),Vector2(428,43)),ui._select_trait.bind(i),i==ui.selected_trait,24,"trait")
		b.tooltip_text=list[i].source
	page_buttons(ui,p+Vector2(341,480),"traits",ui.trait_page,ceili(list.size()/7.0))

static func skills(ui: Control,p: Vector2) -> void:
	var start: int=ui.skill_page*12 if ui.has_rpg() else 0
	for i in range(start,mini(start+12,ui.skills().size())):
		var skill: Dictionary=ui.skill_at(i)
		var b: Button=ui._guide(ui.modal,"node",skill.kind,Rect2(p+skill.pos-Vector2(48,28),Vector2(96,73)),ui._select_skill.bind(i),"",i==ui.selected_skill)
		b.text=skill.name
		b.content_icon=skill.get("texture")
		b.learned=ui.learned_skills.has(i)
		b.tooltip_text=skill.name+" · "+("已习得" if b.learned else "尚未习得")
		ui.skill_buttons[i]=b
	if ui.has_rpg():
		page_buttons(ui,p+Vector2(335,476),"skills",ui.skill_page,ceili(ui.skills().size()/12.0))
		if ui.skills().is_empty():
			ui._button("先选择职业",Rect2(p+Vector2(700,431),Vector2(322,57)),ui.show_panel.bind("character"),false,24)
			return
	if ui.ink_open or ui.ink_progress>0:
		var centers: Array[Vector2]=ink_centers(ui)
		for i in range(centers.size()):
			var b: Button=ui._guide(ui.modal,"ink_slot","",Rect2(p+centers[i]-Vector2(31,26),Vector2(62,52)),ui._assign_ink.bind(i))
			b.text=["Ⅰ","Ⅱ"][i] if ui.skill_at(ui.selected_skill).passive else KEYS.label(i%3)
			b.reveal=ui.ink_progress
			b.disabled=not ui.ink_open or ui.ink_progress<.85
			ui.ink_buttons[i]=b
		var cancel: Button=ui._guide(ui.modal,"ink_slot","",Rect2(p+Vector2(1027,450),Vector2(50,52)),ui._cancel_ink)
		cancel.text="×"
		cancel.reveal=ui.ink_progress
		cancel.disabled=not ui.ink_open or ui.ink_progress<.85
		ui.ink_buttons[-1]=cancel
	elif ui.has_rpg() and ui.skill_at(ui.selected_skill).passive:
		var label: Button=ui._button("随职业常驻生效",Rect2(p+Vector2(700,431),Vector2(322,57)),Callable(),false,23)
		label.disabled=true
	elif ui.learned_skills.has(ui.selected_skill):
		ui._button("备战",Rect2(p+Vector2(724,431),Vector2(278,57)),ui._open_ink,false,28)
	else:
		var button: Button=ui._button("研习此招式" if ui.has_rpg() else "学习 · 1 技能点",Rect2(p+Vector2(700,431),Vector2(322,57)),ui._learn_skill,false,25)
		button.disabled=not ui.can_learn(ui.selected_skill)

static func ink_centers(ui: Control) -> Array[Vector2]:
	if ui.skill_at(ui.selected_skill).passive: return [Vector2(814,476),Vector2(933,476)]
	return [Vector2(778,452),Vector2(873,452),Vector2(968,452),Vector2(778,501),Vector2(873,501),Vector2(968,501)]

static func settings(ui: Control,p: Vector2) -> void:
	for i in range(3): ui._button(["声音","按键","画面"][i],Rect2(p+Vector2(643+i*145,-29),Vector2(135,47)),ui._select_settings_tab.bind(i),i==ui.settings_tab,21,"top_bookmark")
	if ui.settings_tab==0:
		for i in range(3):
			var slider := HSlider.new()
			slider.name="AudioLevel%d"%i
			slider.min_value=0
			slider.max_value=100
			slider.step=1
			slider.position=p+Vector2(649,162+i*91)
			slider.size=Vector2(369,26)
			slider.value=ui.preview_levels[i]
			slider.mouse_force_pass_scroll_events=false
			for part in ["slider","grabber_area","grabber_area_highlight"]:
				var track := StyleBoxFlat.new()
				track.bg_color=Color("8f886e") if part!="slider" else Color("c0b396")
				track.content_margin_top=1.3
				track.content_margin_bottom=1.3
				slider.add_theme_stylebox_override(part,track)
			for part in ["grabber","grabber_highlight","grabber_disabled"]: slider.add_theme_icon_override(part,knob())
			ui.modal.add_child(slider)
			slider.value_changed.connect(ui._set_level.bind(i))
	elif ui.settings_tab==1:
		for i in range(5):
			var action: String = ui.PREFERENCES.CAST_ACTIONS[i]
			var mode_button: Button = ui._button("快速施法" if ui.PREFERENCES.get_cast_mode(action)=="quick" else "精准施法",Rect2(p+Vector2(801,120+i*55),Vector2(144,36)),ui._toggle_cast_mode.bind(i),false,17,"tab")
			mode_button.name="CastMode%d"%i
			mode_button.tooltip_text="快速：按住瞄准、松开释放。\n精准：点按选取、再次点按或左键释放。\n右键取消；各槽位独立保存。"
			if i<3:
				ui._button("…" if ui.awaiting_binding==i else KEYS.label(i),Rect2(p+Vector2(954,120+i*55),Vector2(107,36)),ui._bind_key.bind(i),ui.awaiting_binding==i,23,"tab")
	else:
		ui._button("开启" if ui.PREFERENCES.get_damage_numbers() else "关闭",Rect2(p+Vector2(922,303),Vector2(137,43)),ui._toggle_damage_numbers,ui.PREFERENCES.get_damage_numbers(),22)
	if ui.game_mode:
		ui._button("返回标题",Rect2(p+Vector2(66,452),Vector2(160,43)),ui._return)
		ui._button("保存旅途",Rect2(p+Vector2(297,452),Vector2(160,43)),ui._save_journey,false,22)
	ui._button("恢复本页默认",Rect2(p+Vector2(646,456),Vector2(223,40)),ui._reset_settings_tab,false,20)
	ui._button("完成",Rect2(p+Vector2(933,456),Vector2(137,40)),ui.close_panel,true,22)

static func knob() -> Texture2D:
	var image := Image.new()
	image.load_svg_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="26" height="26"><path d="M13 4C24 3 23 22 13 22C1 22 2 5 13 4Z" fill="#e9ddc1" stroke="#685e4b" stroke-width="1.3"/><path d="M10 7L17 18M6 11L13 21" stroke="#afa184" stroke-width="1" opacity=".6"/><circle cx="13" cy="13" r="2" fill="#756952"/></svg>')
	return ImageTexture.create_from_image(image)
