shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

// A combat-only overlay. The original textured character shader stays intact.
// Add a narrow, pale rim instead of covering the black coat with a white fill.
void fragment() {
	float edge = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.0);
	ALBEDO = vec3(0.65, 0.70, 0.74);
	ALPHA = 0.012 + edge * 0.16;
}
