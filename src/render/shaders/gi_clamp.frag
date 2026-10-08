#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint fast_texture;
    float scale;
    float offset;
} push;

layout(location = 0) out vec4 out_bound;

void main() {
    vec3 fast = texelFetch(TEX(push.fast_texture, push.frame.sampler_nearest_clamp), ivec2(gl_FragCoord.xy), 0).rgb;
    out_bound = vec4(max(fast * push.scale + push.offset, vec3(0.0)), 1.0);
}
