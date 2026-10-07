extends SceneTree
## Narrow GPU regression for the shipped evoker ground-area effects.
## Godot --path . --rendering-method gl_compatibility --fixed-fps 60 --script tests/combat_persistent_visual.gd

const Attack = preload("res://combat/attack_instance.gd")
const OUTPUT := "res://docs/combat/"
var arena
var checks := 0
var failures := 0
var report: PackedStringArray = []

func _initialize() -> void:
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	failures += 0 if ok else 1
	var text := ("PASS " if ok else "FAIL ") + label
	print(text)
	report.append(text)

func ticks(count: int) -> void:
	for i in range(count):
		await physics_frame
		await process_frame

func find_area(id: String) -> Node:
	for node in arena.effects.get_children():
		if node.get_script() == Attack and node.action.get("id", "") == id:
			return node
	return null

func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		verify(false, "GPU renderer required for persistent visual evidence")
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	verify(image.get_size() == Vector2i(1280, 720), "capture native 1280x720 framebuffer")
	verify(image.save_png(ProjectSettings.globalize_path(OUTPUT + name + ".png")) == OK, "saved " + name + ".png")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1280, 720)
	arena = load("res://scenes/demo/CombatTestArena.tscn").instantiate()
	root.add_child(arena)
	for enemy in arena.enemies:
		enemy.ai_enabled = false
	arena.player.loadout.select_career("mage")
	arena.player.loadout.set_level(3)
	arena.player.loadout.select_career("evoker")
	arena.player.loadout.assign_skill(0, 0, "evoker_ice_storm")
	arena.player.loadout.assign_skill(0, 1, "evoker_fire_wall")
	arena.player.loadout.assign_skill(0, 2, "mage_lightning")
	arena.ui.toggle_menu(false)
	arena.toast_time = 0
	arena.player.global_position = Vector3(0, 0.1, 8)
	var ice_center := Vector3(-5, 0, 1)
	var fire_center := Vector3(5, 0, 1)
	arena.enemies[0].global_position = ice_center + Vector3.UP * 0.05
	arena.enemies[1].global_position = fire_center + Vector3.UP * 0.05
	var ice_start_hp: float = arena.enemies[0].resources.current("HP")
	var fire_start_hp: float = arena.enemies[1].resources.current("HP")
	arena.aim_override = ice_center
	arena.aim_point = ice_center
	arena.player.facing = (ice_center - arena.player.global_position).normalized()
	verify(arena.player.combat.use_action(arena.database.skills.evoker_ice_storm), "real mage controller accepts Ice Storm")
	await ticks(40)
	var ice := find_area("evoker_ice_storm")
	verify(is_instance_valid(ice) and is_instance_valid(ice.visual), "Ice Storm owns persistent circle geometry")
	verify(is_instance_valid(ice) and ice.visual.is_visible_in_tree(), "Ice Storm circle is visible after cast animation ends")
	verify(arena.player.combat.can_start(), "first cast completed while its area stays alive")
	arena.aim_override = fire_center
	arena.aim_point = fire_center
	arena.player.facing = Vector3.RIGHT
	verify(arena.player.combat.use_action(arena.database.skills.evoker_fire_wall), "real mage controller accepts Fire Wall")
	await ticks(40)
	var fire := find_area("evoker_fire_wall")
	verify(is_instance_valid(fire) and is_instance_valid(fire.visual), "Fire Wall owns persistent line geometry")
	verify(is_instance_valid(fire) and fire.visual.is_visible_in_tree(), "Fire Wall remains visible after cast animation ends")
	verify(is_instance_valid(fire) and fire.action.get("center_on_point", false), "line geometry uses the actual chosen ground point")
	verify(arena.enemies[0].resources.current("HP") < ice_start_hp, "enemy inside Ice Storm receives real periodic damage")
	verify(arena.enemies[1].resources.current("HP") < fire_start_hp, "enemy inside Fire Wall receives real periodic damage")
	verify(not arena.sound.muted and arena.sound.cursor >= 2, "cast and hit feedback use active arena audio voices")
	verify(arena.sound.cache.has("skill") and arena.sound.cache.skill.data.size() > 0, "spell sound stream contains generated audio samples")
	await capture("visual_persistent_zones_1280")
	var guard := 0
	while is_instance_valid(ice) and ice.time < 3.55 and guard < 600:
		await ticks(1)
		guard += 1
	verify(is_instance_valid(ice) and ice.visual.is_visible_in_tree(), "Ice Storm ground circle still visible near end of 4-second lifetime")
	while is_instance_valid(ice) and guard < 700:
		await ticks(1)
		guard += 1
	verify(not is_instance_valid(ice), "Ice Storm geometry disappears at the effect's expiry")
	verify(is_instance_valid(fire) and fire.visual.is_visible_in_tree(), "6-second Fire Wall outlives 4-second Ice Storm")
	guard = 0
	while is_instance_valid(fire) and fire.time < 5.55 and guard < 600:
		await ticks(1)
		guard += 1
	verify(is_instance_valid(fire) and fire.visual.is_visible_in_tree(), "Fire Wall ground line remains visible near end of lifetime")
	while is_instance_valid(fire) and guard < 700:
		await ticks(1)
		guard += 1
	verify(not is_instance_valid(fire), "Fire Wall geometry disappears at the effect's expiry")
	verify(find_area("evoker_ice_storm") == null and find_area("evoker_fire_wall") == null, "no stale persistent visual nodes remain")
	await capture("visual_persistent_zones_expired_1280")
	var summary := "COMBAT_PERSISTENT_VISUAL_RESULT checks=%d failures=%d" % [checks, failures]
	print(summary)
	report.append(summary)
	report.append("Renderer: " + RenderingServer.get_video_adapter_name())
	var log := FileAccess.open(OUTPUT + "persistent_visual_test.log", FileAccess.WRITE)
	log.store_string("\n".join(report) + "\n")
	quit(0 if failures == 0 else 1)
