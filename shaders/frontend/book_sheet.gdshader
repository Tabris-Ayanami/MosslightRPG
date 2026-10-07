shader_type canvas_item;
render_mode unshaded;
uniform sampler2D front_texture: filter_linear, repeat_disable;
uniform sampler2D back_texture: filter_linear, repeat_disable;
uniform vec4 front_region;
uniform vec4 back_region;
uniform vec2 canvas_size=vec2(1280,720);
uniform vec2 sheet_origin=vec2(120,79);
uniform bool mirror_front=false;
uniform bool mirror_back=true;
uniform float opacity=1.0;
varying vec3 sheet_data;
void vertex(){sheet_data=COLOR.rgb;}
float hash(vec2 p){vec3 q=fract(vec3(p.xyx)*.1031);q+=dot(q,q.yzx+33.33);return fract((q.x+q.y)*q.z);}
float noise(vec2 p){vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.0-2.0*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1)),f.x),f.y);}
void fragment(){
	bool rear=sheet_data.g>.5;
	vec2 uv=UV;
	if (rear ? mirror_back : mirror_front) uv.x=1.0-uv.x;
	vec4 region=rear ? back_region : front_region;
	uv=region.xy+uv*region.zw;
	vec4 src=rear ? texture(back_texture,uv) : texture(front_texture,uv);
	// Ink, portrait and paper grain share material coordinates on both sides.
	vec2 px=uv*canvas_size;
	vec2 page=px-sheet_origin;
	float fleck=hash(floor(px*1.7));
	float fibers=noise(px*vec2(.09,1.4));
	float cloud=noise(px*.011)*.55+noise(px*.039)*.30+noise(px*.15)*.15;
	float edge=min(min(page.x,1120.0-page.x),min(page.y,550.0-page.y));
	float wear=(1.0-smoothstep(0.0,52.0,edge))*.07;
	float paper=smoothstep(.47,.85,dot(src.rgb,vec3(.299,.587,.114)));
	vec3 color=src.rgb*(1.0+(cloud-.5)*.14+(fleck-.5)*.048+(fibers-.5)*.022);
	color-=vec3(.15,.11,.07)*wear*paper;
	color=mix(color,vec3(.87,.81,.68),smoothstep(.85,.99,fleck)*.12*(1.0-paper));
	COLOR=vec4(color*sheet_data.r,src.a*opacity);
}
