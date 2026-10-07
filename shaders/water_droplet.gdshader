shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
#include "weather_globals.gdshaderinc"
varying float life;
void vertex() {
    life=INSTANCE_CUSTOM.x;
    vec3 center=MODEL_MATRIX[3].xyz;
    float size=length(MODEL_MATRIX[0].xyz);
    vec3 point=center+(INV_VIEW_MATRIX[0].xyz*VERTEX.x+INV_VIEW_MATRIX[1].xyz*VERTEX.y)*size;
    VERTEX=(inverse(MODEL_MATRIX)*vec4(point,1.0)).xyz;
}
void fragment() {
    vec2 p=(UV-.5)*2.0;
    if (dot(p,p)>mix(1.0,.20,smoothstep(.3,1.0,life))) discard;
    ALBEDO=vec3(.62,.83,.81)*max(weather_light,vec3(.10,.15,.23));
    ROUGHNESS=0.0;
}
