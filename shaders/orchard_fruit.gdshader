shader_type spatial;
render_mode cull_disabled, specular_disabled, ambient_light_disabled;
#include "weather_globals.gdshaderinc"
uniform vec4 red : source_color = vec4(.78,.015,.012,1.0);
uniform vec4 red_shadow : source_color = vec4(.43,.007,.012,1.0);
uniform vec4 red_light : source_color = vec4(.98,.055,.025,1.0);
void vertex() {
    vec3 wp=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
    VERTEX+=inverse(mat3(MODEL_MATRIX))*tree_bend(wp);
}
void fragment() {
    ALBEDO=vec3(1.0);
    ROUGHNESS=0.0;
}
void light() {
    float n=dot(NORMAL,LIGHT);
    vec3 color=n>.78 ? red_light.rgb : (n>-.10 ? red.rgb : red_shadow.rgb);
    DIFFUSE_LIGHT+=color*LIGHT_COLOR*(LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION)/3.14159265;
}
