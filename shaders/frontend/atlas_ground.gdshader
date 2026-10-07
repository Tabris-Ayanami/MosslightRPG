shader_type canvas_item;
render_mode unshaded;
uniform sampler2D elevation: filter_linear, repeat_disable;
float hash(vec2 p){vec3 q=fract(vec3(p.xyx)*.1031);q+=dot(q,q.yzx+33.33);return fract((q.x+q.y)*q.z);}
float noise(vec2 p){vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.-2.*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1)),f.x),f.y);}
void fragment(){
 vec2 px=UV*1024.; float n=noise(px*.023)*.6+noise(px*.11)*.4;
 float h=texture(elevation,UV).r*10.-3.;
 float land=smoothstep(.50,.72,h);
 vec3 water=mix(vec3(.81,.83,.72),vec3(.66,.77,.70),.4+n*.3);
 vec3 grass=mix(vec3(.78,.79,.60),vec3(.58,.68,.47),n*.7+smoothstep(2.1,4.0,h)*.30);
 vec3 col=mix(water,grass,land);
 float shore=1.-smoothstep(.03,.15,abs(h-.60));
 col=mix(col,vec3(.44,.48,.34),shore*.52);
 col=mix(col,vec3(.89,.85,.68),(1.-smoothstep(.10,.58,abs(h-.72)))*.22);
 float coast_hatch=step(.76,fract((px.x+px.y*.65)*.11))*(1.-smoothstep(.22,1.12,abs(h-.60)))*(1.-land);
 col-=coast_hatch*.10;
 float contour=(1.-smoothstep(.015,.045,abs(fract((h+2.)*.8)-.5)))*smoothstep(2.4,3.4,h);
 col-=contour*.085;
 float hatch=step(.90,fract((px.x+px.y*.55)*.14))*smoothstep(.0,1.,n)*.034;
 col-=hatch;
 col*=.985+(hash(floor(px*1.5))-.5)*.10+(noise(px*.8)-.5)*.07;
 COLOR=vec4(col,1.);
}
