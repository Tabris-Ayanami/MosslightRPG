shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
#include "../shaders/weather_globals.gdshaderinc"
uniform int mode = 0;
uniform vec2 origin = vec2(0.0);
uniform vec2 extent = vec2(40.0);
void vertex() { POSITION = vec4(VERTEX.xy,1.0,1.0); }
void fragment() {
    if (mode == 1) {
        // Encodes actual shared vertex wind, including the current amplitude.
        float bend=wind_flutter(vec3(30.0,7.0,105.0),.08).x;
        ALBEDO=vec3(.5+bend);
    } else if (mode == 2) {
        ALBEDO=weather_coat(vec3(.22,.46,.13),vec3(origin.x+UV.x*extent.x,2.2,origin.y+UV.y*extent.y),1.0);
    } else {
        ALBEDO=vec3(weather_coverage(origin+UV*extent),0.0);
    }
}
