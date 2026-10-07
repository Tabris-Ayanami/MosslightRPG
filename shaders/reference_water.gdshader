shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;
#include "reference_common.gdshaderinc"
#include "water_flow.gdshaderinc"
#include "water_interactions.gdshaderinc"
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D reflection_tex : source_color, filter_nearest, repeat_disable;
uniform sampler2D surface_normals : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_reflection = false;
uniform mat4 reflection_vp;
uniform vec4 water_tint : source_color = vec4(.38,.57,.58,1);
uniform vec3 absorption = vec3(.012,.006,.004);
uniform float scattering_strength : hint_range(0.0,1.0) = 0.0;
uniform float reflection_strength : hint_range(0.0,2.0) = 1.1;
uniform float refraction_strength : hint_range(0.0,3.0) = 2.4;
uniform float reflection_distortion : hint_range(0.0,3.0) = .90;
uniform float ripple_strength : hint_range(0.0,1.0) = .62;
uniform float shore_foam_strength : hint_range(0.0,1.0) = .035;
uniform float sun_glint_strength : hint_range(0.0,1.0) = .12;
uniform vec4 foam : source_color = vec4(.90,.94,.90,1);
uniform vec3 sun_direction = vec3(.3,.8,.5);
varying vec3 wp;
void vertex() {
    vec3 world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
    VERTEX.y+=water_long_waves(world.xz).x/max(length(MODEL_MATRIX[1].xyz),.001);
    wp=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
}
vec4 rain_waves(vec2 p, float world_pixel) {
    vec2 grid=p/1.12;
    ivec2 cell=ivec2(floor(grid));
    float seed=lattice_hash(cell);
    float age=fract(weather_clock*mix(1.1,1.55,seed)+seed*17.0);
    vec2 center=vec2(.5)+(vec2(seed,lattice_hash(cell+ivec2(137,89)))-.5)*.35;
    float radius=mix(.025,.24,age);
    vec2 delta=(fract(grid)-center)*1.12;
    float r=length(delta);
    float signed_distance=r-radius*1.12;
    float distance_to_ring=abs(signed_distance);
    float aa=max(fwidth(distance_to_ring)*.7,.005);
    float ring=1.0-smoothstep(.009,.009+aa,distance_to_ring);
    float fade=smoothstep(0.0,.12,age)*(1.0-smoothstep(.20,1.0,age));
    float energy=fade*step(seed,weather_rain*.40)*smoothstep(world_pixel*.3,world_pixel*1.3,radius*1.12);
    float envelope=exp(-signed_distance*signed_distance/.0036);
    float angle=signed_distance*28.0;
    float amplitude=.005*energy*exp(-pow(28.0*world_pixel*.65,2.0));
    float height=cos(angle)*envelope*amplitude;
    float derivative=(-28.0*sin(angle)-signed_distance/.0018*cos(angle))*envelope*amplitude;
    return vec4(height,delta/max(r,.001)*derivative,ring*energy*.12);
}

vec4 continuous_reflection(vec2 uv) {
    // Interpolate premultiplied samples so empty sky never adds a grey fringe.
    vec2 pixel=1.0/vec2(textureSize(reflection_tex,0));
    vec2 texel=uv/pixel-.5;
    vec2 origin=(floor(texel)+.5)*pixel;
    vec2 blend=fract(texel);
    vec2 lo=pixel*.5;
    vec2 hi=1.0-lo;
    vec4 a=texture(reflection_tex,clamp(origin,lo,hi));
    vec4 b=texture(reflection_tex,clamp(origin+vec2(pixel.x,0),lo,hi));
    vec4 c=texture(reflection_tex,clamp(origin+vec2(0,pixel.y),lo,hi));
    vec4 d=texture(reflection_tex,clamp(origin+pixel,lo,hi));
    a.rgb*=a.a;
    b.rgb*=b.a;
    c.rgb*=c.a;
    d.rgb*=d.a;
    vec4 reflected=mix(mix(a,b,blend.x),mix(c,d,blend.x),blend.y);
    reflected.rgb/=max(reflected.a,.0001);
    return reflected;
}

vec2 projected_water_offset(vec3 offset, vec3 surface_view, mat4 view_matrix, mat4 projection) {
    vec4 start=projection*vec4(surface_view,1.0);
    vec4 end=projection*vec4(surface_view+(view_matrix*vec4(offset,0.0)).xyz,1.0);
    return (end.xy/end.w-start.xy/start.w)*.5;
}
vec3 safe_bed_sample(vec2 uv, vec3 fallback, float surface_y, float surface_z, mat4 inv_projection, mat4 inv_view) {
    float depth=texture(depth_tex,uv).r;
    vec4 view=inv_projection*vec4(uv*2.0-1.0,depth,1.0);
    view.xyz/=view.w;
    vec3 world=(inv_view*vec4(view.xyz,1.0)).xyz;
    if (world.y>surface_y+.025 || view.z>surface_z+.025) return fallback;
    return texture(screen_tex,uv).rgb;
}
vec3 clear_refraction(vec2 uv, vec2 pixel, vec3 fallback, float surface_y, float surface_z, mat4 inv_projection, mat4 inv_view) {
    // Each interpolation tap rejects the foreground independently. Ordinary
    // bilinear screen sampling pulls banks and bridge posts into the lake.
    vec2 texel=uv/pixel-.5;
    vec2 origin=(floor(texel)+.5)*pixel;
    vec2 blend=fract(texel);
    vec2 lo=pixel*.5;
    vec2 hi=1.0-lo;
    vec3 a=safe_bed_sample(clamp(origin,lo,hi),fallback,surface_y,surface_z,inv_projection,inv_view);
    vec3 b=safe_bed_sample(clamp(origin+vec2(pixel.x,0),lo,hi),fallback,surface_y,surface_z,inv_projection,inv_view);
    vec3 c=safe_bed_sample(clamp(origin+vec2(0,pixel.y),lo,hi),fallback,surface_y,surface_z,inv_projection,inv_view);
    vec3 d=safe_bed_sample(clamp(origin+pixel,lo,hi),fallback,surface_y,surface_z,inv_projection,inv_view);
    return mix(mix(a,b,blend.x),mix(c,d,blend.x),blend.y);
}
void fragment() {
    vec2 p = wp.xz;
    vec2 pixel = 1.0 / VIEWPORT_SIZE;
    float world_pixel=2.0/(abs(PROJECTION_MATRIX[1][1])*VIEWPORT_SIZE.y);
    float d = texture(depth_tex, SCREEN_UV).r;
    vec4 bed_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV*2.0-1.0,d,1.0);
    bed_view.xyz /= bed_view.w;
    vec3 bed_world = (INV_VIEW_MATRIX*vec4(bed_view.xyz,1.0)).xyz;
    float water_depth = max(0.0,wp.y-bed_world.y);
    // Reject foreground samples: refracting a bank/building into the water
    // otherwise gives the impression of a cut-out or transparent structure.
    if (bed_world.y > wp.y+.025 || -bed_view.z < -VERTEX.z-.025) discard;
    // The surface gradient bends the bed, reflection and light together.
    // Fine detail is filtered continuously as it becomes smaller than a pixel.
    float flow=weather_wind_phase;
    vec3 a=texture(surface_normals,p*.095+vec2(flow*.016,-flow*.009)).xyz*2.0-1.0;
    vec3 b=texture(surface_normals,p.yx*.137+vec2(-flow*.011,flow*.014)).xyz*2.0-1.0;
    vec4 contacts=water_contact_waves(p,world_pixel);
    vec4 rain=weather_rain>.001 ? rain_waves(p,world_pixel) : vec4(0.0);
    vec3 broad=water_long_waves(p);
    vec3 field=broad+(water_flow_field(p,world_pixel)-broad)*ripple_strength;
    float detail_filter=1.0-smoothstep(.08,.22,world_pixel);
    vec2 slope=field.yz+(a.xy*.65+b.yx*.35)*.018*detail_filter+contacts.yz+rain.yz;
    vec3 surface_world_normal=normalize(vec3(-slope.x,1.0,-slope.y));
    vec3 surface_view_normal=normalize((VIEW_MATRIX*vec4(surface_world_normal,0.0)).xyz);
    float border = smoothstep(0.0,6.0,min(min(SCREEN_UV.x,1.0-SCREEN_UV.x)*VIEWPORT_SIZE.x,min(SCREEN_UV.y,1.0-SCREEN_UV.y)*VIEWPORT_SIZE.y));
    vec3 incident=normalize((INV_VIEW_MATRIX*vec4(-normalize(VIEW),0.0)).xyz);
    vec3 flat_ray=refract(incident,vec3(0.0,1.0,0.0),.75019);
    vec3 bent_ray=refract(incident,surface_world_normal,.75019);
    vec2 bend=(bent_ray.xz/max(-bent_ray.y,.2)-flat_ray.xz/max(-flat_ray.y,.2))*min(water_depth,4.0)*refraction_strength;
    vec2 offset=projected_water_offset(vec3(bend.x,0.0,bend.y),VERTEX,VIEW_MATRIX,PROJECTION_MATRIX);
    vec2 texel_offset=offset/pixel;
    offset/=sqrt(1.0+dot(texel_offset,texel_offset)/36.0);
    vec2 refract_uv = clamp(SCREEN_UV+offset*border*smoothstep(.02,.45,water_depth),pixel*.5,1.0-pixel*.5);
    float rd = texture(depth_tex,refract_uv).r;
    vec4 refract_view = INV_PROJECTION_MATRIX*vec4(refract_uv*2.0-1.0,rd,1.0);
    refract_view.xyz /= refract_view.w;
    vec3 refract_world = (INV_VIEW_MATRIX*vec4(refract_view.xyz,1.0)).xyz;
    if (refract_world.y > wp.y+.025 || -refract_view.z < -VERTEX.z) {
        refract_uv=SCREEN_UV;
        refract_view=bed_view;
    }
    // Measure the accepted sample's optical path, not the vertical water level
    // or a perspective-only 1/z approximation. Works with orthographic zoom.
    float optical_path=clamp(length(refract_view.xyz-VERTEX),0.0,24.0);
    vec3 transmittance=exp(-absorption*optical_path*.60);
    // Preserve the bottom's local contrast. Clear water absorbs a little light;
    // a large constant in-scatter term makes it look like grey/green paint.
    vec3 background=clear_refraction(refract_uv,pixel,texture(screen_tex,SCREEN_UV).rgb,wp.y,VERTEX.z,INV_PROJECTION_MATRIX,INV_VIEW_MATRIX);
    vec3 col=background*transmittance+water_tint.rgb*(vec3(1.0)-transmittance)*scattering_strength*weather_light;
    vec3 reflection_offset=vec3(-slope.x,0.0,-slope.y)*reflection_distortion;
    vec4 reflection_p = reflection_vp * vec4(wp+reflection_offset, 1.0);
    vec2 reflect_uv = reflection_p.xy / reflection_p.w * 0.5 + 0.5;
    reflect_uv.y = 1.0 - reflect_uv.y;
    float reflection_border=smoothstep(0.0,.045,min(min(reflect_uv.x,1.0-reflect_uv.x),min(reflect_uv.y,1.0-reflect_uv.y)));
    float fresnel=.02+.98*pow(1.0-clamp(dot(surface_view_normal,normalize(VIEW)),0.0,1.0),5.0);
    if (use_reflection) {
        vec4 reflected=continuous_reflection(clamp(reflect_uv,vec2(.001),vec2(.999)));
        // Near-vertical views mostly transmit the bed. A constant reflection
        // floor washes out clear water even when Fresnel reflectance is tiny.
        col=mix(col,reflected.rgb,clamp(reflected.a*reflection_border*reflection_strength*fresnel,0.0,1.0));
    }
    float shore=(1.0-smoothstep(.035,.18,water_depth))*mix(.55,1.0,field_noise(p*.8+weather_clock*.025));
    vec3 sunlight=normalize((VIEW_MATRIX*vec4(sun_direction,0.0)).xyz);
    vec3 halfway=normalize(sunlight+normalize(VIEW));
    // A broad low-exponent lobe looked like moving grey fog. Resolve the small
    // sun footprint instead, retaining its energy as a glint becomes subpixel.
    float alignment=max(dot(surface_view_normal,halfway),0.0);
    float glint_width=.00012;
    float glint_aa=max(fwidth(alignment)*.65,.00004);
    float sun_glint=(1.0-smoothstep(glint_width,glint_width+glint_aa,1.0-alignment))*glint_width/(glint_width+glint_aa)*(1.0-weather_cloud*.8);
    float crests=water_crest_marker(p,world_pixel)*.020*(1.0-weather_cloud*.65);
    float highlights=max(max(sun_glint*sun_glint_strength+crests,shore*shore_foam_strength),max(rain.w,contacts.w));
    col=mix(col,foam.rgb*max(weather_light,vec3(.10,.15,.23)),clamp(highlights,0.0,.72));
    ALBEDO = col;
    ALPHA = 1.0;
}
