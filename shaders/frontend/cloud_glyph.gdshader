shader_type canvas_item;
uniform float formation=1.0;
uniform float seed=0.0;
uniform float clock=0.0;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float noise(vec2 p){vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.0-2.0*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+1.0),f.x),f.y);}
void fragment(){
	vec4 glyph=texture(TEXTURE,UV)*COLOR;
	vec2 p=FRAGCOORD.xy*.065+vec2(seed,clock*.12);
	float n=noise(p)*.7+noise(p*2.8)*.3;
	float wisps=smoothstep(n-.24,n+.20,formation*1.5-.25);
	vec3 lit=mix(vec3(.76,.89,.97),vec3(1.0,.995,.96),smoothstep(.13,.72,n));
	COLOR=vec4(glyph.rgb*lit,glyph.a*wisps);
}
