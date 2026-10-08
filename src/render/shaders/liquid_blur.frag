#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
    uint raw;
    vec2 direction;
    float width;
    float edge;
} push;

layout(location = 0) out float out_distance;

float distanceAt(ivec2 pixel) {
    float value = texelFetch(TEX(push.source_texture, push.frame.sampler_nearest_clamp), pixel, 0).r;
    if (push.raw == 0u) return value;
    return value > 0.0 ? linearDepth(value, push.frame.near) : 0.0;
}

void main() {
    FrameConstants frame = push.frame;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float center = distanceAt(pixel);
    if (center <= 0.0) {
        out_distance = 0.0;
        return;
    }
    float pixels = clamp(push.width * abs(frame.proj[1][1]) * frame.resolution.y * 0.5 / center, 1.0, 28.0);
    int reach = int(ceil(pixels));
    float sum = center;
    float weight = 1.0;
    for (int i = 1; i <= reach; i++) {
        float along = float(i) / pixels;
        float falloff = exp(-2.5 * along * along);
        for (int side = -1; side <= 1; side += 2) {
            float value = distanceAt(pixel + ivec2(push.direction) * (i * side));
            if (value <= 0.0) continue;
            float jump = (value - center) / push.edge;
            float w = falloff * exp(-jump * jump);
            sum += value * w;
            weight += w;
        }
    }
    out_distance = sum / weight;
}
