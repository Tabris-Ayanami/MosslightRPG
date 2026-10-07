extends SceneTree
## Compare actual pixels with the immediate presenter and verify movement reuse.
const HUD = preload("res://combat/battle_hud.gd")
var checks := 0
var failures: Array[String] = []
var panes: Array[SubViewport] = []
var presenters: Array[RefCounted] = []
var canvases: Array[Control] = []
var output := ""
var measurements: Array = []
class Canvas extends Control:
	var presenter: RefCounted
	func _draw() -> void: presenter.draw(self)
func _initialize() -> void:
	create_timer(30).timeout.connect(func(): quit(2))
	call_deferred("run")
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
func frame() -> void:
	for i in range(3): await process_frame
	await RenderingServer.frame_post_draw
func entries(helper: RefCounted) -> void:
	helper.overhead_entries.assign([{"id":1,"relation":&"hostile","position":Vector2(200,170),"width":76.0,"name":"巡林卫士","level":3,"ratio":.63,"trail":.85,"impact":0.0,"poise":.8,"exposed":false}])
	helper.lock_entries.assign([{"feet":Vector2(200,225),"head":Vector2(200,170),"show_head":true}])
	helper.boss_entry = {"id":2,"position":Vector2(320,68),"width":420.0,"name":"石脊守卫","level":5,"title":"区域头目","ratio":.7,"trail":.8,"exposed":true}
	helper.number_entries.assign([{"position":Vector2(210,125),"age":.3,"text":"128","color":Color("f2c99a"),"target_id":1}])
	helper.status_entries.assign([{"position":Vector2(390,200),"age":.4,"text":"破绽","color":Color.WHITE}])
func compare(label: String) -> void:
	canvases[0].queue_redraw()
	presenters[1]._sync_retained()
	await frame()
	var images: Array[Image] = [panes[0].get_texture().get_image(), panes[1].get_texture().get_image()]
	var a := images[0].get_data(); var b := images[1].get_data()
	var difference := 0; var changed := 0
	for i in range(a.size()):
		var d := absi(int(a[i])-int(b[i]))
		difference += d
		if d>8: changed += 1
	var mean := float(difference)/a.size()/255.0
	measurements.append({"case":label,"mean_byte_error":mean,"channels_changed_over_8":changed})
	check(mean < .001, label + " preserves rendered bars, rings, text and overlap")
	if not output.is_empty():
		images[0].save_png(output.path_join(label+"-immediate.png"))
		images[1].save_png(output.path_join(label+"-retained.png"))
func draw_count() -> int:
	var result := 0
	for ref in presenters[1]._retained.values():
		var node: Node = ref.get_ref()
		if is_instance_valid(node): result += node.draw_count
	return result
func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence="): output = arg.trim_prefix("--evidence=")
	if DisplayServer.get_name() == "headless": quit(1); return
	if not output.is_empty(): DirAccess.make_dir_recursive_absolute(output)
	for retained in [false,true]:
		var pane := SubViewport.new()
		pane.size = Vector2i(640,360)
		pane.disable_3d = true
		pane.transparent_bg = true
		pane.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(pane); panes.append(pane)
		var canvas := Canvas.new(); canvas.size = Vector2(640,360)
		canvas.presenter = HUD.new(); pane.add_child(canvas)
		presenters.append(canvas.presenter); canvases.append(canvas)
		if retained: canvas.presenter.attach(canvas)
		entries(canvas.presenter)
	await compare("initial")
	var count := draw_count()
	for i in range(10):
		for helper in presenters:
			helper.overhead_entries[0].position += Vector2(1,1)
			helper.lock_entries[0].feet += Vector2(1,1)
			helper.lock_entries[0].head += Vector2(1,1)
			helper.number_entries[0].position += Vector2(1,-1)
			helper.status_entries[0].position += Vector2(1,0)
		presenters[1]._sync_retained()
		await frame()
	check(draw_count() == count,"translation retains draw commands for unchanged bars, rings and text")
	await compare("moved")
	for helper in presenters:
		helper.overhead_entries[0].ratio = .32
		helper.overhead_entries[0].trail = .61
		helper.overhead_entries[0].poise = .15
		helper.overhead_entries[0].exposed = true
		helper.number_entries[0].age = .02
		helper.number_entries[0].color.a = .55
	await compare("damaged")
	check(draw_count() > count,"HP, poise, break and number pop invalidate the matching entries")
	for helper in presenters: helper.ui_scale = 1.5
	await compare("resized")
	for helper in presenters: helper.clear()
	await compare("cleared")
	check(presenters[1]._retained.is_empty(),"hide/clear drops every retained actor identity")
	for pane in panes: pane.queue_free()
	await frame()
	presenters.clear(); canvases.clear(); panes.clear()
	var report := {"checks":checks,"failures":failures,"measurements":measurements}
	if not output.is_empty():
		var file := FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
		file.store_string(JSON.stringify(report,"\t")); file.close()
	print("BATTLE_RETAINED ",JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
