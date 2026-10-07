extends RefCounted
## The low-frequency field used by water_flow.gdshaderinc. Keep buoyancy and
## aiming on the animated surface; detail ripples remain an optical effect.
const WAVES := [
	[Vector2(.8,.3),.030,.72,.62,0.0],
	[Vector2(-.4,.9),.017,1.05,.83,1.3],
	[Vector2(.6,-.7),.010,1.37,1.04,2.6],
]

static func field(at: Vector2, clock: float, wind_strength := 1.0) -> Vector3:
	var result := Vector3.ZERO
	for wave: Array in WAVES:
		var direction: Vector2=wave[0].normalized()
		var phase: float=at.dot(direction)*wave[2]-clock*wave[3]+wave[4]
		var slope: Vector2=direction*cos(phase)*wave[1]*wave[2]
		result+=Vector3(sin(phase)*wave[1],slope.x,slope.y)
	return result*(1.0+(wind_strength-1.0)*.035)
