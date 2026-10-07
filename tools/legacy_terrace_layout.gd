extends RefCounted
## Coordinates are local to WaterGarden. X east, -Z north; terrain remains editable.
const EAST_ROAD = [Vector2(9,1.7),Vector2(23,1.7),Vector2(31,-1),Vector2(39,-4),Vector2(47,-1),Vector2(57,4)]
const NORTH_ROAD = [Vector2(0,-8),Vector2(0,-25),Vector2(-1,-32),Vector2(0,-40),Vector2(3,-53)]
const WOODLAND_ROAD = [Vector2(29,0),Vector2(28,-10),Vector2(26,-18),Vector2(21,-27),Vector2(12,-34)]

static func path_distance(p: Vector2, points: Array) -> float:
	var distance := INF
	for i in range(points.size()-1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i+1]
		var t := clampf((p-a).dot(b-a)/(b-a).length_squared(),0,1)
		distance = minf(distance,p.distance_to(a.lerp(b,t)))
	return distance

static func island_ground(x: float,z: float) -> float:
	if x>=1 and x<=4 and z>=7.7 and z<=11.5: return 2.2-(z-7.7)*.625
	if x>=4 and x<=6.8 and z<=-.4 and z>=-3.7: return minf(3.7,2.2+(-.4-z)*.5)-.08
	var edge := Vector2(x/16.0,(z+1)/12.0).length()+sin(x*.64+z*.35)*.045+cos(z*.91-x*.22)*.045
	if edge>1.14: return -1.5
	if edge>1.0: return .15
	if edge>.90: return .85
	if Vector2(x+5,z+2.5).length()<3.45: return .1
	if Vector2((x-7.5)/5.5,(z+5.5)/4.8).length()<1: return 3.7
	return 2.2

static func terrace(edge: float) -> float:
	if edge>1.08: return -1.5
	if edge>1.0: return .15
	if edge>.945: return .85
	return 2.2

static func ground(x: float,z: float) -> float:
	var garden := island_ground(x,z)
	var irregular := sin(x*.31+z*.17)*.027+cos(z*.42-x*.15)*.025
	var forest := terrace(Vector2((x-40)/26.5,(z+2)/23.5).length()+irregular)
	var village := terrace(Vector2((x+1)/23.5,(z+42)/24.5).length()+irregular)
	var saddle := terrace(Vector2((x-24)/10.5,(z+25)/13.0).length()+irregular)
	var result := maxf(garden,maxf(forest,maxf(village,saddle)))
	# Open water channels make both bridges legible; their decks supply collision.
	if x>14 and x<22 and z>-4 and z<8: result=-1.5
	if z< -11 and z> -23 and absf(x)<4: result=-1.5
	# A gently sloped overlook inside the forest, away from the main trail.
	if x>42 and z< -8 and forest>2:
		result+=smoothstep(43,52,x)*smoothstep(-8,-15,z)*1.5
	return result

static func road_distance(x: float,z: float) -> float:
	var p := Vector2(x,z)
	return minf(path_distance(p,EAST_ROAD),minf(path_distance(p,NORTH_ROAD),path_distance(p,WOODLAND_ROAD)))

static func grass_density(x: float,z: float) -> float:
	if ground(x,z)<1: return 0
	if x>3.5 and x<7.3 and z<.1 and z> -4.1: return 0
	if x>.6 and x<4.4 and z>7 and z<12: return 0
	if Vector2(x+5,z+2.5).length()<4.65: return 0
	if z> -7 and z<8 and absf(x-(1.6+sin(z*.43)*1.2))<1.35: return 0
	if z< -6.7 and z> -9 and absf(x+4)<4: return 0
	var trail := smoothstep(1.0,2.2,road_distance(x,z))
	var plaza := smoothstep(5.7,7.7,Vector2(x,z+40).length())
	return trail*plaza

static func grass_allowed(x: float,z: float) -> bool:
	return grass_density(x,z)>.65
