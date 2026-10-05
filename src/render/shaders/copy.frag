#version 460
#include "common.glsl"

// Copies one texture into another of the same size.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
} push;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = texelFetch(TEX(push.source_texture, push.frame.sampler_nearest_clamp), ivec2(gl_FragCoord.xy), 0);
}
