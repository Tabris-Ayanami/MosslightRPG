extends "res://tests/combat_charge_visual.gd"
## Actual engagement/timeout/input, bone-relative carry, and frozen ladder phase.
var actor
var visual

func bone_snapshot() -> Array:
	var result := []
	for name: String in ["J_Bip_L_UpperArm", "J_Bip_R_UpperArm", "J_Bip_L_UpperLeg", "J_Bip_R_UpperLeg", "J_Bip_L_LowerLeg", "J_Bip_R_LowerLeg"]:
		result.append(visual.skeleton.get_bone_global_pose(visual._bones[name]))
	return result

func hand_height(left: bool) -> float:
	return visual._rig.to_local(visual._bone_world("L_Hand" if left else "J_Bip_R_Hand").origin).y

func carry(label: String) -> void:
	verify(visual.weapons_stowed and not visual.combat_pose_active, label + " is relaxed with back carry")
	verify(visual.skeletal_clip in ["Idle", "Run"], label + " samples natural locomotion")
	verify(visual.back_attachment_error < .001, label + " stays attached to the real chest bone")
	for node in [visual._weapon, visual._dual_weapon, visual._shield]:
		if is_instance_valid(node):
			var local: Vector3 = visual.carry_anchor.affine_inverse() * node.global_position
			verify(local.length() < .65 and local.z >= .17 and local.z <= .29, label + " equipment stays close behind the torso")

func run() -> void:
	root.size = Vector2i(1920, 1080)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	await tick(5)
	actor = arena.player
	visual = actor.animation
	arena.ui.toggle_menu(false)
	arena.toast_time = 0
	arena.renderer.camera_height = 8
	arena.renderer.target_camera_height = 8
	for enemy in arena.enemies:
		enemy.set_physics_process(false)
	await tick(25)
	verify(visual.weapon_family == "UNARMED" and not visual.combat_pose_active and visual.skeletal_clip == "Idle", "Lv0 civilian idles naturally out of combat")
	var relaxed_height := (hand_height(true) + hand_height(false)) * .5
	verify(relaxed_height < 1.05, "relaxed civilian lowers both hands")
	await capture("stance_unarmed_relaxed_1080")
	actor.combat.engage()
	await tick(3)
	verify(visual.combat_pose_active and not visual.weapons_stowed and hand_height(true) > relaxed_height + .1, "engagement raises the civilian boxing guard")
	await capture("stance_unarmed_combat_1080")
	await tick(305)
	verify(not actor.combat.in_combat and not visual.combat_pose_active and hand_height(true) < 1.05, "real five-second combat timeout lowers fists again")
	await key(KEY_W, true)
	await tick(8)
	verify(visual.skeletal_clip == "Run" and visual.current_animation == "travel_run", "out-of-combat WASD uses natural run instead of boxing")
	await key(KEY_W, false)
	await tick(10)
	actor.facing = Vector3.FORWARD
	arena.aim_override = actor.global_position + Vector3.FORWARD * 3
	await mouse(true)
	await mouse(false)
	verify(visual.combat_pose_active and not visual.weapons_stowed and actor.combat.state == "ACTION", "actual civilian attack draws immediately even before engagement")
	while actor.combat.runner.busy(): await tick()
	await tick(3)
	verify(not visual.combat_pose_active, "missed attack returns to natural idle after its recovery")
	verify(actor.loadout.select_career("warrior"), "actual warrior gear is equipped")
	await tick(15)
	carry("single sword")
	var grip: Vector3 = visual._rig.to_local(visual._weapon.global_position)
	var head: Vector3 = visual._rig.to_local(visual._bone_world("J_Bip_C_Head").origin)
	verify(grip.y < head.y and absf(grip.x - head.x) > .12, "back sword grip stays beside and below the head")
	await capture("stance_sword_back_1080")
	actor.combat.engage()
	await tick(3)
	verify(visual.skeletal_clip == "SwordIdle" and not visual.weapons_stowed and visual._weapon.global_position.distance_to(visual._bone_world("J_Bip_R_Hand").origin) < .001, "engagement restores sword stance and real hand attachment")
	await capture("stance_sword_drawn_1080")
	actor.combat.combat_timeout = .03
	await tick(4)
	verify(actor.loadout.equip_weapon(0, "azure_katana"), "actual out-of-combat gear change succeeds")
	verify(visual._weapon.global_position.distance_to(visual.carry_anchor.origin) < .65, "new weapon is placed on the back immediately within the equipment callback")
	await tick(3)
	await mouse(true)
	verify(actor.combat.state == "CHARGING" and visual.combat_pose_active and not visual.weapons_stowed, "sword press draws immediately on real charge startup")
	await mouse(false)
	while actor.combat.runner.busy(): await tick()
	await tick(2)
	actor.loadout.set_level(10)
	verify(actor.loadout.select_career("swordsman") and actor.loadout.select_career("dual_swordsman"), "actual dual-sword profession selected")
	await tick(4)
	carry("dual swords")
	verify(visual._weapon.global_position.distance_to(visual._dual_weapon.global_position) > .3, "both back sword grips remain on separate shoulders")
	await capture("stance_dual_back_1080")
	actor.combat.engage()
	await tick(3)
	verify(not visual.weapons_stowed and visual._dual_weapon.global_position.distance_to(visual._bone_world("L_Hand").origin) < .001, "dual combat stance restores left-hand weapon")
	actor.loadout.select_career("warrior")
	actor.loadout.set_level(2)
	verify(actor.loadout.select_career("soldier"), "actual sword-and-shield profession selected")
	await tick(4)
	carry("sword and shield")
	await capture("stance_shield_back_1080")
	await mouse(true, true)
	verify(not visual.weapons_stowed and actor.combat.state == "ACTION", "shield input draws from the back immediately")
	await mouse(false, true)
	await tick(35)
	actor.combat.reset()
	visual.equip_shield({})
	for id: String in ["hunter_dagger", "border_spear", "iron_greatsword", "shortbow", "apprentice_staff", "storm_orb"]:
		var data: Dictionary = arena.database.weapons[id]
		visual.switch_weapon_family(data.animation_family, data)
		visual.set_weapon_visible(true)
		await tick(3)
		carry(id)
		await capture("stance_back_" + id + "_1080")
	visual.switch_weapon_family("SINGLE_BLADE", arena.database.weapons.iron_longsword)
	actor.set_physics_process(false)
	visual.set_climbing(true, .25, true)
	var phase_a := bone_snapshot()
	verify(visual.climbing_active and visual.weapons_stowed and visual.current_animation == "climb_ik", "ladder API stows gear and activates skeletal climbing")
	visual.set_climbing(true, .75, true)
	verify(phase_a != bone_snapshot(), "ladder phase moves real arm and leg bone chains")
	var frozen := bone_snapshot()
	for i in range(10): visual.set_climbing(true, .75, false)
	verify(frozen == bone_snapshot() and visual.current_animation == "climb_hold", "stationary ladder phase freezes all four limb targets")
	await capture("stance_climbing_ik_1080")
	visual.set_climbing(false, 0, false)
	verify(not visual.climbing_active and visual.current_animation == "travel_idle", "leaving ladder restores normal travel pose")
	arena.queue_free()
	await tick(5)
	await main_world_ladder()
	var summary := "COMBAT_STANCE_VISUAL_RESULT checks=%d failures=%d captures=%d" % [checks, failures, images.size()]
	print(summary)
	report.append(summary)
	report.append("RunUTC: " + Time.get_datetime_string_from_system(true))
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	var file := FileAccess.open(OUTPUT + "stance_visual_test.log", FileAccess.WRITE)
	file.store_string("\n".join(report) + "\n")
	quit(0 if failures == 0 else 1)

func main_world_ladder() -> void:
	var app = load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await tick(3)
	app._enter_world(load("res://scenes/main.tscn"))
	await tick(3)
	app._finish_arrival()
	var game = app.game
	arena = game.combat_world
	actor = game.player
	visual = actor.animation
	verify(actor.progression.choose_career("warrior"), "main-world warrior fixture uses the actual progression API")
	app.ui.close_panel(true)
	app.ui.region_clock = 0
	game.sound.muted = true
	arena.encounters_started = true
	var ladder: Node3D = game.reference_map.get_node("NorthernVillage/VillageHouseLadder")
	actor.restore(ladder.bottom_exit() + Vector3.UP * .02)
	await tick(35)
	verify(game.nearest_interactable() == ladder, "actual village house ladder is in interaction reach")
	await key(KEY_F, true)
	await key(KEY_F, false)
	verify(actor.ladder.active and visual.climbing_active and visual.weapons_stowed, "physical F enters the real house ladder and stows the sword")
	var start: Vector3 = actor.global_position
	await key(KEY_W, true)
	await tick(65)
	await key(KEY_W, false)
	await tick(4)
	verify(actor.global_position.y > start.y + 1.7 and actor.ladder.active, "physical W climbs into the middle of the village ladder")
	verify(visual.current_animation == "climb_hold" and visual.back_attachment_error < .001, "real ladder pauses with the weapon fixed to the back")
	var pose := bone_snapshot()
	var position: Vector3 = actor.global_position
	await tick(15)
	verify(pose == bone_snapshot() and actor.global_position == position, "released W holds all four skeletal limbs still on the ladder")
	await capture("stance_main_ladder_default_1080")
	# A supported player camera zoom/orbit, retaining the production renderer,
	# lighting, pitch, materials and low-resolution world viewport.
	game.target_camera_height = 8
	game.camera_yaw += .45
	await tick(35)
	await capture("stance_main_ladder_close_1080")
	var before: float = actor.ladder.phase
	await key(KEY_S, true)
	await tick(7)
	await key(KEY_S, false)
	verify(actor.global_position.y < position.y and not is_equal_approx(actor.ladder.phase, before), "physical S reverses the climbing cycle while descending")
	await key(KEY_F, true)
	await key(KEY_F, false)
	verify(not actor.ladder.active and not visual.climbing_active, "physical F releases the climbing pose without leftover IK")
	actor.restore(ladder.bottom_exit() + Vector3.UP * .02)
	await tick(8)
	verify(visual.skeletal_clip == "Idle" and visual.weapons_stowed and not visual.combat_pose_active, "main world returns to relaxed idle with the sword carried on the back")
	await capture("stance_main_sword_relaxed_1080")
	app.queue_free()
	await tick(5)
