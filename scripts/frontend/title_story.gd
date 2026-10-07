extends RefCounted
## Shared seconds for the body performance, prop continuity and camera edit.
const RISE_START := .3
const GETUP_DURATION := 3.2
const GETUP_NATIVE_DURATION := 1.5333333
const RISE_END := 4.2
const PREPARE_END := 8.6
const CHOICE_TIME := 10.0
const DEPARTURE_TIME := 6.8
const END := CHOICE_TIME+DEPARTURE_TIME
const FACING := Vector3(.8,0,.6)
const YAW := 0.927295218
const WALK_STRIDE := 2.67
const SHEATHE := [
	[0.0,Vector3(.41,1.71,.11)], [.22,Vector3(.70,2.03,.43)],
	[.44,Vector3(.61,2.70,.12)], [.61,Vector3(.33,2.55,-.28)],
	[.72,Vector3(.33,2.55,-.28)], [.90,Vector3(.49,1.80,-.01)],
	[1.0,Vector3(.41,1.71,.11)]
]
const BACK_GRIP := Vector3(.33,2.55,-.28)
const BACK_TIP := Vector3(-.36,1.16,-.32)
const GROUND_GRIP := Vector3(.568,.077,-.38)
const PICKUP_NATIVE_TIME := .62
const PICKUP_TIME := RISE_START+GETUP_DURATION*PICKUP_NATIVE_TIME/GETUP_NATIVE_DURATION
const ATTACH_TIME := RISE_END+(PREPARE_END-RISE_END)*.67

static func prepare(seconds: float) -> float:
	return clampf((seconds-RISE_END)/(PREPARE_END-RISE_END),0,1)

static func yaw_at(seconds: float) -> float:
	var p := prepare(seconds)
	return YAW*.5*(smoothstep(.06,.42,p)+smoothstep(.32,.78,p))

static func getup_time(seconds: float) -> float:
	return clampf((seconds-RISE_START)/GETUP_DURATION,0,1)*GETUP_NATIVE_DURATION

static func distance_at(seconds: float) -> float:
	var t := maxf(0,seconds-CHOICE_TIME)
	return 1.40*(t-.45*(1-exp(-t/.45)))

static func sample(points: Array, time: float) -> Vector3:
	var index := 0
	for i in range(points.size()-1):
		if time>=points[i][0]: index=i
	var a: Vector3=points[index][1]
	var b: Vector3=points[index+1][1]
	var span: float=points[index+1][0]-points[index][0]
	var t := clampf((time-points[index][0])/span,0,1)
	var ma := Vector3.ZERO
	var mb := Vector3.ZERO
	for endpoint in range(2):
		var k := index+endpoint
		if k==0 or k==points.size()-1: continue
		var h0: float=points[k][0]-points[k-1][0]
		var h1: float=points[k+1][0]-points[k][0]
		var d0: Vector3=(points[k][1]-points[k-1][1])/h0
		var d1: Vector3=(points[k+1][1]-points[k][1])/h1
		var m := Vector3.ZERO
		for axis in range(3):
			if d0[axis]*d1[axis]>0:
				m[axis]=3*(h0+h1)/((2*h1+h0)/d0[axis]+(h1+2*h0)/d1[axis])
		if endpoint==0: ma=m
		else: mb=m
	return a*(2*t*t*t-3*t*t+1)+ma*span*(t*t*t-2*t*t+t)+b*(-2*t*t*t+3*t*t)+mb*span*(t*t*t-t*t)
