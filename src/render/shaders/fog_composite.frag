#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint fog_texture;
    uint depth_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    float center = linearDepth(texelFetch(TEX(push.depth_texture, nearest), ivec2(gl_FragCoord.xy), 0).r, frame.near);
    ivec2 fog_size = textureSize(TEX(push.fog_texture, nearest), 0);
    vec2 position = in_uv * vec2(fog_size) - 0.5;
    ivec2 base = ivec2(floor(position));
    vec2 f = position - vec2(base);
    vec4 total = vec4(0.0);
    float weight_total = 0.0;
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 2; x++) {
            ivec2 tap = clamp(base + ivec2(x, y), ivec2(0), fog_size - 1);
            vec2 tap_uv = (vec2(tap) + 0.5) / vec2(fog_size);
            float depth = linearDepth(textureLod(TEX(push.depth_texture, nearest), tap_uv, 0.0).r, frame.near);
            float bilinear = (x == 0 ? 1.0 - f.x : f.x) * (y == 0 ? 1.0 - f.y : f.y);
            float weight = bilinear / (1e-3 + abs(depth - center) / max(center, 1e-3) * 20.0);
            total += texelFetch(TEX(push.fog_texture, nearest), tap, 0) * weight;
            weight_total += weight;
        }
    }
    vec4 fog = total / max(weight_total, 1e-6);
    out_color = vec4(fog.rgb, 1.0 - fog.a);
}
