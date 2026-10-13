#include "path_history.slang"

struct Push {
    FrameConstants frame;
    uint color;
    uint guide;
    uint soft;
    uint facing;
    uint lamp;
    uint gloss;
    uint surface;
    uint history_color;
    uint history_guide;
    uint history_soft;
    uint history_facing;
    uint history_lamp;
    uint history_gloss;
    uint history_surface;
    uint motion;
    uint depth;
    uint moved;
    uint reset;
    float history_limit;
    float lamp_limit;
    float3 previous_camera;
    float pad;
};

[[vk::push_constant]] Push push;

/// The share of this frame in light that needs no filtering while the
/// camera moves, and in what a mirror shows.
static const float moving_steady_weight = 1.0 / 3.0;
static const float moving_mirror_weight = 0.5;

/// A path traced picture gathered over frames, part by part.
struct Output {
    /// Light that needs no filtering, with the frames gathered in alpha.
    float4 color : SV_Target0;
    float4 guide : SV_Target1;
    /// Bounced light over the surface's color, with its squared brightness in alpha.
    float4 soft : SV_Target2;
    float4 facing : SV_Target3;
    float4 lamp : SV_Target4;
    /// Glossy reflections, with the frames gathered in alpha.
    float4 gloss_gathered : SV_Target5;
    float4 surface : SV_Target6;
};

/// Blends what the tracer found this frame into what was gathered before:
/// at the same pixel while nothing moves, otherwise where the surface was
/// last frame, if that pixel showed the same surface then.
[shader("fragment")]
Output fragmentMain(float4 position : SV_Position) {
    FrameConstants frame = push.frame;
    float2 fragment = position.xy;
    int2 pixel = int2(fragment);
    float4 traced = fetchTexel(push.color, pixel);
    float3 light = traced.rgb;
    bool primary_mirror = traced.a > 0.5;
    float4 guide_now = fetchTexel(push.guide, pixel);
    float3 shown = guide_now.rgb;
    float gloss_reach = guide_now.a;
    float3 grainy = fetchTexel(push.soft, pixel).rgb;
    float4 facing_now = fetchTexel(push.facing, pixel);
    bool first_mirrored = facing_now.a < 0.0;
    float first_distance = abs(facing_now.a);
    float3 lamp_now = fetchTexel(push.lamp, pixel).rgb;
    float3 gloss_now = fetchTexel(push.gloss, pixel).rgb;
    float4 surface_now = fetchTexel(push.surface, pixel);

    float count = 0.0;
    float3 light_before = float3(0.0);
    float4 grainy_before = float4(0.0);
    float3 shown_before = float3(0.0);
    float4 facing_before = float4(0.0);
    float3 lamp_before = float3(0.0);
    if (push.reset == 0u) {
        if (push.moved == 0u) {
            float4 before = fetchTexel(push.history_color, pixel);
            count = before.a;
            light_before = before.rgb;
            grainy_before = fetchTexel(push.history_soft, pixel);
            shown_before = fetchTexel(push.history_guide, pixel).rgb;
            facing_before = fetchTexel(push.history_facing, pixel);
            lamp_before = fetchTexel(push.history_lamp, pixel).rgb;
        } else {
            float2 center = (float2(pixel) + 0.5) * frame.inv_resolution;
            float3 toward = normalize(worldPositionFromDepth(center, 0.5, frame.inv_view_proj) - frame.camera_position);
            float3 spot = frame.camera_position + toward * first_distance;
            float2 was_at;
            if (seenLastFrame(frame, fragment, true, push.depth, push.motion, spot, first_distance, first_mirrored, was_at)) {
                uint linear_sampler = frame.sampler_linear_clamp;
                float4 guide_before = sampleTextureLod(push.history_guide, linear_sampler, was_at, 0.0);
                float4 facing_seen = sampleTextureLod(push.history_facing, linear_sampler, was_at, 0.0);
                float expected = distance(push.previous_camera, spot);
                bool was_mirrored = facing_seen.a < 0.0;
                float3 unlike = abs(guide_before.rgb - shown);
                if (was_mirrored == first_mirrored && abs(abs(facing_seen.a) - expected) <= 0.03 * expected + 0.02 && max(unlike.r, max(unlike.g, unlike.b)) < 0.2) {
                    count = sampleTextureLod(push.history_color, linear_sampler, was_at, 0.0).a;
                    light_before = historySharp(push.history_color, linear_sampler, was_at, frame.resolution);
                    grainy_before = sampleTextureLod(push.history_soft, linear_sampler, was_at, 0.0);
                    shown_before = guide_before.rgb;
                    facing_before = facing_seen;
                    lamp_before = sampleTextureLod(push.history_lamp, linear_sampler, was_at, 0.0).rgb;
                }
            }
            count = min(count, dot(shown, float3(1.0)) > 0.0 && !first_mirrored ? push.history_limit : 6.0);
        }
    }
    if (broken(light_before) || broken(grainy_before) || broken(shown_before) || broken(facing_before) || broken(lamp_before) || isnan(count) || isinf(count)) {
        count = 0.0;
        light_before = float3(0.0);
        lamp_before = float3(0.0);
        grainy_before = float4(0.0);
        shown_before = float3(0.0);
        facing_before = float4(0.0);
    }
    count = min(count, 8192.0);
    float weight = 1.0 / (count + 1.0);
    float steady_weight = push.moved != 0u ? max(weight, primary_mirror ? moving_mirror_weight : moving_steady_weight) : weight;
    Output result;
    result.color = float4(lerp(light_before, light, steady_weight), count + 1.0);
    float brightness = min(luminance(grainy), 240.0);
    result.soft = lerp(grainy_before, float4(grainy, brightness * brightness), weight);
    float shown_weight = push.moved != 0u ? max(weight, 0.7) : weight;
    result.facing = lerp(facing_before, facing_now, shown_weight);
    float4 surface_before = surface_now;
    if (push.reset == 0u && push.moved == 0u) surface_before = fetchTexel(push.history_surface, pixel);
    if (broken(surface_before)) surface_before = surface_now;
    result.surface = lerp(surface_before, surface_now, weight);
    float4 gloss_before = float4(0.0);
    if (push.reset == 0u && push.moved == 0u) gloss_before = fetchTexel(push.history_gloss, pixel);
    if (broken(gloss_before)) gloss_before = float4(0.0);
    result.gloss_gathered = float4(lerp(gloss_before.rgb, gloss_now, 1.0 / (gloss_before.a + 1.0)), min(gloss_before.a + 1.0, 8192.0));
    result.guide = float4(lerp(shown_before, shown, shown_weight), gloss_reach);
    result.lamp = float4(lerp(lamp_before, lamp_now, max(weight, 1.0 / push.lamp_limit)), 1.0);
    return result;
}
