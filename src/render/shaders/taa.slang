#include "common.slang"

#include "taa.Push.slang"

[[vk::push_constant]] Push push;

float3 toYCoCg(float3 c) {
    return float3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

float3 fromYCoCg(float3 c) {
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

float3 compress(float3 c) {
    return c / (1.0 + luminance(c));
}

float3 expand(float3 c) {
    return c / max(1.0 - luminance(c), 1e-4);
}

float3 sampleHistory(FrameConstants frame, float2 uv) {
    uint history_texture = push.history_texture;
    float2 history_size = textureSize(history_texture);
    float2 position = uv * history_size;
    float2 center = floor(position - 0.5) + 0.5;
    float2 f = position - center;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 tc0 = (center - 1.0) / history_size;
    float2 tc12 = (center + w2 / w12) / history_size;
    float2 tc3 = (center + 2.0) / history_size;
    uint s = frame.sampler_linear_clamp;
    float4 result =
        float4(sampleTextureLod(history_texture, s, float2(tc12.x, tc0.y), 0.0).rgb, 1.0) * (w12.x * w0.y) +
        float4(sampleTextureLod(history_texture, s, float2(tc0.x, tc12.y), 0.0).rgb, 1.0) * (w0.x * w12.y) +
        float4(sampleTextureLod(history_texture, s, float2(tc12.x, tc12.y), 0.0).rgb, 1.0) * (w12.x * w12.y) +
        float4(sampleTextureLod(history_texture, s, float2(tc3.x, tc12.y), 0.0).rgb, 1.0) * (w3.x * w12.y) +
        float4(sampleTextureLod(history_texture, s, float2(tc12.x, tc3.y), 0.0).rgb, 1.0) * (w12.x * w3.y);
    return max(result.rgb / result.a, float3(0.0));
}

/// Share of this frame in what moves `moving_speed` pixels a frame or
/// faster. History is resampled every frame it is kept, which softens it,
/// so what moves keeps less of it than what stands still.
static const float moving_blend = 0.5;
static const float moving_speed = 2.0;

/// How fast, in pixels a frame, anything near the reprojected pixel moved last frame.
float speedBefore(FrameConstants frame, float2 history_uv) {
    if (push.previous_motion_texture == INVALID_ID) return 0.0;
    int2 at = int2(history_uv * frame.resolution);
    int2 limit = int2(frame.resolution) - 1;
    float fastest = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 moved = fetchTexel(push.previous_motion_texture, clamp(at + int2(x, y), int2(0), limit)).rg * frame.resolution;
            fastest = max(fastest, dot(moved, moved));
        }
    }
    return sqrt(fastest);
}

[shader("fragment")]
float4 fragmentMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    FrameConstants frame = push.frame;
    int2 pixel = min(int2(in_uv * frame.resolution), int2(frame.resolution) - 1);
    int2 limit = int2(frame.resolution) - 1;

    float carried = fetchTexel(push.color_texture, pixel).a;
    if (push.history_valid == 0u) return fetchTexel(push.color_texture, pixel);

    float2 jitter_pixels = frame.jitter * frame.resolution;
    float3 filtered = float3(0.0);
    float filtered_weight = 0.0;
    float span = frame.resolution.x / textureSize(push.history_texture).x;
    bool upscaling = span < 0.999;
    float3 narrow = float3(0.0);
    float narrow_weight = 0.0;
    float3 mean = float3(0.0);
    float3 mean_squared = float3(0.0);
    float closest_depth = 0.0;
    int2 closest_pixel = pixel;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int2 tap = clamp(pixel + int2(x, y), int2(0), limit);
            float3 c = toYCoCg(compress(fetchTexel(push.color_texture, tap).rgb));
            float2 offset_pixels = float2(pixel + int2(x, y)) + 0.5 - jitter_pixels - in_uv * frame.resolution;
            float tap_weight = exp(-2.29 * dot(offset_pixels, offset_pixels));
            filtered += c * tap_weight;
            float narrow_tap = exp(-2.29 * dot(offset_pixels, offset_pixels) / (span * span));
            narrow += c * narrow_tap;
            narrow_weight += narrow_tap;
            filtered_weight += tap_weight;
            mean += c;
            mean_squared += c * c;
            float depth = fetchTexel(push.depth_texture, tap).r;
            if (depth > closest_depth) {
                closest_depth = depth;
                closest_pixel = tap;
            }
        }
    }
    mean /= 9.0;
    float3 deviation = sqrt(max(mean_squared / 9.0 - mean * mean, float3(0.0)));

    float2 motion = fetchTexel(push.motion_texture, closest_pixel).rg;
    float2 history_uv = in_uv - motion;
    if (any(history_uv < 0.0) || any(history_uv > 1.0)) {
        return float4(max(expand(fromYCoCg(filtered / filtered_weight)), float3(0.0)), carried);
    }

    float3 history = toYCoCg(compress(sampleHistory(frame, history_uv)));
    float3 current_ycocg = filtered / filtered_weight;
    float confidence = 1.0;
    if (upscaling) {
        confidence = clamp(narrow_weight, 0.0, 1.0);
        current_ycocg = lerp(current_ycocg, narrow / max(narrow_weight, 1e-6), confidence);
    }
    float speed = length(motion * frame.resolution);
    float gamma = lerp(1.75, 1.0, clamp(max(speed, speedBefore(frame, history_uv)) * 0.5, 0.0, 1.0));
    float3 box_min = mean - gamma * deviation;
    float3 box_max = mean + gamma * deviation;
    float3 box_center = 0.5 * (box_max + box_min);
    float3 box_extent = 0.5 * (box_max - box_min) + 1e-5;
    float3 offset = history - box_center;
    float3 unit = abs(offset / box_extent);
    float max_unit = max(unit.x, max(unit.y, unit.z));
    if (max_unit > 1.0) history = box_center + offset / max_unit;

    float blend = (upscaling ? lerp(0.05, 0.2, clamp(speed / 24.0, 0.0, 1.0)) : lerp(0.05, moving_blend, clamp(speed / moving_speed, 0.0, 1.0))) * max(confidence, 0.15);
    float flicker = abs(current_ycocg.x - history.x) / max(max(current_ycocg.x, history.x), 1e-3);
    blend *= 1.0 - 0.85 * flicker * (1.0 - clamp(speed, 0.0, 1.0));
    float3 resolved = expand(fromYCoCg(lerp(history, current_ycocg, blend)));
    if (!upscaling) resolved = lerp(resolved, fetchTexel(push.color_texture, pixel).rgb, push.settled);
    return float4(max(resolved, float3(0.0)), carried);
}
