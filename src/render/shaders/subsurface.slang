//! Separable subsurface scattering (Jimenez et al. 2015): the diffuse light
//! of subsurface pixels blurred across the screen, red farthest, by a width
//! that follows depth, stopping at depth edges.
#include "common.slang"

#include "subsurface.BlurPush.slang"

[[vk::push_constant]] BlurPush push;

[shader("fragment")]
float4 blurMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = push.frame;
    int2 pixel = int2(fragment.xy);
    int2 last_pixel = int2(textureSize(push.source)) - 1;
    float4 center = fetchTexel(push.source, pixel);
    float3 before = push.last != 0u ? fetchTexel(push.original, pixel).rgb : center.rgb;
    if (center.a <= 0.0) return push.last != 0u ? float4(0.0) : center;
    float depth = linearDepth(fetchTexel(push.depth, pixel).r, frame.depth_terms);
    float reach = center.a * push.radius;
    float pixels = reach * abs(frame.proj[1][1]) * 0.5 * frame.resolution.y / max(depth, 1e-3);
    if (pixels < 0.5) return push.last != 0u ? float4(center.rgb - before, 0.0) : center;
    const float3 spread = float3(1.0, 0.42, 0.22);
    const int taps = 8;
    float3 total = float3(0.0);
    float3 weights = float3(0.0);
    for (int i = -taps; i <= taps; i++) {
        float along = float(i) / float(taps);
        int2 at = clamp(pixel + int2(round(push.direction * (along * pixels))), int2(0), last_pixel);
        float4 tap = fetchTexel(push.source, at);
        float tap_depth = linearDepth(fetchTexel(push.depth, at).r, frame.depth_terms);
        float kept = tap.a > 0.0 ? clamp(1.0 - abs(tap_depth - depth) / max(reach, 1e-4), 0.0, 1.0) : 0.0;
        float3 weight = exp(-along * along / (2.0 * spread * spread));
        total += lerp(center.rgb, tap.rgb, kept) * weight;
        weights += weight;
    }
    float3 blurred = total / weights;
    return push.last != 0u ? float4(blurred - before, 0.0) : float4(blurred, center.a);
}
