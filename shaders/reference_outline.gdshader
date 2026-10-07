shader_type spatial;
render_mode unshaded, blend_mul, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest, repeat_disable;
void vertex() { POSITION = vec4(VERTEX.xy,1.0,1.0); }
float depth_at(vec2 uv, mat4 ip) {
    vec4 v = ip * vec4(uv * 2.0 - 1.0, texture(depth_tex,uv).r, 1.0);
    return -v.z / v.w;
}
void fragment() {
    vec4 depth_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, texture(depth_tex, SCREEN_UV).r, 1.0);
    vec3 depth_world = (INV_VIEW_MATRIX * vec4(depth_view.xyz / depth_view.w, 1.0)).xyz;
    if (depth_world.y < 0.65) discard;
    vec2 px = 1.0 / VIEWPORT_SIZE;
    float c = depth_at(SCREEN_UV, INV_PROJECTION_MATRIX);
    vec3 n = texture(normal_tex,SCREEN_UV).rgb * 2.0 - 1.0;
    float roughness = texture(normal_tex,SCREEN_UV).a;
    bool canopy = roughness > .015 && roughness < .049;
    float edge = 0.0, convex = 0.0, front = 0.0;
    vec2 offsets[4] = {vec2(-1,0), vec2(1,0), vec2(0,-1), vec2(0,1)};
    for (int i=0;i<4;i++) {
        vec2 uv = clamp(SCREEN_UV + offsets[i] * px,px*.5,1.0-px*.5);
        float nd = depth_at(uv,INV_PROJECTION_MATRIX);
        vec3 nn = texture(normal_tex,uv).rgb * 2.0 - 1.0;
        float neighbour_roughness = texture(normal_tex,uv).a;
        bool same_canopy = canopy && neighbour_roughness > .015 && neighbour_roughness < .049;
        edge += same_canopy ? 0.0 : max(nd - c - 0.11, 0.0);
        front += max(c - nd - 0.13, 0.0);
        convex += (1.0-dot(n,nn)) * step(0.025,dot(n-nn,vec3(0.35,0.65,0.2))) * (1.0-step(0.24,abs(nd-c)));
    }
    float silhouette = smoothstep(roughness < 0.05 ? 1.4 : 0.35, roughness < 0.05 ? 2.1 : 0.65, edge);
    float highlight = smoothstep(0.16,0.38,convex) * (1.0-step(0.3,front)) * step(0.05,roughness);
    // Modulate the completed color instead of painting an opaque-pass screen
    // copy over water/alpha geometry. White leaves the current pixel unchanged.
    ALBEDO = mix(vec3(1.0),vec3(.65),silhouette*.65);
    ALBEDO *= mix(vec3(1.0),vec3(1.24),highlight*.65);
    ALPHA = 1.0;
}
