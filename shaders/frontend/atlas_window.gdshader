shader_type canvas_item;
render_mode unshaded;
uniform sampler2D atlas: filter_linear_mipmap, repeat_disable;
uniform vec2 map_origin=vec2(-32,-72);
uniform vec2 map_size=vec2(106,101);
uniform vec2 focus=vec2(0,0);
uniform vec2 extent=vec2(44,44);
uniform bool circular=true;
uniform bool aged_parchment=false;
float hash(vec2 p){vec3 q=fract(vec3(p.xyx)*.1031);q+=dot(q,q.yzx+33.33);return fract((q.x+q.y)*q.z);}
float noise(vec2 p){vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.-2.*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1)),f.x),f.y);}
void fragment(){
 vec2 where=focus+(UV-.5)*extent;
 vec2 uv=(where-map_origin)/map_size;
 vec2 px=uv*1024.; float n=noise(px*.023)*.6+noise(px*.11)*.4;
 vec3 base=mix(vec3(.81,.83,.72),vec3(.66,.77,.70),.4+n*.3);
 base*=.985+(hash(floor(px*1.5))-.5)*.10+(noise(px*.8)-.5)*.07;
 vec4 color=texture(atlas,clamp(uv,vec2(.002),vec2(.998)));
 float inside=step(0.,uv.x)*step(uv.x,1.)*step(0.,uv.y)*step(uv.y,1.);
 color.rgb=mix(base,color.rgb,inside);
 if(aged_parchment){
  float luma=dot(color.rgb,vec3(.299,.587,.114));
  vec3 sepia=mix(vec3(.28,.21,.13),vec3(.93,.86,.70),smoothstep(.20,.82,luma));
  color.rgb=mix(sepia,color.rgb*.94,.13);
  color.rgb+=(noise(UV*vec2(49.,28.))-.5)*.025;
 }
 float edge=min(min(UV.x,1.-UV.x),min(UV.y,1.-UV.y));
 color.a=circular ? 1.-smoothstep(.491,.50,length(UV-.5)) : smoothstep(.0,.04,edge+(noise(px*.17)-.5)*.016);
 COLOR=color;
}
