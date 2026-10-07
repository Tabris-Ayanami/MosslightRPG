extends RefCounted
## Monotone cubic Hermite tracks. One shared velocity at each pose boundary;
## equal-value contacts stay exactly still rather than overshooting the ground.
const KEYS=[
	[0.0,Vector3(0,.28,0),90.0,0.0,Vector3(.20,.17,1.56),Vector3(-.35,.17,1.06),Vector3(.30,.29,-1.28),Vector3(-.30,.29,-1.24),-2.0,0.0],
	[.16,Vector3(0,.30,.02),85.0,-5.0,Vector3(.22,.17,1.13),Vector3(-.34,.17,1.00),Vector3(.68,.20,-.73),Vector3(-.63,.20,-.53),-6.0,-9.0],
	[.28,Vector3(.025,.36,.03),70.0,-7.0,Vector3(.25,.17,1.0),Vector3(-.35,.17,.91),Vector3(.57,.14,-.40),Vector3(-.57,.14,-.40),-5.0,-8.0],
	[.34,Vector3(.04,.41,.03),60.0,-7.0,Vector3(.27,.17,.94),Vector3(-.36,.17,.82),Vector3(.57,.14,-.40),Vector3(-.57,.14,-.40),-5.0,-8.0],
	[.41,Vector3(.07,.49,.02),46.0,-6.0,Vector3(.29,.17,.77),Vector3(-.36,.17,.56),Vector3(.55,.34,-.34),Vector3(-.55,.34,-.34),-1.0,-7.0],
	[.53,Vector3(.09,.72,0),20.0,-4.0,Vector3(.31,.17,.66),Vector3(-.36,.17,.11),Vector3(.51,.83,-.07),Vector3(-.48,.85,.13),5.0,-6.0],
	[.66,Vector3(.08,1.12,-.04),-14.0,-2.0,Vector3(.31,.17,.66),Vector3(-.35,.17,-.62),Vector3(.48,1.17,.36),Vector3(-.47,1.17,.34),8.0,-4.0],
	[.80,Vector3(.04,1.52,-.02),-11.0,0.0,Vector3(.31,.17,.66),Vector3(-.32,.17,-.50),Vector3(.46,1.53,.36),Vector3(-.40,1.53,.22),4.0,-3.0],
	[.92,Vector3(0,1.76,0),-3.0,0.0,Vector3(.23,.17,.27),Vector3(-.23,.23,-.13),Vector3(.40,1.70,.12),Vector3(-.40,1.70,.12),1.0,1.0],
	[1.0,Vector3(0,1.79,0),0.0,0.0,Vector3(.18,.17,0),Vector3(-.18,.17,0),Vector3(.40,1.71,.06),Vector3(-.40,1.71,.06),0.0,0.0]
]

static func component(key: int, field: int, axis: int) -> float:
	return KEYS[key][field][axis] if axis>=0 else float(KEYS[key][field])

static func tangent(key: int, field: int, axis: int) -> float:
	if key==0 or key==KEYS.size()-1: return 0
	var h0: float=KEYS[key][0]-KEYS[key-1][0]
	var h1: float=KEYS[key+1][0]-KEYS[key][0]
	var d0 := (component(key,field,axis)-component(key-1,field,axis))/h0
	var d1 := (component(key+1,field,axis)-component(key,field,axis))/h1
	if d0*d1<=0: return 0
	var w0 := 2*h1+h0
	var w1 := h1+2*h0
	return (w0+w1)/(w0/d0+w1/d1)

static func scalar(progress: float, field: int, axis: int=-1) -> float:
	var k := 0
	for i in range(KEYS.size()-1):
		if progress>=KEYS[i][0]: k=i
	var h: float=KEYS[k+1][0]-KEYS[k][0]
	var t := clampf((progress-KEYS[k][0])/h,0,1)
	var a := component(k,field,axis)
	var b := component(k+1,field,axis)
	return (2*t*t*t-3*t*t+1)*a+(t*t*t-2*t*t+t)*h*tangent(k,field,axis)+(-2*t*t*t+3*t*t)*b+(t*t*t-t*t)*h*tangent(k+1,field,axis)

static func vector(progress: float, field: int) -> Vector3:
	return Vector3(scalar(progress,field,0),scalar(progress,field,1),scalar(progress,field,2))
