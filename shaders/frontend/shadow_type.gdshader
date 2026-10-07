shader_type canvas_item;
uniform sampler2D meadow_texture : filter_linear, repeat_disable;
uniform sampler2D meadow_surface : source_color, filter_nearest, repeat_disable;
uniform bool ground_lettering = false;
uniform vec4 sunlight_ink : source_color = vec4(.98,.96,.81,1.0);
uniform vec4 shade_ink : source_color = vec4(.65,.77,.62,1.0);
void fragment(){
    vec4 glyph=COLOR;
    vec3 meadow=texture(meadow_texture,SCREEN_UV).rgb;
    float light=smoothstep(.15,.85,meadow.r);
    vec3 ink=mix(shade_ink.rgb,sunlight_ink.rgb,light);
    float alpha=glyph.a;
    if(ground_lettering) {
        vec3 ground=texture(meadow_surface,SCREEN_UV).rgb;
        float blade=clamp((meadow.r-meadow.b)/max(meadow.r,.04),0.0,1.0);
        ink=mix(mix(vec3(.56,.66,.43),vec3(.93,.93,.68),light),ground,.23);
        alpha*=1.0-blade*.76;
    }
    COLOR=vec4(ink,alpha);
}
