#include "weather_globals.gdshaderinc"
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
// Integer lattice hashing keeps adjacent cells identical at a shared corner.
// The former sin/dot hash produced visible cell discontinuities on Vulkan.
float lattice_hash(ivec2 p) {
    uint h = uint(p.x) * 374761393u + uint(p.y) * 668265263u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    return float(h & 16777215u) / 16777215.0;
}
float field_noise(vec2 p) {
    ivec2 i = ivec2(floor(p));
    vec2 f = fract(p);
    f = f*f*f*(f*(f*6.0-15.0)+10.0);
    return mix(mix(lattice_hash(i), lattice_hash(i+ivec2(1,0)), f.x), mix(lattice_hash(i+ivec2(0,1)), lattice_hash(i+ivec2(1,1)), f.x), f.y);
}
float grass_patch(vec2 p) {
    vec2 q=mat2(vec2(.8,.6),vec2(-.6,.8))*p;
    q+=vec2(field_noise(p*.19),field_noise(p*.19+vec2(17,31)))*2.2;
    return field_noise(q*.30)*.72 + field_noise(q*.95)*.22 + field_noise(q*2.7)*.06;
}
float cloud_light(vec2 p, float time) {
    float n = field_noise(p * 0.065 + weather_wind.xy * weather_wind_phase * .009);
    // Overcast skies lose distinct moving cloud bands. Surface wetness is a
    // separate stationary layer and must not look like passing cloud shadows.
    float contrast = mix(.28,.025,smoothstep(.15,.8,weather_cloud));
    return mix(1.0-contrast,1.0,smoothstep(.35,.55,n))*(1.0-weather_cloud*.14);
}
