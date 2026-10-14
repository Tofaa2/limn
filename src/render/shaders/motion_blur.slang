#include "common.slang"

struct Push {
    FrameConstants frame;
    uint color_texture;
    uint motion_texture;
    float shutter;
    float max_length;
    int tap_count;
    uint spread;
};

[[vk::push_constant]] Push push;

[shader("fragment")]
float4 fragmentMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = push.frame;
    uint linear = frame.sampler_linear_clamp;
    uint nearest = frame.sampler_nearest_clamp;
    float2 own = sampleTextureLod(push.motion_texture, nearest, in_uv, 0.0).rg * push.shutter;
    float noise = interleavedGradientNoise(fragment.xy, frame.frame_index);
    float2 pixels = frame.resolution;
    float2 motion = own;
    if (push.spread != 0u) {
        float fastest = length(own * pixels);
        for (int i = 0; i < 8; i++) {
            float angle = (float(i) + noise) * 0.78539816;
            float radius = push.max_length * 0.5 * sqrt((float(i) + 0.5) / 8.0);
            float2 offset = float2(cos(angle), sin(angle)) * radius * float2(pixels.y / pixels.x, 1.0);
            float2 there = sampleTextureLod(push.motion_texture, nearest, in_uv + offset, 0.0).rg * push.shutter;
            float speed = length(there * pixels);
            if (speed > fastest && speed * 0.5 >= length(offset * pixels)) {
                fastest = speed;
                motion = there;
            }
        }
    }
    float travelled = length(motion);
    float3 center = sampleTextureLod(push.color_texture, linear, in_uv, 0.0).rgb;
    if (travelled * frame.resolution.y < 1.0) return float4(center, 1.0);
    if (travelled > push.max_length) motion *= push.max_length / travelled;
    float offset = noise - 0.5;
    float own_reach = length(own * pixels) * 0.5;
    float3 total = float3(0.0);
    for (int i = 0; i < push.tap_count; i++) {
        float t = (float(i) + 0.5 + offset) / float(push.tap_count) - 0.5;
        float2 uv = in_uv - motion * t;
        float weight = 1.0;
        if (push.spread != 0u) {
            float distance_pixels = length(motion * t * pixels);
            float tap_reach = length(sampleTextureLod(push.motion_texture, nearest, uv, 0.0).rg * push.shutter * pixels) * 0.5;
            weight = clamp(max(tap_reach, own_reach) - distance_pixels + 1.0, 0.0, 1.0);
        }
        total += lerp(center, sampleTextureLod(push.color_texture, linear, uv, 0.0).rgb, weight);
    }
    return float4(total / float(push.tap_count), 1.0);
}
