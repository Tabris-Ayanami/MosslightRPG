extends SceneTree
var app: Node
func _initialize() -> void: call_deferred("run")
func snapshot() -> Image:
	for i in range(5): await process_frame
	await RenderingServer.frame_post_draw
	return app.cloud_view.get_texture().get_image()
func area(image: Image, threshold: float) -> float:
	var count := 0
	var total := 0
	for y in range(0,image.get_height(),4):
		for x in range(0,image.get_width(),4):
			total+=1
			if image.get_pixel(x,y).a>=threshold: count+=1
	return float(count)/total
func run() -> void:
	app=load("res://scenes/frontend/app.tscn").instantiate()
	root.add_child(app)
	await process_frame
	app.set_process(false)
	app.journey_cursor=1
	app._sample_journey()
	var before := await snapshot()
	app.ascent_cursor=0
	app._sample_ascent()
	var after := await snapshot()
	var covered := area(before,.2)
	var unchanged := before.get_data()==after.get_data()
	print("CLOUD_AUDIT sparse_sky_coverage=",covered," identical_at_departure=",unchanged)
	app.ascent_cursor=.93
	app._sample_ascent()
	var inside := await snapshot()
	var opaque := area(inside,.98)
	print("CLOUD_AUDIT opaque_fraction_before_cover=",opaque," cover=",app.cloud_material.get_shader_parameter("cover"))
	var passed := unchanged and covered>.025 and covered<.18 and opaque>.98
	print("CLOUD_AUDIT ","PASS" if passed else "FAIL")
	app.queue_free()
	for i in range(12): await process_frame
	quit(0 if passed else 1)
