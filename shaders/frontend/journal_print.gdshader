shader_type canvas_item;
render_mode unshaded;
uniform vec2 sheet_origin=vec2(120.0,79.0);
uniform vec2 canvas_size=vec2(1280.0,720.0);
float hash(vec2 p){vec3 q=fract(vec3(p.xyx)*.1031);q+=dot(q,q.yzx+33.33);return fract((q.x+q.y)*q.z);}
float noise(vec2 p){vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.0-2.0*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1)),f.x),f.y);}
void fragment(){
	vec4 src=COLOR;
	vec2 px=UV*canvas_size;
	vec2 page=px-sheet_origin;
	float fleck=hash(floor(px*1.7));
	float fibers=noise(px*vec2(.09,1.4));
	float cloud=noise(px*.011)*.55+noise(px*.039)*.30+noise(px*.15)*.15;
	float edge=min(min(page.x,1120.0-page.x),min(page.y,550.0-page.y));
	float wear=(1.0-smoothstep(0.0,52.0,edge))*.07;
	float light=dot(src.rgb,vec3(.299,.587,.114));
	float paper=smoothstep(.47,.85,light);
	vec3 color=src.rgb;
	color*=1.0+(cloud-.5)*.14+(fleck-.5)*.048+(fibers-.5)*.022;
	color-=vec3(.15,.11,.07)*wear*paper;
	// Broken pigment lies in the same fibres as the page, including text and icons.
	float tooth=smoothstep(.85,.99,fleck)*.12*(1.0-paper);
	color=mix(color,vec3(.87,.81,.68),tooth);
	COLOR=vec4(color,src.a);
}
