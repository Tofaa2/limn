#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint accumulation_texture;
    uint reveal_texture;
} push;

layout(location = 0) out vec4 out_color;

void main() {
    uint nearest = push.frame.sampler_nearest_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float reveal = texelFetch(TEX(push.reveal_texture, nearest), pixel, 0).r;
    if (reveal >= 1.0) discard;
    vec4 accumulation = texelFetch(TEX(push.accumulation_texture, nearest), pixel, 0);
    out_color = vec4(accumulation.rgb / max(accumulation.a, 1e-5), 1.0 - reveal);
}
