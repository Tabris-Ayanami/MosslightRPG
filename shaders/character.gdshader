shader_type spatial;
render_mode cull_disabled, specular_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0);
uniform bool has_texture = true;
uniform bool cutout = false;
void fragment() {
    vec4 tex = has_texture ? texture(albedo_texture, UV) : vec4(1.0);
    if (cutout && tex.a < 0.45) discard;
    // Keep black cloth readable at the game's low internal resolution.
    ALBEDO = max(tex.rgb * tint.rgb, vec3(0.035, 0.045, 0.065));
    ROUGHNESS = 0.9;
}
void light() {
    float n = dot(NORMAL, LIGHT);
    float shade = n > .5 ? 1.0 : (n > -.05 ? .78 : .52);
    float shadow = mix(.60, 1.0, smoothstep(.15, .8, ATTENUATION));
    DIFFUSE_LIGHT += LIGHT_COLOR * shade * shadow * (LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION) / 3.14159265;
}
