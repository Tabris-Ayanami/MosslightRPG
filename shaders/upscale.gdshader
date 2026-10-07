shader_type canvas_item;
render_mode unshaded;
uniform vec2 snap_offset = vec2(0.0);
void fragment() {
    // Two spare pixels around the low-resolution viewport cover snap motion.
    vec2 source_size = 1.0 / TEXTURE_PIXEL_SIZE;
    vec2 uv = (UV * (source_size - vec2(4.0)) + vec2(2.0) + snap_offset) / source_size;
    // Cole Cecil / t3ssel8r: interpolate only where an output pixel straddles
    // source texels. Keep the existing padded viewport and camera compensation.
    vec2 texel=uv*source_size;
    vec2 footprint=clamp(fwidth(texel),vec2(.0001),vec2(1.0));
    vec2 within=fract(texel);
    vec2 amount=clamp(within/footprint,vec2(0),vec2(.5))
               +clamp((within-1.0)/footprint+.5,vec2(0),vec2(.5));
    vec2 from_center=amount-.5;
    amount=.5+.5*sign(from_center)*smoothstep(vec2(0),vec2(1),abs(from_center)*2.0);
    COLOR=textureGrad(TEXTURE,(floor(texel)+amount)/source_size,dFdx(uv),dFdy(uv));
}
