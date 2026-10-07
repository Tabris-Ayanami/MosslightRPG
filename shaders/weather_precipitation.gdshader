shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;
#include "weather_globals.gdshaderinc"
uniform bool snowflake = false;
varying vec3 wp;
varying float drop_seed;
void vertex() {
    drop_seed = fract(float(INSTANCE_ID)*.61803398875);
    if (!snowflake) {
        // Varied short streaks, with subpixel coverage instead of disappearing
        // between samples as the orthographic camera zooms out.
        float world_pixel = 2.0/(abs(PROJECTION_MATRIX[1][1])*VIEWPORT_SIZE.y);
        float width = max(length(MODEL_MATRIX[0].xyz)*.045,.0001);
        VERTEX.x *= max(1.0,world_pixel*.65/width);
        VERTEX.y *= mix(.42,1.15,drop_seed*drop_seed);
    }
    wp = (MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
}
void fragment() {
    // Rain and snow stop at the lake as well as the collision height field.
    if (wp.y < .63) discard;
    vec2 p=abs(UV-.5)*2.0;
    if (snowflake && p.x+p.y>1.35) discard;
    float edge = snowflake ? 1.0 : (1.0-smoothstep(.2,1.0,p.x))*smoothstep(0.0,.3,UV.y)*(1.0-UV.y*.45);
    ALBEDO = snowflake ? vec3(.88,.94,1.0)*max(weather_light,vec3(.13,.18,.28)) : vec3(.61,.76,.82)*max(weather_light,vec3(.21,.30,.43));
    ALPHA = COLOR.a*edge*(snowflake ? .94 : mix(.28,.64,drop_seed));
    ROUGHNESS = 0.0;
}
