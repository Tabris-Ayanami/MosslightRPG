global uniform float weather_clock;
global uniform float weather_wind_phase;
global uniform float weather_wetness;
global uniform float weather_surface_scale;
// Linear data, not sRGB colour: R/G are independently staggered arrival times.
global uniform sampler2D weather_surface_arrival : filter_linear, repeat_enable;
global uniform vec4 weather_wind;
global uniform float weather_rain;
global uniform float weather_snow;
global uniform float weather_cloud;
global uniform vec3 weather_light;
// xyz = tree root in world space; w enables whole-tree bending.
instance uniform vec4 weather_tree = vec4(0.0);

float wind_gust(vec2 p) {
    float t = weather_wind_phase;
    float along = dot(p, weather_wind.xy);
    return .38 + sin(t*1.4-along*.24)*.43 + sin(t*2.7-along*.73)*.19;
}
vec3 wind_flutter(vec3 p, float flexibility) {
    float g = wind_gust(p.xz)*weather_wind.z*flexibility;
    return vec3(weather_wind.x*g, -abs(g)*.08, weather_wind.y*g);
}
vec3 tree_bend(vec3 p) {
    float height = clamp(p.y-weather_tree.y, 0.0, 15.0);
    float bend = height*height*.0018*weather_tree.w;
    return wind_flutter(vec3(weather_tree.x, p.y, weather_tree.z), bend);
}
vec2 weather_coverage(vec2 p) {
    vec2 uv = p/(128.0*weather_surface_scale);
    vec2 arrival = texture(weather_surface_arrival,uv).rg;
    // A finer stationary layer breaks the front's outline into small irregular
    // edges. Narrow snow fronts keep the pixel scene from looking airbrushed.
    vec2 detail = texture(weather_surface_arrival,uv*19.0+vec2(.31,.67)).rg;
    arrival = clamp(arrival+(detail-vec2(.4))*.075,vec2(.015),vec2(.85));
    // At zero, every patch is dry; at one, every patch is fully covered.
    // Fixed world/rest positions make the fronts independent of camera and wind.
    return smoothstep(arrival,arrival+vec2(.095,.065),vec2(weather_wetness,weather_snow));
}
vec3 weather_coat(vec3 base, vec3 p, float up) {
    float above_water = smoothstep(.65,.85,p.y);
    vec2 coverage = weather_coverage(p.xz);
    float wet = weather_wetness*.12+coverage.r*.88;
    base *= 1.0-wet*.42*above_water;
    float snow = smoothstep(.20,.70,up)*coverage.g;
    return mix(base,vec3(.77,.84,.89),snow*above_water);
}
