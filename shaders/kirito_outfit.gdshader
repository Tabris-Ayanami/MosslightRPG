shader_type spatial;
render_mode cull_disabled, specular_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0);
uniform bool has_texture = true;
uniform int cloth_layer = 0;
uniform vec4 torso_color : source_color = vec4(0.0);
uniform vec4 legs_color : source_color = vec4(0.0);
uniform vec4 feet_color : source_color = vec4(0.0);
uniform vec4 head_color : source_color = vec4(0.0);
uniform vec4 belt_color : source_color = vec4(0.0);
uniform vec4 neck_color : source_color = vec4(0.0);
uniform vec4 ring1_color : source_color = vec4(0.0);
uniform vec4 ring2_color : source_color = vec4(0.0);
uniform int torso_pattern = 0;
uniform int legs_pattern = 0;
uniform int feet_pattern = 0;
uniform int head_pattern = 0;

float fabric_pattern(vec2 uv, int kind) {
	if (kind == 1) return sin(uv.x * 460.0) * sin(uv.y * 510.0) * 0.055;
	if (kind == 2) return -smoothstep(0.88, 0.98, abs(sin((uv.x + uv.y) * 92.0))) * 0.11;
	if (kind == 3) return sin((uv.x * 1.6 + uv.y) * 360.0) * 0.045;
	if (kind == 4) return -smoothstep(0.89, 0.98, abs(sin(uv.y * 150.0))) * 0.09;
	if (kind == 5) return (fract(sin(dot(floor(uv * 320.0), vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.05;
	if (kind == 6) return -smoothstep(0.90, 0.99, abs(sin((uv.x - uv.y) * 130.0))) * 0.075;
	return 0.0;
}

void fragment() {
	vec4 tex = has_texture ? texture(albedo_texture, UV) : vec4(1.0);
	vec3 original = max(tex.rgb * tint.rgb, vec3(0.035, 0.045, 0.065));
	// UV2 stores original bind-pose x/y, so these garment regions stay fixed
	// while the skinned arms/coat move. No positions or skin weights are changed.
	float x = UV2.x;
	float height = UV2.y;
	vec4 dye = torso_color;
	int pattern = torso_pattern;
	if (height < 0.86 && cloth_layer != 1) { dye = legs_color; pattern = legs_pattern; }
	if (height < 0.30 && abs(x) < 0.20 && cloth_layer != 1) { dye = feet_color; pattern = feet_pattern; }
	if (height > 1.28 && abs(x) < 0.27 && head_color.a > 0.0) { dye = head_color; pattern = head_pattern; }
	if (abs(height - 0.92) < 0.043 && abs(x) < 0.24 && belt_color.a > 0.0) dye = belt_color;
	if (height > 1.10 && height < 1.25 && abs(x) < 0.085 && neck_color.a > 0.0) dye = neck_color;
	if (abs(x) > 0.43 && height > 1.16) {
		if (x < 0.0 && ring1_color.a > 0.0) dye = ring1_color;
		if (x > 0.0 && ring2_color.a > 0.0) dye = ring2_color;
	}
	// The under-body atlas contains exposed skin. Its warm, bright islands are
	// excluded; face, hair and hand/glove surfaces never use this shader at all.
	float skin = cloth_layer == 0 && tex.r > tex.b * 1.15 && tex.r > 0.17 ? 1.0 : 0.0;
	float luminance = dot(tex.rgb, vec3(0.2126, 0.7152, 0.0722));
	float detail = clamp(0.50 + luminance * 4.0, 0.50, 1.12);
	vec3 dyed = dye.rgb * (detail + fabric_pattern(UV, pattern));
	float trim = smoothstep(0.09, 0.42, luminance);
	dyed = mix(dyed, mix(dye.rgb, vec3(0.72), 0.65), trim * 0.68);
	ALBEDO = mix(original, max(dyed, vec3(0.015)), dye.a * (1.0 - skin));
	ROUGHNESS = 0.9;
}

void light() {
	float n = dot(NORMAL, LIGHT);
	float shade = n > .5 ? 1.0 : (n > -.05 ? .78 : .52);
	float shadow = mix(.60, 1.0, smoothstep(.15, .8, ATTENUATION));
	DIFFUSE_LIGHT += LIGHT_COLOR * shade * shadow * (LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION) / 3.14159265;
}
