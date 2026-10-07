extends RefCounted
## Pull back behind the traveller for the sky choices, then crane above the ground.
const STORY=preload("res://scripts/frontend/title_story.gd")
const SUBJECT := Vector3(3.15,0,.8)
const FORWARD := STORY.FACING
const RIGHT := Vector3(-.6,0,.8)
const HORIZON_POSITION := SUBJECT-FORWARD*78+RIGHT*3.5+Vector3(0,1.0,0)
const FRAME := Basis(RIGHT,Vector3.UP,-FORWARD)
const ROOF_CENTER := SUBJECT+FORWARD*6+Vector3(0,100,0)
const ORIGINS := [Vector3(150,228,-310),Vector3(-185,64,-300),Vector3(224,77,-346),Vector3(-180,290,-360),Vector3(172,292,-585)]
const SIZES := [Vector3(47,25,33),Vector3(34,12,23),Vector3(45,17,29),Vector3(34,21,25),Vector3(39,15,28)]

static func cloud_centers(_progress: float=0.0) -> PackedVector3Array:
	var centers := PackedVector3Array()
	for point: Vector3 in ORIGINS: centers.append(HORIZON_POSITION+FRAME*(point-Vector3(0,0,-18)))
	return centers

static func horizon_pose() -> Transform3D:
	return Transform3D(FRAME*Basis(Vector3.RIGHT,deg_to_rad(18)),HORIZON_POSITION)

static func camera_pose(progress: float) -> Transform3D:
	if progress<=0: return horizon_pose()
	var t := smoothstep(0,1,progress)
	var target := SUBJECT+FORWARD*STORY.distance_at(STORY.CHOICE_TIME+progress*STORY.DEPARTURE_TIME)
	var position := target-FORWARD*lerpf(78,3,smoothstep(.05,.96,progress))+RIGHT*3.5*(1-t)
	position.y=lerpf(1,103,pow(t,1.25))
	var looking := Transform3D(Basis.IDENTITY,position).looking_at(target).basis
	var basis := horizon_pose().basis.slerp(looking,smoothstep(0,.27,progress))
	return Transform3D(basis,position)
