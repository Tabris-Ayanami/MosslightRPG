// Crown-volume lighting on broad geometric sprays. Legacy alpha cards remain
// supported; technique references are in assets/foliage/eduardo/SOURCE.md.
shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, specular_disabled, ambient_light_disabled;
#include "reference_common.gdshaderinc"
uniform sampler2D leaf_mask : filter_linear_mipmap, repeat_disable;
// Older baked cards retain their mask until the authoring scene is rebuilt.
uniform bool sprig_geometry = false;
uniform bool directional_leaflets = false;
uniform bool hanging_leaves=false;
uniform vec4 leaf_light : source_color = vec4(.60,.75,.44,1.0);
uniform vec4 leaf_mid : source_color = vec4(.32,.54,.34,1.0);
uniform vec4 leaf_dark : source_color = vec4(.14,.33,.28,1.0);
varying vec3 wp;
varying vec3 surface_position;
varying vec3 light_anchor;
varying float crown_up;
void vertex() {
    vec3 center = MODEL_MATRIX[3].xyz;
    surface_position = center;
    vec3 n = normalize(mat3(MODEL_MATRIX)*(INSTANCE_CUSTOM.rgb*2.0-1.0));
    vec3 view_normal = (VIEW_MATRIX*vec4(n,0.0)).xyz;
    float seed = INSTANCE_CUSTOM.a;
    float angle = hanging_leaves ? sin(seed*25.0)*.22 : seed * 125.663706;
    if (sprig_geometry) {
        angle = hanging_leaves ? 3.14159265+sin(seed*25.0)*.28 : (seed-.5)*3.8;
    }
    if (directional_leaflets && !hanging_leaves) {
        // Sprays lean out along the crown instead of spinning randomly in place.
        angle = -atan(view_normal.x,max(abs(view_normal.y),.35))*.70+(seed-.5)*1.2;
    }
    vec2 p = VERTEX.xy * vec2(length(MODEL_MATRIX[0].xyz),length(MODEL_MATRIX[1].xyz));
    if (sprig_geometry) {
        // Vary blade lengths along each shoot without adding colour speckle.
        // COLOR.r stores the blade index in sixths, also on older baked meshes.
        float blade = floor(COLOR.r*6.0+.1);
        float shape = fract(sin(seed*57.3+blade*19.7)*437.53);
        p *= mix(.70,1.08,shape);
    }
    p = mat2(vec2(cos(angle),sin(angle)),vec2(-sin(angle),cos(angle))) * p;
    wp = center+tree_bend(center)+wind_flutter(center,.015);
    light_anchor = (VIEW_MATRIX * vec4(wp,1.0)).xyz;
    vec3 pos = wp + INV_VIEW_MATRIX[0].xyz*p.x + INV_VIEW_MATRIX[1].xyz*p.y;
    VERTEX = (VIEW_MATRIX*vec4(pos,1.0)).xyz;
    crown_up = n.y;
    // Every blade on a spray shares its volume normal. Random per-blade normals
    // break a single sunlit plane into distracting, camera-dependent confetti.
    if (directional_leaflets) {
        vec2 axis = COLOR.gb*2.0-1.0;
        axis = mat2(vec2(cos(angle),sin(angle)),vec2(-sin(angle),cos(angle)))*axis;
        // A small coherent blade tilt gives internal depth without random flecks.
        view_normal = normalize(view_normal+vec3(axis*.07,0.0));
    }
    NORMAL = normalize(view_normal);
}
void fragment() {
    ALPHA = sprig_geometry ? 1.0 : texture(leaf_mask,UV).r;
    ALPHA_SCISSOR_THRESHOLD = .48;
    ALBEDO = vec3(1.0);
    // Foliage is excluded from the hard-surface normal-outline pass.
    // Reserved foliage marker lets the outline pass skip internal leaf borders.
    ROUGHNESS = .035;
    LIGHT_VERTEX = light_anchor;
}
void light() {
    float n = dot(NORMAL,LIGHT);
    float direct = smoothstep(.12,.82,ATTENUATION);
    vec3 color = n>.63 ? leaf_light.rgb : (n>.15 ? leaf_mid.rgb : leaf_dark.rgb);
    if (sprig_geometry) {
        // Three connected value groups, with short transitions at the terminator.
        color = mix(leaf_dark.rgb,leaf_mid.rgb,smoothstep(.25,.53,n));
        color = mix(color,leaf_light.rgb,smoothstep(.68,.89,n));
        color *= mix(.97,1.025,UV.y);
    }
    color = weather_coat(color,surface_position,crown_up);
    // Occlusion remains separate from the clump's volume normal.
    color = mix(leaf_dark.rgb*.92,color,direct*.88+.12);
    color *= cloud_light(wp.xz,TIME);
    DIFFUSE_LIGHT += color * LIGHT_COLOR * (LIGHT_IS_DIRECTIONAL ? 1.0 : ATTENUATION) / 3.14159265;
}
