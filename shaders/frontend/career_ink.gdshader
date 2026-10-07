shader_type canvas_item;
render_mode unshaded;
uniform float growth=1.0;
uniform float erasure=0.0;
varying vec2 pen_position;
float hash(vec2 p){vec3 q=fract(vec3(p.xyx)*.1031);q+=dot(q,q.yzx+33.33);return fract((q.x+q.y)*q.z);}
void vertex(){pen_position=VERTEX;}
void fragment(){
	float grain=hash(floor(pen_position*1.8));
	float reveal=(92.0-pen_position.y)/92.0+grain*.12;
	float erased=pen_position.x/106.0+pen_position.y*.0015+grain*.17;
	COLOR.a*=smoothstep(reveal-.19,reveal+.04,growth*1.3);
	COLOR.a*=1.0-smoothstep(erased-.18,erased+.10,erasure*1.5);
}
