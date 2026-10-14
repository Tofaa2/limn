#include "common.slang"

struct BlurPush {
    FrameConstants frame;
    uint color_texture;
    uint depth_texture;
    float focus_distance;
    float strength;
    float max_radius;
    int tap_count;
    uint blades;
};

[[vk::push_constant]] BlurPush blur_push;

float blurRadius(float view_depth, float focus_distance) {
    return min(blur_push.strength * abs(view_depth - focus_distance) / max(view_depth, 1e-3), blur_push.max_radius);
}

[shader("fragment")]
float4 blurMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = blur_push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    uint linear = frame.sampler_linear_clamp;
    float focus_distance = blur_push.focus_distance;
    if (focus_distance < 0.0) focus_distance = max(frame.exposure.data.focus, frame.near);
    float center_depth = linearDepth(sampleTextureLod(blur_push.depth_texture, nearest, in_uv, 0.0).r, frame.depth_terms);
    float center_radius = blurRadius(center_depth, focus_distance);
    float3 total = sampleTextureLod(blur_push.color_texture, linear, in_uv, 0.0).rgb;
    float weight_total = 1.0;
    float spin = interleavedGradientNoise(fragment.xy, frame.frame_index) * 6.2831853;
    for (int i = 0; i < blur_push.tap_count; i++) {
        float distance_pixels = blur_push.max_radius * sqrt((float(i) + 0.5) / float(blur_push.tap_count));
        float angle = float(i) * 2.39996323 + spin;
        float reach = distance_pixels;
        if (blur_push.blades >= 3u) {
            float sector = 6.2831853 / float(blur_push.blades);
            float within = angle - sector * floor(angle / sector) - 0.5 * sector;
            distance_pixels *= cos(0.5 * sector) / cos(within);
        }
        float2 uv = in_uv + float2(cos(angle), sin(angle)) * distance_pixels * frame.inv_resolution;
        float tap_depth = linearDepth(sampleTextureLod(blur_push.depth_texture, nearest, uv, 0.0).r, frame.depth_terms);
        float tap_radius = blurRadius(tap_depth, focus_distance);
        if (tap_depth > center_depth) tap_radius = min(tap_radius, center_radius);
        float weight = smoothstep(reach - 1.0, reach + 1.0, tap_radius);
        total += sampleTextureLod(blur_push.color_texture, linear, uv, 0.0).rgb * weight;
        weight_total += weight;
    }
    return float4(total / weight_total, clamp(center_radius / max(blur_push.max_radius, 1e-3), 0.0, 1.0));
}

struct CompositePush {
    FrameConstants frame;
    uint color_texture;
    uint blurred_texture;
    uint depth_texture;
    float focus_distance;
    float strength;
    float max_radius;
};

[[vk::push_constant]] CompositePush composite_push;

[shader("fragment")]
float4 compositeMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = composite_push.frame;
    float focus_distance = composite_push.focus_distance;
    if (focus_distance < 0.0) focus_distance = max(frame.exposure.data.focus, frame.near);
    float view_depth = linearDepth(sampleTextureLod(composite_push.depth_texture, frame.sampler_nearest_clamp, in_uv, 0.0).r, frame.depth_terms);
    float radius = min(composite_push.strength * abs(view_depth - focus_distance) / max(view_depth, 1e-3), composite_push.max_radius);
    float3 sharp = fetchTexel(composite_push.color_texture, int2(fragment.xy)).rgb;
    float4 blurred = sampleTextureLod(composite_push.blurred_texture, frame.sampler_linear_clamp, in_uv, 0.0);
    float spilled = blurred.a * composite_push.max_radius;
    float amount = smoothstep(0.5, 2.5, max(radius, spilled));
    return float4(lerp(sharp, blurred.rgb, amount), 1.0);
}
