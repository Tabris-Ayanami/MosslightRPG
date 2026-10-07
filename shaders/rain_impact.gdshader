shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;
#include "weather_globals.gdshaderinc"
varying float age;
varying float seed;
varying vec3 wp;
void vertex() {
    age = INSTANCE_CUSTOM.y;
    seed = fract(float(INSTANCE_ID)*.61803398875);
    // Ignore the parent drop's orientation: impacts lie on the world surface.
    float scale = length(MODEL_MATRIX[0].xyz);
    wp = MODEL_MATRIX[3].xyz+vec3(VERTEX.x*scale,.035,VERTEX.z*scale);
    VERTEX = (inverse(MODEL_MATRIX)*vec4(wp,1.0)).xyz;
}
void fragment() {
    if (wp.y < .67 || weather_rain < .001) discard;
    vec2 p = (UV-.5)*2.0;
    float radius = mix(.14,.83,age);
    float distance_to_ring = abs(length(p)-radius);
    float aa = max(fwidth(distance_to_ring)*.7,.04);
    float ring = 1.0-smoothstep(.018,.018+aa,distance_to_ring);
    // A few broken arcs read as a splash, rather than a field of perfect hoops.
    float arcs = smoothstep(-.3,.3,sin(atan(p.y,p.x)*3.0+seed*6.283));
    float fade = smoothstep(0.0,.12,age)*(1.0-smoothstep(.25,1.0,age));
    float center = (1.0-smoothstep(.08,.22,length(p)))*(1.0-smoothstep(.08,.3,age));
    ALBEDO = vec3(.55,.73,.76)*max(weather_light,vec3(.22,.30,.42));
    ALPHA = max(ring*arcs*fade*.46,center*.28);
    ROUGHNESS = 0.0;
}
