#version 460
#include "common.glsl"

// Builds one level of the depth pyramid used for occlusion culling. With
// reverse-Z the farthest surface has the smallest depth, so each texel keeps
// the minimum of the region it covers: anything nearer than that value in
// front of the whole region is certainly hidden.
layout(push_constant, scalar) uniform Push {
    uint source_texture;
    uint sampler_index;
    // Nonzero when reading the full-resolution depth buffer (level 0).
    uint first;
    int source_lod;
    vec2 texel;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out float out_depth;

void main() {
    if (push.first != 0u) {
        // The pyramid's top level is at most 2x smaller than the depth
        // buffer per axis, so four taps cover every source texel under it.
        vec2 offset = push.texel * 0.25;
        float a = textureLod(TEX(push.source_texture, push.sampler_index), in_uv + vec2(-offset.x, -offset.y), 0.0).r;
        float b = textureLod(TEX(push.source_texture, push.sampler_index), in_uv + vec2(offset.x, -offset.y), 0.0).r;
        float c = textureLod(TEX(push.source_texture, push.sampler_index), in_uv + vec2(-offset.x, offset.y), 0.0).r;
        float d = textureLod(TEX(push.source_texture, push.sampler_index), in_uv + vec2(offset.x, offset.y), 0.0).r;
        out_depth = min(min(a, b), min(c, d));
        return;
    }
    ivec2 base = ivec2(gl_FragCoord.xy) * 2;
    ivec2 limit = textureSize(TEX(push.source_texture, push.sampler_index), push.source_lod) - 1;
    float a = texelFetch(TEX(push.source_texture, push.sampler_index), min(base, limit), push.source_lod).r;
    float b = texelFetch(TEX(push.source_texture, push.sampler_index), min(base + ivec2(1, 0), limit), push.source_lod).r;
    float c = texelFetch(TEX(push.source_texture, push.sampler_index), min(base + ivec2(0, 1), limit), push.source_lod).r;
    float d = texelFetch(TEX(push.source_texture, push.sampler_index), min(base + ivec2(1, 1), limit), push.source_lod).r;
    out_depth = min(min(a, b), min(c, d));
}
