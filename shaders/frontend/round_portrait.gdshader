shader_type canvas_item;
render_mode unshaded;
uniform vec3 paper : source_color=vec3(.91,.875,.78);
uniform vec3 graphite : source_color=vec3(.22,.215,.19);
varying vec4 canvas_tint;

float grain(vec2 p){return fract(sin(dot(floor(p),vec2(41.17,289.31)))*43758.5453);}
float value(vec4 c){return mix(1.0,dot(c.rgb,vec3(.299,.587,.114)),c.a);}
void vertex(){canvas_tint=COLOR;}

void fragment(){
    vec4 src=texture(TEXTURE,UV);
    // Keep facial lines at least a fraction of a screen pixel in the 72px HUD.
    // Sampling only at source resolution loses eyes when the 256px bust shrinks.
    vec2 d=max(TEXTURE_PIXEL_SIZE*1.7,fwidth(UV)*.8);
    float mid=value(src);
    float l=value(texture(TEXTURE,UV-vec2(d.x,0)));
    float r=value(texture(TEXTURE,UV+vec2(d.x,0)));
    float u=value(texture(TEXTURE,UV-vec2(0,d.y)));
    float b=value(texture(TEXTURE,UV+vec2(0,d.y)));
    float contour=smoothstep(.035,.32,length(vec2(l-r,u-b)));
    float fine=max(0.0,(l+r+u+b)*.25-mid)*2.4;
    float shade=(1.0-smoothstep(.04,.92,mid))*src.a;
    // Fixed paper coordinates: pencil strokes never crawl as the world moves.
    vec2 px=UV*144.0;
    float jitter=sin(px.y*.17)*.22+sin(px.x*.24)*.12;
    float hatch=1.0-smoothstep(.22,.60,abs(sin((px.x+px.y*.68)*1.03+jitter)));
    float cross=1.0-smoothstep(.16,.51,abs(sin((px.x-px.y*.78)*1.11+jitter)));
    float strokes=hatch*smoothstep(.12,.76,shade)*.37+cross*smoothstep(.54,.96,shade)*.23;
    float pencil=clamp(contour*.64+fine*1.05+strokes+shade*.28,0.0,.95);
    // Dense graphite preserves dark hair, pupils and lashes after downsampling.
    pencil=max(pencil,smoothstep(.68,.94,shade)*.64);
    pencil*=.80+grain(UV/TEXTURE_PIXEL_SIZE)*.20;
    vec3 sheet=paper*(.975+grain(px*2.0)*.05);
    // A restrained wash keeps clothing identities without shaded plastic faces.
    vec3 wash=mix(sheet,sheet*mix(vec3(1.0),src.rgb,.18),src.a*.42);
    vec3 sketch=mix(wash,graphite,pencil);
    float rim=1.0-smoothstep(.474,.49,length(UV-.5));
    COLOR=vec4(sketch,rim)*canvas_tint;
}
