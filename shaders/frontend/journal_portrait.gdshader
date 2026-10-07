shader_type canvas_item;
render_mode unshaded;
uniform vec3 ink : source_color=vec3(.28,.25,.20);
float luminance(vec4 c){return dot(c.rgb,vec3(.299,.587,.114));}
float grain(vec2 p){return fract(sin(dot(floor(p),vec2(41.17,289.31)))*43758.5453);}
void fragment(){
	vec4 src=texture(TEXTURE,UV);
	vec2 d=TEXTURE_PIXEL_SIZE*1.4;
	vec4 l=texture(TEXTURE,UV-vec2(d.x,0));
	vec4 r=texture(TEXTURE,UV+vec2(d.x,0));
	vec4 u=texture(TEXTURE,UV-vec2(0,d.y));
	vec4 b=texture(TEXTURE,UV+vec2(0,d.y));
	float outline=length(vec2(luminance(l)-luminance(r),luminance(u)-luminance(b)));
	float silhouette=abs(l.a-r.a)+abs(u.a-b.a);
	float shade=1.0-smoothstep(.08,.87,luminance(src));
	vec2 px=UV/TEXTURE_PIXEL_SIZE;
	float h1=1.0-smoothstep(.12,.45,abs(sin((px.x+px.y*.62)*.55+sin(px.y*.09)*.22)));
	float h2=1.0-smoothstep(.10,.30,abs(sin((px.x-px.y*.83)*.58)));
	float strokes=h1*smoothstep(.12,.68,shade)*.37+h2*smoothstep(.64,.98,shade)*.22;
	float alpha=clamp(outline*2.5+silhouette*.64+shade*.11+strokes,0.0,.88)*src.a;
	alpha*=.76+grain(px)*.24;
	COLOR=vec4(ink,alpha)*vec4(1,1,1,COLOR.a);
}
