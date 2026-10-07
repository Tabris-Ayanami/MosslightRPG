extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Baking ImageTexture3D requires the real renderer for texture readback.")
		quit(1)
		return
	var source := NoiseTexture3D.new()
	source.width=96
	source.height=64
	source.depth=96
	source.seamless=true
	var noise := FastNoiseLite.new()
	noise.seed=8042
	noise.noise_type=FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency=.055
	noise.fractal_octaves=4
	noise.fractal_gain=.5
	source.noise=noise
	await source.changed
	var images := source.get_data()
	if images.is_empty():
		push_error("Cloud volume readback was empty.")
		quit(1)
		return
	var volume := ImageTexture3D.new()
	volume.create(images[0].get_format(),96,64,96,false,images)
	var result := ResourceSaver.save(volume,"res://assets/ui/sky/cloud-noise.res",ResourceSaver.FLAG_COMPRESS)
	print("CLOUD_NOISE_BAKED ",result," ",images[0].get_format())
	quit(result)
