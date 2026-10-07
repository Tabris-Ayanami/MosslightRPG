extends Node3D
## A small, reusable interaction placed beside an existing village house.
const Art = preload("res://scripts/art.gd")
@export var house_path: NodePath = NodePath("../Buildings/House_3")
var display_name := "村屋木梯"
var interaction_prompt := "F 攀爬木梯 · W/S 上下"
var _bottom := Vector3.ZERO
var _top := Vector3.ZERO
var _ground_exit := Vector3.ZERO
var _roof_exit := Vector3.ZERO
var _facing := Vector3.FORWARD
var landing: StaticBody3D
var persistent_id := "interaction.ladder.village_house_3"
var dismantled := false
var _ladder_parts: Array[Node3D] = []
var _hover_bounds := AABB()

func _ready() -> void:
	add_to_group("interactables")
	add_to_group("village_ladders")
	var house := get_node(house_path) as Node3D
	global_transform = Transform3D(house.global_basis.orthonormalized(), house.to_global(Vector3(.038, 0, 1.85)))
	_facing = -global_basis.z
	_bottom = house.to_global(Vector3(.038, .04, 2.05))
	_top = house.to_global(Vector3(.038, 3.30, 2.05)) + Vector3.UP * .045
	_ground_exit = house.to_global(Vector3(.038, .06, 2.52))
	_roof_exit = house.to_global(Vector3(.038, 3.30, 1.25)) + Vector3.UP * .045
	var height: float = _top.y - global_position.y + .85
	_hover_bounds = AABB(Vector3(-.44,0,-.13),Vector3(.88,height,.26))
	for x in [-.36, .36]:
		_ladder_parts.append(Art.box(self, Vector3(x, height * .5, 0), Vector3(.10, height, .12), Color("73502f")))
	for i in range(int(height / .32)):
		_ladder_parts.append(Art.box(self, Vector3(0, .18 + i * .32, -.015), Vector3(.74, .08, .10), Color("ac8050")))
	# The existing steep roof has no walkable ridge collider. This one small
	# wooden service platform supplies a visible, capsule-sized landing.
	var center := to_local(_roof_exit - Vector3.UP * (.045 + .06))
	landing = Art.solid_box(self, center, Vector3(1.08, .12, 1.35), Color("795b37"))
	landing.name = "RooftopLanding"
	for x in [-.36, 0.0, .36]:
		Art.box(self, center + Vector3(x, .065, 0), Vector3(.012, .008, 1.32), Color("473d2c"))

func _grounded(point: Vector3) -> Vector3:
	if not is_inside_tree(): return point
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 3, point - Vector3.UP * 6, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return Vector3(point.x, float(hit.position.y) + .04, point.z) if not hit.is_empty() else point

func bottom_anchor() -> Vector3:
	var ground := _grounded(_ground_exit)
	return Vector3(_bottom.x, ground.y, _bottom.z)
func interaction_hover_bounds() -> AABB:
	# The gaps between rungs belong to the ladder, but the roof platform does not.
	return _hover_bounds
func top_anchor() -> Vector3:
	return _top
func bottom_exit() -> Vector3:
	return _grounded(_ground_exit)
func top_exit() -> Vector3:
	return _roof_exit
func facing_direction() -> Vector3:
	return _facing
func interaction_distance(point: Vector3) -> float:
	if dismantled: return INF
	return minf(point.distance_to(bottom_exit()), point.distance_to(top_exit()))
func prompt(_game: Node) -> String:
	return interaction_prompt
func interact(game: Node) -> void:
	if dismantled: return
	game.controlled_actor().ladder.try_interact(self)

func apply_dismantled(value: bool) -> void:
	dismantled=value
	for part in _ladder_parts: part.visible=not value
	# The house's service landing remains a solid floor after removing its ladder.
