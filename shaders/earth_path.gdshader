shader_type spatial;
render_mode specular_disabled, ambient_light_disabled;
#include "reference_common.gdshaderinc"

uniform vec4 earth : source_color = vec4(.55, .385, .235, 1.0);
uniform vec4 packed_earth : source_color = vec4(.67, .505, .315, 1.0);
uniform vec4 dry_grit : source_color = vec4(.73, .595, .40, 1.0);
uniform bool ribbon = true;
uniform vec2 plaza_center = vec2(0.0);
uniform float plaza_radius = 6.3;
varying vec3 wp;
varying vec3 local_position;
varying vec3 wn;

void vertex() {
    local_position = VERTEX;
    wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    wn = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
    if (CAMERA_POSITION_WORLD.y < .6 && wp.y < .62) discard;
    // Fixed world texels keep clumps attached to the ground through camera orbits.
    vec2 p = (floor(wp.xz * 12.0) + .5) / 12.0;
    float edge_noise = field_noise(p * 2.2);
    float edge = ribbon ? min(UV.x, 1.0 - UV.x) * 2.0
                        : (plaza_radius - length(local_position.xz - plaza_center)) / .65;
    float boundary = ribbon ? .07 + edge_noise * .10 : .20 + edge_noise * .60;
    if (edge < boundary) discard;

    float clods = field_noise(p * .90) * .70 + field_noise(p * 2.8) * .30;
    float centre_wear = ribbon ? 1.0 - smoothstep(.12, .78, abs(UV.x - .5) * 2.0)
                               : .52 + field_noise(p * .29) * .24;
    float packed = smoothstep(.24, .76, clods) * .62 + centre_wear * .30;
    vec3 soil = mix(earth.rgb, packed_earth.rgb, packed);
    // Short broken scuffs and small grit clusters, without a full-screen speckle.
    float crumbs = field_noise(p * 5.0);
    soil *= crumbs < .29 ? .91 : (crumbs > .73 ? 1.035 : 1.0);
    float grit = step(.81, field_noise(p * 7.3)) * step(.48, field_noise(p * 1.7));
    soil = mix(soil, dry_grit.rgb, grit * .42);
    if (ribbon) {
        float rut_offset = (field_noise(p * .72) - .5) * .10;
        float rut_distance = min(abs(UV.x - .29 - rut_offset), abs(UV.x - .72 - rut_offset));
        float rut = (1.0 - smoothstep(.015, .047, rut_distance)) * smoothstep(.30, .62, field_noise(p * 1.5));
        soil *= 1.0 - rut * .085;
    }
    ALBEDO = weather_coat(soil, wp, wn.y);
    ROUGHNESS = 1.0;
}

void light() {
    float n = dot(NORMAL, LIGHT);
    float band = wn.y > .72 ? 1.0 : (n > .55 ? 1.0 : (n > .08 ? .8 : .58));
    float lit = band * smoothstep(.25, .8, ATTENUATION) * cloud_light(wp.xz, TIME);
    // Earth keeps a warm bounce in shade; it still receives the scene's night light.
    DIFFUSE_LIGHT += mix(vec3(.34, .33, .28), vec3(1.0, .98, .87), lit)
                    * LIGHT_COLOR * (LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION) / 3.14159265;
}
