// x = local height, yz = radial slope, w = sparse crest highlight.
// Origins remain in world space after an actor leaves the contact.
uniform int water_event_count = 0;
uniform vec4 water_events[24];
uniform vec4 water_event_shapes[24];

vec4 water_contact_waves(vec2 p, float world_pixel) {
    vec4 result=vec4(0.0);
    for (int i=0;i<24;i++) {
        if (i>=water_event_count) break;
        vec4 e=water_events[i];
        vec4 shape=water_event_shapes[i];
        vec2 delta=p-e.xy;
        if (dot(delta,delta)>9.0) continue;
        float age=e.z;
        float entry=1.0-step(.5,shape.z);
        float dash=step(3.5,shape.z);
        float radius=.12+age*mix(.72,1.05,entry);
        float r=length(delta);
        vec2 radial=delta/max(r,.001);
        float d=r-radius;
        float width=.16+age*.075;
        float envelope=exp(-d*d/(width*width));
        float fade=smoothstep(0.0,.08,age)*(1.0-smoothstep(.35,1.85,age));
        float rear=1.0-smoothstep(-.15,.65,dot(radial,shape.xy));
        float arcs=mix(1.0,rear,max(step(.5,shape.z)*step(shape.z,1.5),dash));
        float filter=exp(-pow(18.0*world_pixel*.65,2.0));
        float energy=fade*e.w*arcs*filter*smoothstep(.0,.06,r);
        float amplitude=mix(mix(.008,.016,entry),.014,dash)*energy;
        float angle=d*18.0;
        result.x+=cos(angle)*envelope*amplitude;
        float derivative=(-18.0*sin(angle)-2.0*d*cos(angle)/(width*width))*envelope*amplitude;
        result.yz+=radial*derivative;
        float crest=smoothstep(.55,.95,cos(angle))*envelope;
        result.w+=crest*energy*.16;
    }
    return vec4(result.x,clamp(result.yz,vec2(-.45),vec2(.45)),clamp(result.w,0.0,.35));
}
