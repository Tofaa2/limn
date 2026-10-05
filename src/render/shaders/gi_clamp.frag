#version 460
#include "common.glsl"

// Bounds the steady irradiance atlas by the fast one. Drawn twice, with
// minimum and maximum blending, so the atlas ends up clamped to
// [fast * (1 - tolerance), fast * (1 + tolerance)] without being read.
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
