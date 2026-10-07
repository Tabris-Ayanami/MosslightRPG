extends "res://tests/combat_feel.gd"
## Shipped family clips, actual mouse contacts/misses, fixed-length grips and
## weapon-space trails. Run at several render rates with fixed 60 Hz physics.
const Motion = preload("res://combat/melee_motion.gd")
const Impact = preload("res://combat/impact_feedback.gd")
const Trail = preload("res://combat/weapon_trail.gd")
var foe: Node
var contacts: Array[Dictionary] = []
var evidence: Array[Dictionary] = []
var observations: Array[Dictionary] = []
class ClockProbe extends Node:
	var test: SceneTree
	func _physics_process(_delta: float) -> void:
		var p: Node = test.player
		if is_instance_valid(p):
			test.observations.append({"time":p.combat.runner.action_time,"sample":p.animation.skeletal_time,"clock":p.input_router.clock,"phase":p.combat.runner.action_phase,"frozen":p.combat.stopped_this_tick,"remaining":p.combat.hitstop_remaining})

func run() -> void:
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	await ticks(4)
	player = arena.player
	foe = arena.enemies[0]
	var probe := ClockProbe.new()
	probe.test = self
	probe.process_physics_priority = 100
	root.add_child(probe)
	foe.health.damage_received.connect(func(amount: float):
		if amount > 0: contacts.append({"phase":player.combat.runner.action_phase,"time":player.combat.runner.action_time}))
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/content_pipeline/schemas/content-pack-v1.schema.json"))
	for name: String in schema["x-melee-clip-lengths"]:
		var clip := Motion.animation(name)
		verify(clip != null and absf(clip.length - float(schema["x-melee-clip-lengths"][name])) < .001, name + " compiler duration matches shipped animation")
	var invalid: Dictionary = arena.database.get_action("POLEARM","PRIMARY_TAP",0)
	invalid.motion["recovery_end"] = .5
	verify(not Motion.error_for(invalid).is_empty(), "runtime rejects an incomplete recovery pair like the compiler")
	for family in ["SHORT_WEAPON", "POLEARM", "HEAVY_2H"]:
		await fixture(family)
		var count: int = arena.database.get_combo_count(family)
		verify(count == (4 if family == "SHORT_WEAPON" else 3), family + " keeps the existing combo length")
		var clips: Array[String] = []
		for index in range(count):
			var action: Dictionary = arena.database.get_action(family,"PRIMARY_TAP",index)
			clips.append(action.motion.clip)
			verify(Motion.error_for(action).is_empty(), action.id + " has valid source markers")
			verify(Impact.is_finisher(action,arena.database) == (index == count-1), action.id + " feedback follows the actual final stage")
			check_pose(action)
			await check_contact(family,index,false)
			await check_contact(family,index,true)
		var unique_clips := {}
		for clip in clips: unique_clips[clip] = true
		verify(clips.size() == unique_clips.size(), family + " uses a distinct source motion for each stage")
	# Smaller axe/hammer heads must use their own trail extents and remain attached.
	await fixture("HEAVY_2H")
	for kind in ["battle_axe", "war_hammer"]:
		player.animation.switch_weapon_family("HEAVY_2H",{"weapon_type":kind})
		for index in range(3): check_pose(arena.database.get_action("HEAVY_2H","PRIMARY_TAP",index))
		var edge := Trail.edge("HEAVY_2H",{"weapon_type":kind})
		verify(absf(edge[0].x) > .3 and absf(edge[0].z) < 1.21, kind + " trail spans the head rather than extending a sword blade")
	await fixture("POLEARM")
	player.animation.equip_shield({"id":"test_shield"})
	var pole: Dictionary = arena.database.get_action("POLEARM","PRIMARY_TAP",0)
	player.animation.play_action(pole)
	player.animation.update_pose(0,Vector3.FORWARD,"ACTION","ACTIVE",.3)
	verify(player.animation._shield.visible and player.animation.hand_attachment_error < .001, "polearm plus shield preserves shield attachment")
	player.animation.equip_shield({})
	check_trail()
	for action_id in InputMap.get_actions(): Input.action_release(action_id)
	print("MELEE_FAMILY_MOTION ",JSON.stringify({"checks":checks,"failures":failures,"contacts":evidence}))
	probe.queue_free()
	arena.queue_free()
	await ticks(4)
	quit(0 if failures.is_empty() else 1)

func fixture(family: String) -> void:
	foe.set_physics_process(true)
	await prepare("warrior" if family == "SHORT_WEAPON" else "barbarian")
	if family == "SHORT_WEAPON": player.loadout.current_set = 1
	elif family == "POLEARM": player.loadout.equip_weapon(0,"border_spear")
	else: player.loadout.equip_weapon(0,"iron_greatsword")
	foe.resources.configure("HP",1000000)
	foe.combat.base_poise = 1000000
	foe.combat.current_poise = 1000000
	foe.facing = Vector3.FORWARD
	foe.set_physics_process(false)
	await ticks(2)
	contacts.clear()
	observations.clear()

func arm_lengths() -> PackedFloat64Array:
	var lengths := PackedFloat64Array()
	for side in ["L","R"]:
		var upper: Vector3 = player.animation._bone_world("J_Bip_"+side+"_UpperArm").origin
		var lower: Vector3 = player.animation._bone_world("J_Bip_"+side+"_LowerArm").origin
		var hand: Vector3 = player.animation._bone_world("L_Hand" if side == "L" else "J_Bip_R_Hand").origin
		lengths.append(upper.distance_to(lower))
		lengths.append(lower.distance_to(hand))
	return lengths

func check_pose(action: Dictionary) -> void:
	var visual: Node = player.animation
	visual.play_action(action)
	visual.rotation.y = 0
	var before := arm_lengths()
	var max_grip := 0.0
	var max_stretch := 0.0
	for phase in ["STARTUP","ACTIVE","RECOVERY"]:
		for i in range(13):
			visual.update_pose(0,Vector3.FORWARD,"ACTION",phase,float(i)/12)
			max_grip = maxf(max_grip,visual.support_hand_error)
			var after := arm_lengths()
			for bone in range(4): max_stretch = maxf(max_stretch,absf(before[bone]-after[bone]))
	visual.update_pose(0,Vector3.FORWARD,"ACTION","ACTIVE",0)
	var tip_length := .66 if action.animation_family == "SHORT_WEAPON" else (1.59 if action.animation_family == "POLEARM" else (1.475 if "sword" in str(visual.weapon_data.get("weapon_type","")) else 1.2))
	var tip: Vector3 = visual.to_local(visual._weapon.to_global(Vector3(0,0,-tip_length)))
	verify(max_grip < .003 and max_stretch < .001, action.id + " keeps both grips and original arm lengths through all phases")
	verify(tip.z < -.65 and absf(tip.x) < .60 and tip.y > .45 and tip.y < 1.95, action.id + " reaches the frontal body at its contact marker: " + str(tip))
	verify(visual.skeletal_clip == action.motion.clip and absf(visual.skeletal_time-float(action.motion.contact)) < .001, action.id + " uses calibrated contact time")
	evidence.append({"id":action.id,"weapon":visual.weapon_data.get("weapon_type",""),"contact_tip":str(tip),"grip_error":max_grip,"bone_length_error":max_stretch})

func check_contact(family: String, index: int, miss: bool) -> void:
	await fixture(family)
	var action: Dictionary = arena.database.get_action(family,"PRIMARY_TAP",index)
	# A nearby aimed enemy now causes one approach before the swing. An empty
	# swing needs an enemy beyond both the hit shape and mild aim acquisition.
	foe.global_position = player.global_position + Vector3.FORWARD * (maxf(4.65,float(action.range)+.12) if miss else (.95 if family == "SHORT_WEAPON" else 1.45))
	player.combat.combo = index
	player.combat.combo_timeout = 2.0
	await tap_mouse()
	var frozen_frames := 0
	var stable := true
	for i in range(140):
		await ticks(1)
		if not player.combat.runner.busy() and not player.attack_assist.approaching(): break
	# Observe every physical step, including multiple steps inside one 30 FPS frame.
	for i in range(1,observations.size()):
		var now := observations[i]
		var previous := observations[i-1]
		if now.frozen and now.remaining > .0001 and previous.phase == "ACTIVE":
			frozen_frames += 1
			stable = stable and is_equal_approx(now.time,previous.time) and is_equal_approx(now.sample,previous.sample) and now.clock > previous.clock
	verify(contacts.is_empty() if miss else contacts.size() == 1, action.id + (" misses beyond reach and aim acquisition" if miss else " physical mouse tap hits exactly once"))
	if not miss:
		verify(not contacts.is_empty() and contacts[0].phase == "ACTIVE", action.id + " damage begins in its active phase")
		verify(frozen_frames > 0 and stable, action.id + " contact freezes local motion while input continues")
	else: verify(frozen_frames == 0, action.id + " empty swing has no hitstop")

func check_trail() -> void:
	var trail := Trail.new()
	root.add_child(trail)
	trail.sample(true,"one",1.0,Vector3.ZERO,Vector3.FORWARD)
	trail.sample(true,"one",1.016,Vector3.RIGHT*.1,Vector3.FORWARD+Vector3.RIGHT*.1)
	verify(trail.visible and trail._samples.size() == 2, "trail uses two actual world-space edge samples")
	var rebuilds := trail.rebuilds
	trail.sample(true,"one",1.016,Vector3.RIGHT,Vector3.FORWARD+Vector3.RIGHT)
	verify(trail.rebuilds == rebuilds and trail._samples.size() == 2, "hitstop cannot upload duplicate trail geometry")
	trail.sample(true,"one",1.032,Vector3.RIGHT*.1,Vector3.FORWARD+Vector3.RIGHT*.1)
	verify(trail.rebuilds == rebuilds+1 and trail._samples.size() == 2, "a held pose fades existing vertices without appending duplicates")
	rebuilds = trail.rebuilds
	trail.sample(true,"one",1.032,Vector3.RIGHT*.1,Vector3.FORWARD+Vector3.RIGHT*.1)
	verify(trail.rebuilds == rebuilds, "a frozen held pose does not rebuild faded geometry")
	trail.sample(true,"two",2.0,Vector3.RIGHT,Vector3.FORWARD+Vector3.RIGHT)
	verify(not trail.visible and trail._samples.size() == 1, "new action cannot connect to previous weapon history")
	trail.sample(false,"two",2.016,Vector3.ZERO,Vector3.ZERO)
	verify(not trail.visible and trail._samples.is_empty(), "cancel, stow and inactive windows clear the trail")
	trail.queue_free()
