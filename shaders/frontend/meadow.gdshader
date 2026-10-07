shader_type spatial;
render_mode specular_disabled;
#include "../reference_common.gdshaderinc"
#include "title_breeze.gdshaderinc"
varying vec3 world;
void vertex(){world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
void fragment(){
    float patch=grass_patch(world.xz);
    float grain=field_noise(floor(world.xz*18.0)*.71);
    ALBEDO=mix(vec3(.29,.44,.14),vec3(.55,.68,.25),smoothstep(.26,.80,patch));
    float near_detail=1.0-smoothstep(18.0,60.0,length(world.xz-CAMERA_POSITION_WORLD.xz));
    ALBEDO*=1.0+(grain-.5)*.08*near_detail;
    ALBEDO*=1.0+title_breeze(world.xz)*.085*near_detail;
    float distance_fade=smoothstep(28.0,160.0,length(world.xz-CAMERA_POSITION_WORLD.xz));
    ALBEDO=mix(ALBEDO,vec3(.49,.60,.30),distance_fade);
    ROUGHNESS=1.0;
}
void light(){
    float shade=smoothstep(.2,.78,ATTENUATION);
    DIFFUSE_LIGHT+=ALBEDO*mix(vec3(.19,.33,.25),vec3(1.07,1.0,.74),shade)*LIGHT_COLOR/3.14159265;
}
