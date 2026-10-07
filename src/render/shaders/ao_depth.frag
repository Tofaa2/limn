#version 460
#include "common.glsl"

// Half-resolution linear view depth with a mip chain, for ambient occlusion.
layout(push_constant, scalar) uniform Push {
    uint source_texture;
    uint sampler_index;
    // Nonzero when reading the full-resolution depth buffer (level 0).
    uint first;
    int source_lod;
    float near;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out float out_depth;

const float sky_depth = 60000.0;

void main() {
    if (push.first != 0u) {
        float depth = textureLod(TEX(push.source_texture, push.sampler_index), in_uv, 0.0).r;
        out_depth = min(linearDepth(depth, push.near), sky_depth);
        return;
    }
    ivec2 base = ivec2(gl_FragCoord.xy) * 2;
    ivec2 limit = textureSize(TEX(push.source_texture, push.sampler_index), push.source_lod) - 1;
    float a = texelFetch(TEX(push.source_texture, push.sampler_index), min(base, limit), push.source_lod).r;
    float b = texelFetch(TEX(push.source_texture, push.sampler_index), min(base + ivec2(1, 0), limit), push.source_lod).r;
    float c = texelFetch(TEX(push.source_texture, push.sampler_index), min(base + ivec2(0, 1), limit), push.source_lod).r;
    float d = texelFetch(TEX(push.source_texture, push.sampler_index), min(base + ivec2(1, 1), limit), push.source_lod).r;
    // Average only the samples near the farthest depth (XeGTAO).
    float farthest = max(max(a, b), max(c, d));
    vec4 depths = vec4(a, b, c, d);
    vec4 weights = clamp(1.0 - (farthest - depths) / (farthest * 0.1 + 1e-4), 0.0, 1.0);
    out_depth = dot(depths, weights) / dot(weights, vec4(1.0));
}
