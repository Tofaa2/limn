#ifndef PATH_HISTORY_SLANG
#define PATH_HISTORY_SLANG
#include "common.slang"

bool broken(float3 value) {
    return any(isnan(value)) || any(isinf(value));
}

bool broken(float4 value) {
    return any(isnan(value)) || any(isinf(value));
}

/// Where on last frame's screen `spot` was, which the pixel at `fragment`
/// sees at `reach` along its ray. Follows a moving object where the
/// rasterized picture shows the same surface.
bool seenLastFrame(FrameConstants frame, float2 fragment, bool moved, uint depth_texture, uint motion_texture, float3 spot, float reach, bool mirrored, out float2 was_at) {
    was_at = fragment * frame.inv_resolution;
    if (!moved) return true;
    float4 clip = mul(frame.prev_view_proj_unjittered, float4(spot, 1.0));
    if (clip.w <= 0.0) return false;
    was_at = clip.xy / clip.w * 0.5 + 0.5 + frame.prev_jitter;
    if (!mirrored) {
        int2 pixel = int2(fragment);
        float depth = fetchTexel(depth_texture, pixel).r;
        float3 drawn = worldPositionFromDepth(fragment * frame.inv_resolution, depth, frame.inv_view_proj);
        if (depth > 0.0 && abs(distance(drawn, frame.camera_position) - reach) <= 0.02 * reach + 0.01) {
            float4 now = mul(frame.view_proj_unjittered, float4(spot, 1.0));
            was_at += (now.xy / now.w - clip.xy / clip.w) * 0.5 - fetchTexel(motion_texture, pixel).rg;
        }
    }
    return all(was_at > 0.0) && all(was_at < 1.0);
}

/// A picture kept from last frame read between its texels without the
/// softening a plain blend of four gives, and no brighter or darker than
/// those four.
float3 historySharp(uint texture_index, uint sampler_index, float2 uv, float2 size) {
    float2 place = uv * size;
    float2 base = floor(place - 0.5) + 0.5;
    float2 f = place - base;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 close = (base + w2 / w12) / size;
    float2 before = (base - 1.0) / size;
    float2 after = (base + 2.0) / size;
    float3 total = sampleTextureLod(texture_index, sampler_index, float2(close.x, before.y), 0.0).rgb * (w12.x * w0.y);
    total += sampleTextureLod(texture_index, sampler_index, float2(before.x, close.y), 0.0).rgb * (w0.x * w12.y);
    total += sampleTextureLod(texture_index, sampler_index, float2(close.x, close.y), 0.0).rgb * (w12.x * w12.y);
    total += sampleTextureLod(texture_index, sampler_index, float2(after.x, close.y), 0.0).rgb * (w3.x * w12.y);
    total += sampleTextureLod(texture_index, sampler_index, float2(close.x, after.y), 0.0).rgb * (w12.x * w3.y);
    float weight = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    int2 corner = int2(base - 0.5);
    int2 last = int2(size) - 1;
    float3 a = fetchTexel(texture_index, clamp(corner, int2(0), last)).rgb;
    float3 b = fetchTexel(texture_index, clamp(corner + int2(1, 0), int2(0), last)).rgb;
    float3 c = fetchTexel(texture_index, clamp(corner + int2(0, 1), int2(0), last)).rgb;
    float3 d = fetchTexel(texture_index, clamp(corner + int2(1, 1), int2(0), last)).rgb;
    return clamp(total / weight, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
}

#endif
