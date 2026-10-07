shader_type spatial;
render_mode specular_disabled, ambient_light_disabled;
#include "reference_common.gdshaderinc"
#include "water_flow.gdshaderinc"
uniform vec4 meadow : source_color = vec4(.34,.53,.27,1.0);
uniform vec4 meadow_high : source_color = vec4(.49,.66,.33,1.0);
uniform vec4 cliff : source_color = vec4(0.39, 0.48, 0.46, 1);
uniform vec4 bank_soil : source_color = vec4(.49,.47,.35,1);
uniform vec4 sand : source_color = vec4(.63,.65,.55,1);
uniform vec4 riverbed : source_color = vec4(.36,.47,.52,1);
uniform vec4 bed_sand : source_color = vec4(.63,.68,.66,1);
varying vec3 wp;
varying vec3 wn;
vec3 bed_detail(vec2 at) {
    // A continuous bed of angular pebbles. Sparse stones over large grey sand
    // patches made clear water look like alternating cloudy/transparent pools.
    vec2 q=mat2(vec2(.8,.6),vec2(-.6,.8))*at*1.45;
    ivec2 cell=ivec2(floor(q));
    float nearest=10.0;
    float second=10.0;
    float identity=0.0;
    vec2 stone_local=vec2(0);
    for (int y=-1;y<=1;y++) {
        for (int x=-1;x<=1;x++) {
            ivec2 c=cell+ivec2(x,y);
            float h=lattice_hash(c);
            vec2 center=vec2(c)+.23+vec2(h,lattice_hash(c+ivec2(197,79)))*.54;
            float angle=(h-.5)*1.1;
            vec2 local=mat2(vec2(cos(angle),sin(angle)),vec2(-sin(angle),cos(angle)))*(q-center);
            vec2 d=local/vec2(.40+h*.10,.34+h*.09);
            // Broad bevelled stones give refraction a readable contour.
            float distance_to_stone=max(abs(d.x)*.88+abs(d.y)*.18,abs(d.y)*.92+abs(d.x)*.16);
            if (distance_to_stone<nearest) {
                second=nearest;
                nearest=distance_to_stone;
                identity=h;
                stone_local=d;
            } else if (distance_to_stone<second) {
                second=distance_to_stone;
            }
        }
    }
    float gap=second-nearest;
    float aa=max(fwidth(gap)*.40,.018);
    float stone_mask=smoothstep(.035,.065+aa,gap);
    float bevel=smoothstep(.07+aa,.24+aa,gap);
    vec3 stone=riverbed.rgb*mix(.80,1.34,identity);
    stone*=mix(.82,1.08,smoothstep(-.12,.16,stone_local.y-stone_local.x*.55));
    stone*=mix(.70,1.0,bevel);
    vec3 joints=riverbed.rgb*.32+bed_sand.rgb*.025;
    return mix(joints,stone,stone_mask);
}
void vertex() {
    wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    wn = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
    if (CAMERA_POSITION_WORLD.y < 0.6 && wp.y < 0.62) discard;
    float patch = grass_patch(wp.xz);
    vec3 grass = mix(meadow.rgb, meadow_high.rgb, smoothstep(.33,.68,patch));
    float rock_patch=field_noise(wp.xz*.65+wp.y*.27);
    vec3 stone=mix(bank_soil.rgb,cliff.rgb,smoothstep(.22,.80,rock_patch));
    float grassy_slope=smoothstep(.48,.86,wn.y)*smoothstep(.45,1.35,wp.y);
    vec3 shore=mix(bank_soil.rgb,sand.rgb,smoothstep(.18,.72,patch));
    vec3 land=mix(stone,grass,grassy_slope);
    land=mix(shore,land,smoothstep(.55,1.25,wp.y));
    // Continuous stone detail and restrained caustics show through the water.
    float wet=1.0-smoothstep(.48,.65,wp.y);
    float caustic=water_bed_caustic(wp.xz)*wet*.020;
    vec3 bed=land;
    if (wet>.001) bed=bed_detail(wp.xz);
    ALBEDO=weather_coat(mix(land,bed,wet),wp,wn.y)+caustic*vec3(.75,.94,.86);
    ROUGHNESS = 0.94;
}
void light() {
    float n = dot(NORMAL, LIGHT);
    float band = wn.y > .72 ? 1.0 : (n > 0.55 ? 1.0 : (n > 0.08 ? 0.8 : 0.58));
    float lit = band * smoothstep(0.25, 0.8, ATTENUATION) * cloud_light(wp.xz, TIME);
    DIFFUSE_LIGHT += mix(vec3(0.24, 0.38, 0.45), vec3(1.0, 0.99, 0.87), lit) * LIGHT_COLOR * (LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION) / 3.14159265;
}
