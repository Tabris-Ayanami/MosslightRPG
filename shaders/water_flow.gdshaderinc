// x = height, yz = its world-space derivatives. Long waves are shared with
// scripts/water_surface.gd; small waves are filtered at the pixel footprint.
vec3 water_wave(vec2 p, vec2 direction, float amplitude, float frequency, float speed, float phase, float footprint) {
    direction=normalize(direction);
    float angle=dot(p,direction)*frequency-weather_clock*speed+phase;
    float amplitude_filtered=amplitude*exp(-pow(frequency*footprint*.65,2.0));
    return vec3(sin(angle)*amplitude_filtered,direction*cos(angle)*amplitude_filtered*frequency);
}

vec3 water_long_waves(vec2 p) {
    vec3 wave=water_wave(p,vec2(.8,.3),.030,.72,.62,0.0,0.0);
    wave+=water_wave(p,vec2(-.4,.9),.017,1.05,.83,1.3,0.0);
    wave+=water_wave(p,vec2(.6,-.7),.010,1.37,1.04,2.6,0.0);
    return wave*(1.0+(weather_wind.z-1.0)*.035);
}

vec3 water_flow_field(vec2 p, float footprint) {
    vec3 wave=water_long_waves(p);
    vec3 detail=water_wave(p,vec2(.31,.95),.018,4.3,1.17,.4,footprint);
    detail+=water_wave(p,vec2(-.85,.53),.012,6.7,1.63,2.1,footprint);
    detail+=water_wave(p,vec2(.76,-.65),.006,10.2,1.94,4.0,footprint);
    return wave+detail*(1.0+(weather_wind.z-1.0)*.045);
}

float water_crest_marker(vec2 p, float footprint) {
    // Sparse moving crests follow the first detail wave, never a spawned grid.
    float angle=dot(p,normalize(vec2(.31,.95)))*4.3-weather_clock*1.17+.4;
    float distance_to_crest=abs(fract(angle/6.2831853+.25)-.5)*6.2831853;
    float aa=max(fwidth(angle)*.65,.08);
    float crest=1.0-smoothstep(.12,.12+aa,distance_to_crest);
    float patch=smoothstep(.55,.82,field_noise(p*.55));
    return crest*patch*exp(-pow(4.3*footprint*.8,2.0));
}

float water_bed_caustic(vec2 p) {
    // Irregular, softly focused patches rather than an orthogonal white grid.
    vec2 q=p*.85+water_flow_field(p,0.0).yz*1.25;
    ivec2 cell=ivec2(floor(q));
    float first=10.0;
    float second=10.0;
    for (int y=-1;y<=1;y++) {
        for (int x=-1;x<=1;x++) {
            ivec2 c=cell+ivec2(x,y);
            float seed=lattice_hash(c);
            vec2 center=vec2(c)+.18+vec2(seed,lattice_hash(c+ivec2(83,117)))*.64;
            center+=sin(vec2(weather_clock*.31,weather_clock*.27)+vec2(seed*19.0,seed*31.0))*.10;
            float distance_to_center=length(q-center);
            if (distance_to_center<first) {
                second=first;
                first=distance_to_center;
            } else if (distance_to_center<second) {
                second=distance_to_center;
            }
        }
    }
    float edge=second-first;
    float aa=max(fwidth(edge)*.8,.035);
    float line=1.0-smoothstep(.04,.085+aa,edge);
    float patch=smoothstep(.46,.76,field_noise(p*.27+water_long_waves(p).yz*.4));
    return line*patch;
}
