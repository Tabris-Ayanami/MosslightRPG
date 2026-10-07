shader_type spatial;
render_mode specular_disabled;
#include "weather_globals.gdshaderinc"
varying vec3 wp;
void vertex(){
    wp=(MODEL_MATRIX*vec4(VERTEX,1)).xyz;
    vec3 bend=tree_bend(wp);
    VERTEX+=inverse(mat3(MODEL_MATRIX))*bend;
    wp+=bend;
}
void fragment(){
    float row=floor(wp.y*4.2);
    float n=fract(sin(row*91.7+floor(wp.x*3.0+wp.z*2.0)*17.1)*438.15);
    float mark=step(.63,n)*step(.81,fract(wp.y*4.2+sin(wp.x*5.0+wp.z*7.0)*.18));
    ALBEDO=mix(vec3(.62,.62,.49),vec3(.10,.12,.10),mark*.86);
    ROUGHNESS=.9;
}
