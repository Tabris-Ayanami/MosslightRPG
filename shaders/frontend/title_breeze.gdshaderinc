// Shared world-space gusts: the ground's sheen and the blades travel together.
// Continuous integrated weather time keeps the breeze smooth at every frame.
float title_breeze(vec2 p) {
    vec2 direction=normalize(vec2(.86,.5));
    float across=dot(p,vec2(-direction.y,direction.x));
    float phase=dot(p,direction)*.72-weather_wind_phase*1.18;
    phase+=sin(across*.24)*.9;
    float wave=.5+.5*sin(phase);
    float envelope=.72+.28*field_noise(p*.11-direction*weather_wind_phase*.055);
    return smoothstep(.22,.94,wave)*envelope;
}
