shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, specular_disabled, ambient_light_disabled;
#include "../reference_common.gdshaderinc"
#include "title_breeze.gdshaderinc"
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
varying flat float typography_pass;
void vertex() {
    typography_pass=CAMERA_VISIBLE_LAYERS==2u ? 1.0 : 0.0;
    root=MODEL_MATRIX[3].xyz;
    float sx=length(MODEL_MATRIX[0].xyz);
    float sy=length(MODEL_MATRIX[1].xyz);
    active=step(.001,sx*sy);
    float variation=hash21(root.xz*2.7);
    float distance_fade=1.0-smoothstep(32.0,70.0,length(root.xz-CAMERA_POSITION_WORLD.xz));
    active*=step(variation,distance_fade);
    if (use_path_clearance) {
        vec2 map_position=(path_world_to_map*vec4(root,1.0)).xz;
        float clearance=texture(path_clearance,(map_position-vec2(-32,-96))/128.0).r;
        active*=step(clearance,variation);
    }
    tip=1.0-UV.y;
    float height=mix(.40,.78,variation)*mix(.8,1.16,grass_patch(root.xz));
    float gust=title_breeze(root.xz);
    float flutter=sin(weather_wind_phase*2.15+dot(root.xz,vec2(.71,.39)))*.035;
    float lean=.045+gust*.29+flutter;
    vec3 bend=vec3(.86*lean,-abs(lean)*.18,.5*lean)*tip*tip;
    vec3 away=root-player_position;
    float push=(1.0-smoothstep(.2,1.15,length(away.xz)))*(1.0-smoothstep(.7,1.8,abs(away.y)));
    vec3 up=normalize(mix(vec3(0,1,0),INV_VIEW_MATRIX[1].xyz,smoothstep(.60,.96,abs(INV_VIEW_MATRIX[2].y))));
    vec3 p=root + INV_VIEW_MATRIX[0].xyz*(VERTEX.x*sx*.78) + up*(VERTEX.y*sy*height)+bend;
    // Overhead billboards lie almost parallel to the lawn. Their former -0.018
    // offset buried every blade under the receiver, hiding both wind and masks.
    p.y=max(p.y,root.y+.008);
    p.xz+=normalize(away.xz+vec2(.001))*push*tip*.32;
    p.y-=push*tip*.10;
    VERTEX=(VIEW_MATRIX*vec4(p,1.0)).xyz;
    NORMAL=(VIEW_MATRIX*vec4(0,1,0,0)).xyz;
    light_root=(VIEW_MATRIX*vec4(root+vec3(0,.04,0),1)).xyz;
    wind_light=gust*.19;
}
void fragment() {
    if(active<.5) discard;
    if(texture(leaf_texture,UV).a<.55) discard;
    float patch=grass_patch(root.xz);
    vec3 base=mix(meadow.rgb,meadow_high.rgb,smoothstep(.33,.68,patch));
    ALBEDO=weather_coat(base*mix(.98,1.13,tip*tip)+wind_light*tip*vec3(.22,.30,.1),root,1.0);
    if(typography_pass>.5) ALBEDO=vec3(1.0);
    ROUGHNESS=0.0;
    LIGHT_VERTEX=light_root;
}
void light() {
    if(typography_pass>.5) {
        // R retains the sunlight mask. B removes only leaf tips, encoding an
        // aligned occlusion mask without another viewport or a fake noise cutout.
        float light_mask=mix(.12,1.0,smoothstep(.15,.85,ATTENUATION));
        DIFFUSE_LIGHT+=vec3(light_mask,light_mask,light_mask*(1.0-pow(tip,1.7)));
    } else {
        float lit=smoothstep(.1,.85,ATTENUATION)*cloud_light(root.xz,TIME);
        DIFFUSE_LIGHT+=mix(vec3(.24,.40,.37),vec3(1.0,.99,.87),lit)*LIGHT_COLOR*(LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION)/3.14159265;
    }
}

