shader_type spatial;
render_mode ambient_light_disabled, specular_disabled;
void fragment(){ALBEDO=vec3(1.0);ROUGHNESS=1.0;}
void light(){DIFFUSE_LIGHT+=vec3(smoothstep(.15,.85,ATTENUATION));}
