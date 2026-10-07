shader_type spatial;
render_mode skip_vertex_transform,cull_disabled,specular_disabled;
#include "weather_globals.gdshaderinc"
uniform vec4 petal_color : source_color=vec4(1.0,.94,.82,1.0);
void vertex(){
    vec3 center=MODEL_MATRIX[3].xyz;
    center += tree_bend(center)+wind_flutter(center,.02);
    vec3 p=center+INV_VIEW_MATRIX[0].xyz*VERTEX.x*length(MODEL_MATRIX[0].xyz)+INV_VIEW_MATRIX[1].xyz*VERTEX.y*length(MODEL_MATRIX[1].xyz);
    VERTEX=(VIEW_MATRIX*vec4(p,1.0)).xyz;
    NORMAL=normalize((VIEW_MATRIX*vec4(0,1,0,0)).xyz);
}
void fragment(){
    vec2 p=(UV-.5)*2.0;
    float petals=0.0;
    for(int i=0;i<5;i++){
        float a=float(i)*6.2831853/5.0;
        petals=max(petals,1.0-step(.43,length(p-vec2(cos(a),sin(a))*.45)));
    }
    ALPHA=petals;
    ALPHA_SCISSOR_THRESHOLD=.5;
    ALBEDO=mix(petal_color.rgb,vec3(.66,.43,.07),1.0-step(.20,length(p)));
    ROUGHNESS=0.0;
}
