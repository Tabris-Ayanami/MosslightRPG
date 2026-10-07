shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0,1.0) = 1.0;
void fragment() {
	vec3 scene = textureLod(screen_texture, SCREEN_UV, 2.4 * amount).rgb;
	vec3 restful = mix(scene, vec3(0.075, 0.135, 0.105), 0.36 * amount);
	COLOR = vec4(restful, 1.0);
}
