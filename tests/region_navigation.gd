extends SceneTree
var game: Node
var checks := 0
var failures: Array[String]=[]
func _initialize() -> void:
	call_deferred("run")
func ticks(n: int) -> void:
	for i in range(n):
		await physics_frame
		await process_frame
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok: failures.append(label)
	print("PASS " if ok else "FAIL ",label)
func walk_to(destination: Vector2,limit := 380) -> bool:
	var target: Vector3=game.GARDEN_ORIGIN+Vector3(destination.x,2.2,destination.y)
	for i in range(limit):
		var delta: Vector3=target-game.player.global_position
		delta.y=0
		game._release_actions()
		if delta.length()<.32:return true
		var d:=delta.normalized()
		var horizontal: float=d.dot(game.camera_right())
		var vertical: float=d.dot(game.camera_forward())
		Input.action_press("move_right" if horizontal>=0 else "move_left",absf(horizontal))
		Input.action_press("move_up" if vertical>=0 else "move_down",absf(vertical))
		await ticks(1)
		if game.player.global_position.y<1.6:
			game._release_actions()
			return false
	game._release_actions()
	print("BLOCKED_AT ",game.reference_map.to_local(game.player.global_position)," target=",destination)
	return false
func start(at: Vector2) -> void:
	game.player.restore(game.GARDEN_ORIGIN+Vector3(at.x,2.35,at.y))
	await ticks(10)
func run() -> void:
	game=load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await ticks(15)
	var forest: Node=game.reference_map.get_node("EasternForest")
	var village: Node=game.reference_map.get_node("NorthernVillage")
	check(forest.get_node("Trees").get_child_count()>=40,"eastern forest contains at least forty trees")
	check(village.get_node("Buildings").get_child_count()==7,"seven village buildings load with the market square")
	check(not game.hud.visible,"expanded regions do not add HUD or text")
	await start(Vector2(8.7,1.7))
	check(await walk_to(Vector2(26,1.7)),"walk east across the whole bridge without falling or respawning")
	check(await walk_to(Vector2(9,1.7)),"walk back from forest to garden")
	await start(Vector2(0,-8.4))
	check(await walk_to(Vector2(0,-26)),"north bridge is walkable from shrine to village")
	check(await walk_to(Vector2(0,-34)),"village entrance connects to market square")
	check(await walk_to(Vector2(1,-39)),"player can move between stalls and well")
	await start(Vector2(29,0))
	var connected := true
	for waypoint in [Vector2(28,-10),Vector2(26,-18),Vector2(21,-27),Vector2(12,-34),Vector2(4,-35)]:
		if not await walk_to(waypoint):
			connected=false
			break
	check(connected,"woodland trail connects forest to village through the northern pass")
	await start(Vector2(1.6,4.8))
	var exit_clear := true
	for waypoint in [Vector2(.5,-3.8),Vector2(.5,-8.5),Vector2(0,-12)]:
		if not await walk_to(waypoint):
			exit_clear=false
			break
	check(exit_clear,"default spawn can reach the north bridge around the shrine")
	game.player.global_position=game.GARDEN_ORIGIN+Vector3(75,-1,-30)
	await ticks(12)
	check(game.player.global_position.distance_to(game.checkpoint)>20 and game.player.swimming,"water beyond the old map bounds supports swimming without respawn")
	print("REGION_NAVIGATION_RESULT %d/%d passed"%[checks-failures.size(),checks])
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
