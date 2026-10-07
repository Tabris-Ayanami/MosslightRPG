shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, specular_disabled, ambient_light_disabled;
#include "reference_common.gdshaderinc"
uniform sampler2D leaf_texture : source_color, filter_nearest;
uniform vec4 meadow : source_color = vec4(.34,.53,.27,1.0);
uniform vec4 meadow_high : source_color = vec4(.49,.66,.33,1.0);
uniform vec3 player_position = vec3(0,-1000,0);
uniform bool use_path_clearance = false;
uniform sampler2D path_clearance : filter_linear, repeat_disable;
uniform mat4 path_world_to_map = mat4(1.0);
varying vec3 root;
varying vec3 light_root;
varying float tip;
varying float wind_light;
varying float active;
void vertex() {
    root=MODEL_MATRIX[3].xyz;
    float sx=length(MODEL_MATRIX[0].xyz);
    float sy=length(MODEL_MATRIX[1].xyz);
    active=step(.001,sx*sy);
    float variation=hash21(root.xz*2.7);
    if (use_path_clearance) {
        vec2 map_position=(path_world_to_map*vec4(root,1.0)).xz;
        float clearance=texture(path_clearance,(map_position-vec2(-32,-96))/128.0).r;
        active*=step(clearance,variation);
    }
    tip=1.0-UV.y;
    float height=mix(.40,.78,variation)*mix(.8,1.16,grass_patch(root.xz));
    float gust=wind_gust(root.xz);
    vec3 bend=wind_flutter(root,.13)*tip*tip;
    vec3 away=root-player_position;
    float push=(1.0-smoothstep(.2,1.15,length(away.xz)))*(1.0-smoothstep(.7,1.8,abs(away.y)));
    vec3 p=root + INV_VIEW_MATRIX[0].xyz*(VERTEX.x*sx*.78) + vec3(0,VERTEX.y*sy*height-.018,0)+bend;
    p.xz+=normalize(away.xz+vec2(.001))*push*tip*.32;
    p.y-=push*tip*.10;
    VERTEX=(VIEW_MATRIX*vec4(p,1.0)).xyz;
    NORMAL=(VIEW_MATRIX*vec4(0,1,0,0)).xyz;
    light_root=(VIEW_MATRIX*vec4(root+vec3(0,.04,0),1)).xyz;
    wind_light=smoothstep(.1,.8,gust)*.055;
}
void fragment() {
    if(active<.5) discard;
    if(texture(leaf_texture,UV).a<.55) discard;
    float patch=grass_patch(root.xz);
    vec3 base=mix(meadow.rgb,meadow_high.rgb,smoothstep(.33,.68,patch));
    ALBEDO=weather_coat(base*mix(.98,1.13,tip*tip)+wind_light*tip*vec3(.22,.30,.1),root,1.0);
    ROUGHNESS=0.0;
    LIGHT_VERTEX=light_root;
}
void light() {
    float lit=smoothstep(.1,.85,ATTENUATION)*cloud_light(root.xz,TIME);
    DIFFUSE_LIGHT+=mix(vec3(.24,.40,.37),vec3(1.0,.99,.87),lit)*LIGHT_COLOR*(LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION)/3.14159265;
}
