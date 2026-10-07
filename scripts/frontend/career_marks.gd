extends RefCounted
const F=preload("res://scripts/frontend/field_guide_art.gd")

static func draw(c: CanvasItem,kind: String,p: Vector2,r: float,color: Color) -> void:
	# Open contour strokes and light hatching, rather than flat filled UI symbols.
	match kind:
		"mage","conjurer","evoker":
			F.stroke(c,p,r,[Vector2(-.15,.9),Vector2(.02,-.30),Vector2(-.18,-.43),Vector2(-.29,-.64),Vector2(-.15,-.91),Vector2(.18,-.95),Vector2(.39,-.72),Vector2(.28,-.47),Vector2(.05,-.36)],color,1.1)
			F.ring(c,p+Vector2(.05,-.66)*r,r*.16,Color(color,.7),.75)
			F.stroke(c,p,r,[Vector2(-.11,.66),Vector2(.13,.56),Vector2(-.09,.43),Vector2(.16,.30)],Color(color,.6),.7)
			for i in range(3): F.pen(c,p+Vector2(-.62+i*.55,-1.02)*r,p+Vector2(-.72+i*.63,-1.16)*r,Color(color,.45),.6)
		"barbarian","berserker","vanguard":
			F.stroke(c,p,r,[Vector2(-.54,.88),Vector2(.10,-.57),Vector2(.19,-.70),Vector2(.24,-.54),Vector2(-.44,.94),Vector2(-.54,.88)],color,1.15)
			F.stroke(c,p,r,[Vector2(.0,-.38),Vector2(-.36,-.45),Vector2(-.51,-.87),Vector2(-.16,-1.05),Vector2(.24,-.69),Vector2(.63,-.62),Vector2(.83,-.29),Vector2(.45,.02),Vector2(.25,-.23)],color,1.0)
			for i in range(5): F.pen(c,p+Vector2(.36+i*.05,-.36+i*.03)*r,p+Vector2(.52+i*.04,-.51+i*.07)*r,Color(color,.4),.6)
		"rogue","shadowblade":
			F.stroke(c,p,r,[Vector2(-.68,.71),Vector2(-.68,-.02),Vector2(-.39,-.66),Vector2(.0,-1.06),Vector2(.49,-.69),Vector2(.72,-.07),Vector2(.68,.79),Vector2(.18,.63),Vector2(-.26,.72),Vector2(-.68,.71)],color,1)
			F.stroke(c,p,r,[Vector2(-.47,-.02),Vector2(-.18,-.43),Vector2(.04,-.70),Vector2(.44,-.10),Vector2(.26,.29),Vector2(-.24,.32),Vector2(-.47,-.02)],color,.8)
			F.stroke(c,p,r,[Vector2(-.27,.08),Vector2(-.01,.01),Vector2(.20,.07)],color,1.1)
			for i in range(4): F.pen(c,p+Vector2(-.56+i*.09,.48)*r,p+Vector2(-.38+i*.08,.31)*r,Color(color,.4),.6)
		"ranger":
			F.stroke(c,p,r,[Vector2(-.49,-1.0),Vector2(-.04,-.72),Vector2(.43,-.32),Vector2(.50,.13),Vector2(.17,.62),Vector2(-.43,1.0)],color,1.2)
			F.stroke(c,p,r,[Vector2(-.49,-1.0),Vector2(-.43,1.0)],Color(color,.55),.65)
			F.stroke(c,p,r,[Vector2(-.88,.23),Vector2(.93,-.21),Vector2(.65,-.34),Vector2(.80,.01),Vector2(.93,-.21)],color,.9)
		_:
			for i in range(2 if kind=="dual_swordsman" else 1):
				var side := -1.0 if i==1 else 1.0
				var path: Array=[Vector2(-.50,.85),Vector2(-.29,.40),Vector2(-.55,.21),Vector2(-.49,.08),Vector2(-.23,.20),Vector2(.25,-.81),Vector2(.57,-1.06),Vector2(.59,-.65),Vector2(.02,.34),Vector2(.26,.52),Vector2(.19,.65),Vector2(-.09,.49),Vector2(-.34,.91),Vector2(-.50,.85)]
				for j in range(path.size()): path[j].x*=side
				F.stroke(c,p,r,path,color,1.0)
				F.stroke(c,p,r,[Vector2(-.1*side,.26),Vector2(.44*side,-.75)],Color(color,.55),.65)
				for j in range(4): F.pen(c,p+Vector2((-.35+j*.04)*side,.73-j*.07)*r,p+Vector2((-.24+j*.03)*side,.75-j*.07)*r,Color(color,.5),.6)
			if kind=="soldier":
				F.stroke(c,p,r,[Vector2(.18,.17),Vector2(.72,.12),Vector2(.96,.35),Vector2(.80,.77),Vector2(.51,1.02),Vector2(.26,.76),Vector2(.18,.17)],color,.95)
				F.stroke(c,p,r,[Vector2(.33,.32),Vector2(.78,.30),Vector2(.67,.70),Vector2(.51,.83),Vector2(.39,.63),Vector2(.33,.32)],Color(color,.5),.7)
