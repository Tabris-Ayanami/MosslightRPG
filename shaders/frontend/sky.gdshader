shader_type sky;
render_mode disable_fog;
void sky(){
	float altitude=max(EYEDIR.y,0.0);
	vec3 blue=mix(vec3(.32,.59,.77),vec3(.04,.21,.46),pow(altitude,.48));
	float sunlight=pow(max(dot(EYEDIR,normalize(vec3(-.6,.6,-.5))),0.0),22.0);
	COLOR=blue+vec3(.07,.045,.02)*sunlight;
}
