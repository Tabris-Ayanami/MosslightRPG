shader_type spatial;
render_mode cull_disabled, specular_disabled, ambient_light_disabled;
#include "reference_common.gdshaderinc"
uniform vec4 base_color : source_color = vec4(0.6,0.65,0.6,1);
uniform sampler2D source_texture : source_color, filter_linear_mipmap;
uniform bool use_texture = false;
uniform bool foliage = false;
uniform float crown_height = 2.5;
uniform float moss = 0.0;
uniform bool roof_tiles = false;
uniform vec2 roof_axis = vec2(1.0,0.0);
varying vec3 wp;
varying vec3 surface_position;
varying vec3 wn;
void vertex() {
    wp = (MODEL_MATRIX * vec4(VERTEX,1)).xyz;
    surface_position = wp;
    vec3 bend = tree_bend(wp);
    if (foliage) {
        bend += wind_flutter(wp,.04);
        NORMAL = normalize(mix(NORMAL, normalize(VERTEX - vec3(0,crown_height,0)), 0.62));
    }
    VERTEX += inverse(mat3(MODEL_MATRIX))*bend;
    wp += bend;
    wn = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
    if (CAMERA_POSITION_WORLD.y < 0.6 && wp.y < 0.62) discard;
    vec4 tex = texture(source_texture, UV, 1.4);
    if (use_texture && tex.a < 0.24) discard;
    vec3 col = base_color.rgb;
    if (use_texture) col *= mix(vec3(0.94), vec3(1.06), tex.rgb);
    float patch = field_noise(floor(wp.xz * 4.0) / 4.0 * 0.85);
    col *= mix(0.96, 1.04, step(0.55, patch));
    if (!foliage && wn.y > 0.65) col = mix(col, vec3(0.18,0.28,0.11), moss * step(0.57, patch));
    if (roof_tiles && wn.y > 0.25) {
        // Material detail stays attached to the house. It does not depend on
        // subpixel self-shadows between the imported shallow shingle surfaces.
        vec2 perpendicular_axis = vec2(-roof_axis.y,roof_axis.x);
        bool across_x = abs(dot(wn.xz,roof_axis)) > abs(dot(wn.xz,perpendicular_axis));
        vec2 across = across_x ? roof_axis : perpendicular_axis;
        vec2 along = across_x ? perpendicular_axis : roof_axis;
        vec2 local_xz = wp.xz-NODE_POSITION_WORLD.xz;
        float row = dot(local_xz,across)/.34;
        float column = dot(local_xz,along)/.62 + mod(floor(row),2.0)*.5;
        vec2 tile = floor(vec2(column,row));
        float v = fract(row + .025*sin(column*6.2831853));
        float footprint = max(fwidth(row),.008);
        float seam = 1.0-smoothstep(.045-footprint*.5,.045+footprint*.5,min(v,1.0-v));
        float join_width = max(fwidth(column),.008);
        float join = 1.0-smoothstep(.025-join_width*.5,.025+join_width*.5,min(fract(column),1.0-fract(column)));
        join *= smoothstep(.22,.32,v)*(1.0-smoothstep(.70,.80,v));
        float variation = lattice_hash(ivec2(tile));
        col *= .97 + variation*.06;
        col *= 1.0-seam*.17-join*.07;
    }
    ALBEDO = weather_coat(col,surface_position,wn.y);
    ROUGHNESS = foliage ? 0.0 : 0.94;
}
void light() {
    float n = dot(NORMAL, LIGHT);
    // Back-facing roofs receive the constant fill below, not direct sunlight.
    // A positive minimum direct term exposed the shadow-map's grazing-angle acne.
    float band = n > 0.6 ? 1.0 : (n > 0.12 ? (foliage ? 0.70 : 0.79) : (foliage ? 0.40 : 0.55) * smoothstep(0.0, 0.12, n));
    // Broad canopy shading avoids self-shadow speckle between tiny leaf cards.
    float shadow = foliage ? 1.0 : smoothstep(0.25, 0.8, ATTENUATION);
    float lit = band * shadow * cloud_light(wp.xz, TIME);
    DIFFUSE_LIGHT += mix(vec3(0.24,0.37,0.47), vec3(1.0,0.99,0.91), lit) * LIGHT_COLOR * (LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION) / 3.14159265;
}
