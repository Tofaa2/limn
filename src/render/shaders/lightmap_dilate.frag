#version 460
#include "common.glsl"

// Dilates covered lightmap texels into uncovered neighbours, against bilinear
// bleeding at patch edges.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
} push;

layout(location = 0) out vec4 out_light;

void main() {
    uint nearest = push.frame.sampler_nearest_clamp;
    ivec2 texel = ivec2(gl_FragCoord.xy);
    ivec2 last = textureSize(TEX(push.source_texture, nearest), 0) - 1;
    vec4 own = texelFetch(TEX(push.source_texture, nearest), texel, 0);
    if (own.a > 0.0) {
        out_light = vec4(own.rgb, 1.0);
        return;
    }
    vec3 total = vec3(0.0);
    float weight_total = 0.0;
    for (int y = -3; y <= 3; y++) {
        for (int x = -3; x <= 3; x++) {
            vec4 tap = texelFetch(TEX(push.source_texture, nearest), clamp(texel + ivec2(x, y), ivec2(0), last), 0);
            if (tap.a <= 0.0) continue;
            float weight = 1.0 / float(x * x + y * y);
            total += tap.rgb * weight;
            weight_total += weight;
        }
    }
    out_light = weight_total > 0.0 ? vec4(total / weight_total, 1.0) : vec4(0.0);
}
