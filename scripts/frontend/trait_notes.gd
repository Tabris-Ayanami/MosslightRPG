extends RefCounted
## Read the same definitions used by combat; never manufacture acquired blessings.
const F=preload("res://scripts/frontend/field_guide_art.gd")
const STATS={"crit_chance":"暴击率","crit_multiplier":"暴击伤害倍率","damage_multiplier":"伤害","resistance_penetration":"抗性穿透","Poise":"韧性","damage_taken":"受到的伤害","area_multiplier":"范围半径","vulnerability_all":"目标受到的伤害","poise_damage_multiplier":"削韧","spell_range_multiplier":"施法距离"}

static func number(v: float) -> String:
	return str(roundi(v)) if is_equal_approx(v,roundf(v)) else String.num(v,2)

static func condition(c: Dictionary) -> String:
	var op: String={"<":"低于",">":"高于",">=":"至少","<=":"不超过"}.get(c.get("op",""),"为")
	match c.get("type",""):
		"self_hp","target_hp": return ("自身生命" if c.type=="self_hp" else "目标生命")+op+number(float(c.value)*100)+"%"
		"behind_target": return "从目标背后攻击"
		"first_hit": return "进入战斗后的第一次命中"
		"weapon_family": return "使用单手刃类武器"
		"elemental": return "造成元素伤害"
		"presentation_type": return "施放法术" if c.value=="CASTER_ACTION" else "使用武器招式"
		"distance": return "与目标距离"+op+number(float(c.value))+" 米"
		"critical": return "攻击暴击"
		"target_status": return "目标受到自己的控制效果"
		"damage_type": return "造成雷电伤害" if c.value=="LIGHTNING" else str(c.value)+"伤害"
		"level": return "等级"+op+str(c.value)
		"area": return "范围招式"
	return str(c.get("type","条件"))

static func notes(d: Dictionary,db: RefCounted) -> Dictionary:
	var when: PackedStringArray=[]
	for c in d.get("conditions",[]): when.append(condition(c))
	if d.get("event","")=="perfect_dodge": when.insert(0,"完美闪避成功时")
	var effects: PackedStringArray=[]
	if not str(d.get("description","")).is_empty(): effects.append(d.description)
	else:
		for e in d.get("effects",[]):
			var text := ""
			match e.get("type",""):
				"modifier":
					var value: float=float(e.get("value",0))
					text=str(STATS.get(e.stat,e.stat))+" "+("+" if value>=0 else "")+number(value if e.stat=="Poise" else value*100)+("" if e.stat=="Poise" else "%")
				"forced_crit": text="这次攻击必定暴击。"
				"resource": text="恢复 %s 点%s。"%[number(float(e.amount)),{"Energy":"能量","HP":"生命","Stamina":"体力"}.get(e.resource,e.resource)]
				"status":
					var status: Dictionary=db.status_effects.get(e.status,{})
					text="获得「%s」%s。"%[status.get("name",e.status),"，持续 %s 秒"%number(float(e.duration)) if float(e.duration)>0 else ""]
					if e.status=="reversal": text+="\n下一次武器技能的能量消耗为 0。"
					elif e.status=="stealth": text+="\n敌人无法选中自己，攻击会解除隐匿。"
					elif e.status=="keen_edge": text+="\n下一次伤害攻击的暴击率 +15%。"
				"hit_sequence": text="累计命中 %d 次后，下一次武器技能伤害 +%s%%。"%[e.count,number(float(e.multiplier)*100)]
				"element_sequence": text="连续施放不同元素的法术，第 %d 次伤害 +%s%%。"%[e.count,number(float(e.multiplier)*100)]
			for c in e.get("conditions",[]): text=condition(c)+"："+text
			if not text.is_empty(): effects.append(text)
	var cooldown: float=float(d.get("cooldown",0))
	if cooldown>0: effects.append("触发间隔  %s 秒"%number(cooldown))
	if d.has("reset_after_combat"): effects.append("脱离战斗 %s 秒后重置。"%number(float(d.reset_after_combat)))
	return {"condition":"；".join(when) if not when.is_empty() else "常驻生效", "effects":"\n".join(effects)}

static func entries(actor: Node) -> Array:
	var db: RefCounted=actor.loadout.database
	var result: Array=[]
	var sources: Dictionary={}
	for id in actor.loadout.passive_ids:
		var names: PackedStringArray=[]
		for career_id in actor.loadout.career_ids:
			var career: Dictionary=db.careers.get(career_id,{})
			if id in career.get("passives",[]): names.append(career.get("name",career_id))
		sources[id]={"source":"职业 · "+(" / ".join(names) if not names.is_empty() else "职业传承"),"kind":"职业特性"}
	for id in actor.progression.acquired_traits:
		var origin: Dictionary=actor.progression.acquired_traits[id]
		if sources.has(id): sources[id].source+=" / "+origin.source
		else: sources[id]=origin.duplicate()
	for d in actor.combat.passives.definitions():
		var origin: Dictionary=sources.get(d.id,{"source":"当前持用武器","kind":"装备特性"})
		var entry: Dictionary=notes(d,db)
		entry.merge({"id":d.id,"name":d.get("name",d.id),"source":origin.source,"kind":origin.kind})
		result.append(entry)
	return result

static func fixtures() -> Array:
	return [
		{"id":"sword_saint","name":"剑圣","kind":"职业特性","source":"职业 · 剑士","condition":"使用单手刃类武器","effects":"暴击率 +10%\n暴击伤害倍率 +35%"},
		{"id":"qi_reflux","name":"能量回流","kind":"职业特性","source":"职业 · 决斗者","condition":"完美闪避成功时","effects":"恢复 20 点能量。\n触发间隔  3 秒"},
		{"id":"eagle_eye","name":"鹰眼","kind":"祝福","source":"林间石碑 · 旅途所得（美术示例）","condition":"与目标距离高于 8 米","effects":"暴击率 +12%"}]

static func paragraph(c: CanvasItem,at: Vector2,value: String,width: float,font_size := 21,line_height := 34.0,color := F.INK) -> float:
	var y := at.y
	for original in value.split("\n"):
		var line := ""
		for letter in original:
			if F.font().get_string_size(line+letter,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x>width:
				F.text(c,Vector2(at.x,y),line,font_size,color)
				y+=line_height
				line=""
			line+=letter
		F.text(c,Vector2(at.x,y),line,font_size,color)
		y+=line_height
	return y
