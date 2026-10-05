#version 460
#include "common.glsl"

// Lays the smoke's motion over the scene's motion vectors, by how much of
// each pixel the smoke covers, so that antialiasing over frames follows
// the smoke instead of what is behind it.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_motion;

void main() {
    out_motion = textureLod(TEX(push.source_texture, push.frame.sampler_linear_clamp), in_uv, 0.0);
}
