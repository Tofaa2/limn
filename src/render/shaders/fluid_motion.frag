#version 460
#include "common.glsl"

// Blends fluid motion over the scene's motion vectors by fluid coverage.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_motion;

void main() {
    out_motion = textureLod(TEX(push.source_texture, push.frame.sampler_linear_clamp), in_uv, 0.0);
}
