#version 460
#include "common.glsl"

// 3x3 tent upsample, additively blended onto the next larger level.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
    uint pad;
    vec2 source_texel;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

vec3 tap(vec2 offset) {
    return textureLod(TEX(push.source_texture, push.frame.sampler_linear_clamp), in_uv + offset * push.source_texel, 0.0).rgb;
}

void main() {
    vec3 color = tap(vec2(0, 0)) * 4.0;
    color += (tap(vec2(-1, 0)) + tap(vec2(1, 0)) + tap(vec2(0, -1)) + tap(vec2(0, 1))) * 2.0;
    color += tap(vec2(-1, -1)) + tap(vec2(1, -1)) + tap(vec2(-1, 1)) + tap(vec2(1, 1));
    out_color = vec4(color / 16.0, 1.0);
}
