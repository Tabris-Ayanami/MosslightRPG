shader_type spatial;
render_mode cull_disabled, specular_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform sampler2D position_cache : filter_nearest, repeat_disable;
uniform sampler2D normal_cache : filter_nearest, repeat_disable;
uniform float frame = 0.0;
uniform int frame_count = 505;
uniform vec4 tint : source_color = vec4(1.0);
void vertex(){
	int point=int(UV2.x+.5);
	int a=clamp(int(floor(frame)),0,frame_count-1);
	int b=min(a+1,frame_count-1);
	float t=fract(frame);
	VERTEX=mix(texelFetch(position_cache,ivec2(point,a),0).xyz,texelFetch(position_cache,ivec2(point,b),0).xyz,t);
	NORMAL=normalize(mix(texelFetch(normal_cache,ivec2(point,a),0).xyz,texelFetch(normal_cache,ivec2(point,b),0).xyz,t));
}
void fragment(){
	ALBEDO=max(texture(albedo_texture,UV).rgb*tint.rgb,vec3(.035,.045,.065));
	ROUGHNESS=.9;
}
void light(){
	float n=dot(NORMAL,LIGHT);
	float shade=n>.5?1.0:(n>-.05?.78:.52);
	float shadow=mix(.60,1.0,smoothstep(.15,.8,ATTENUATION));
	DIFFUSE_LIGHT+=LIGHT_COLOR*shade*shadow*(LIGHT_IS_DIRECTIONAL?1.0:ATTENUATION)/3.14159265;
}
