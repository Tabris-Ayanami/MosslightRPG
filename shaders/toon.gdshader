shader_type spatial;
render_mode specular_disabled;
uniform vec4 base_color : source_color = vec4(0.5, 0.7, 0.4, 1.0);
uniform float variation = 0.0;
uniform float wind = 0.0;
uniform float glow = 0.0;
varying vec3 world_pos;
void vertex() {
    world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    VERTEX.x += sin(TIME * 1.8 + world_pos.x * 0.8 + world_pos.z) * wind * max(VERTEX.y, 0.0);
}
void fragment() {
    float patch = floor((sin(world_pos.x * 1.1) + sin(world_pos.z * 1.6) + sin(world_pos.x * 2.8 + world_pos.z)) * 1.4) / 4.0;
    ALBEDO = base_color.rgb * (1.0 + patch * variation);
    ROUGHNESS = 0.95;
    EMISSION = base_color.rgb * glow;
}
void light() {
    float diffuse = dot(NORMAL, LIGHT);
    float band = diffuse > 0.65 ? 1.0 : (diffuse > 0.15 ? 0.72 : 0.40);
    DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * band * ATTENUATION / 3.14159265;
}
