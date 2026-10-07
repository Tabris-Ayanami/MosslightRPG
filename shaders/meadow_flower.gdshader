shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, specular_disabled, ambient_light_disabled;
#include "reference_common.gdshaderinc"
uniform vec4 petals : source_color = vec4(.94,.88,.67,1);
uniform int flower_kind = 0;
varying vec3 wp;
varying vec3 surface_position;
varying float variation;
varying vec3 center_view;
void vertex(){
    vec3 center=MODEL_MATRIX[3].xyz;
    surface_position=center;
    variation=INSTANCE_CUSTOM.r;
    float scale=length(MODEL_MATRIX[0].xyz);
    vec3 right=normalize(vec3(INV_VIEW_MATRIX[0].x,0,INV_VIEW_MATRIX[0].z));
    vec3 bend=wind_flutter(center,.055)*(1.0-UV.y);
    wp=center+right*(VERTEX.x*scale)+vec3(0,VERTEX.y*scale,0)+bend;
    VERTEX=(VIEW_MATRIX*vec4(wp,1)).xyz;
    NORMAL=(VIEW_MATRIX*vec4(0,1,0,0)).xyz;
    center_view=(VIEW_MATRIX*vec4(center+vec3(0,.12,0),1)).xyz;
}
float diamond(vec2 p,vec2 c,vec2 s){return 1.0-step(1.0,dot(abs((p-c)/s),vec2(1)));}
void fragment(){
    vec2 p=UV;
    float stem=(1.0-step(.032,abs(p.x-.5)))*step(.3,p.y)*step(p.y,.95);
    float leaf=max(diamond(p,vec2(.35,.72),vec2(.23,.10)),diamond(p,vec2(.63,.60),vec2(.21,.09)));
    float head=0.0;
    vec2 c=vec2(.5,.29);
    if(flower_kind==1){
        head=max(diamond(p,vec2(.50,.17),vec2(.12,.12)),diamond(p,vec2(.34,.32),vec2(.17,.12)));
        head=max(head,diamond(p,vec2(.65,.46),vec2(.16,.12)));
    }else if(flower_kind==2){
        head=1.0-step(.18,length((p-c)*vec2(.85,1.15)));
    }else if(flower_kind==3){
        head=1.0-step(.125,length(p-c-vec2(0,-.065)));
        head=max(head,1.0-step(.12,length(p-c-vec2(-.09,.045))));
        head=max(head,1.0-step(.12,length(p-c-vec2(.09,.045))));
    }else{
        for(int i=0;i<5;i++){
            float a=float(i)*1.256637+variation*.7;
            head=max(head,diamond(p,c+vec2(sin(a),cos(a))*.14,vec2(.14,.11)));
        }
    }
    if(max(max(stem,leaf),head)<.5)discard;
    vec3 col=mix(vec3(.075,.18,.08),vec3(.19,.31,.11),leaf);
    if(head>.5){
        col=petals.rgb;
        if(flower_kind<3 && flower_kind!=1 && distance(p,c)<.065)col=vec3(.64,.34,.055);
    }
    ALBEDO=weather_coat(col,surface_position,.8);
    ROUGHNESS=0.0;
    LIGHT_VERTEX=center_view;
}
void light(){
    float lit=smoothstep(.15,.85,ATTENUATION)*cloud_light(wp.xz,TIME);
    DIFFUSE_LIGHT+=mix(vec3(.40,.51,.57),vec3(1,.99,.91),lit)*LIGHT_COLOR*(LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION)/3.14159265;
}
