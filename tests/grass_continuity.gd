extends SceneTree
## GPU regression: adjacent noise cells must meet continuously at their shared edge.
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var viewport := SubViewport.new()
	viewport.size=Vector2i(64,32)
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var rect := ColorRect.new()
	rect.size=Vector2(64,32)
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code="""shader_type canvas_item;
render_mode unshaded;
#include "res://shaders/reference_common.gdshaderinc"
void fragment(){
    vec2 cell=floor(UV*vec2(64,32));
    vec2 p=vec2(cell.x-32.0,cell.y+95.0);
    vec2 jitter=vec2(.0002,.371);
    float left=field_noise(p+vec2(-jitter.x,jitter.y));
    float right=field_noise(p+jitter);
    COLOR=vec4(left,right,0,1);
}"""
	mat.shader=shader
	rect.material=mat
	viewport.add_child(rect)
	for i in range(4): await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var max_error := .0
	for y in range(32):
		for x in range(64):
			var c := image.get_pixel(x,y)
			max_error=maxf(max_error,absf(c.r-c.g))
	print("GRASS_CONTINUITY max seam error=",max_error," across 2048 lattice edges")
	viewport.queue_free()
	await process_frame
	quit(0 if max_error<.009 else 1)
