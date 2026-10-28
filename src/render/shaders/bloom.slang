#include "common.slang"

#include "bloom.DownPush.slang"

[[vk::push_constant]] DownPush down_push;

float3 downTap(float2 uv, float2 offset) {
    return sampleTextureLod(down_push.source_texture, down_push.frame.sampler_linear_clamp, uv + offset * down_push.source_texel, 0.0).rgb;
}

float karis(float3 c) {
    return 1.0 / (1.0 + luminance(c));
}

[shader("fragment")]
float4 downMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    float3 a = downTap(in_uv, float2(-2, -2));
    float3 b = downTap(in_uv, float2(0, -2));
    float3 c = downTap(in_uv, float2(2, -2));
    float3 d = downTap(in_uv, float2(-2, 0));
    float3 e = downTap(in_uv, float2(0, 0));
    float3 f = downTap(in_uv, float2(2, 0));
    float3 g = downTap(in_uv, float2(-2, 2));
    float3 h = downTap(in_uv, float2(0, 2));
    float3 i = downTap(in_uv, float2(2, 2));
    float3 j = downTap(in_uv, float2(-1, -1));
    float3 k = downTap(in_uv, float2(1, -1));
    float3 l = downTap(in_uv, float2(-1, 1));
    float3 m = downTap(in_uv, float2(1, 1));

    float3 color;
    if (down_push.first_level != 0u) {
        float3 g0 = (a + b + d + e) * 0.25;
        float3 g1 = (b + c + e + f) * 0.25;
        float3 g2 = (d + e + g + h) * 0.25;
        float3 g3 = (e + f + h + i) * 0.25;
        float3 g4 = (j + k + l + m) * 0.25;
        float w0 = karis(g0) * 0.125;
        float w1 = karis(g1) * 0.125;
        float w2 = karis(g2) * 0.125;
        float w3 = karis(g3) * 0.125;
        float w4 = karis(g4) * 0.5;
        color = (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / (w0 + w1 + w2 + w3 + w4);
    } else {
        color = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    }
    return float4(max(color, float3(0.0)), 1.0);
}

#include "bloom.UpPush.slang"

[[vk::push_constant]] UpPush up_push;

float3 upTap(float2 uv, float2 offset) {
    return sampleTextureLod(up_push.source_texture, up_push.frame.sampler_linear_clamp, uv + offset * up_push.source_texel, 0.0).rgb;
}

[shader("fragment")]
float4 upMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    float3 color = upTap(in_uv, float2(0, 0)) * 4.0;
    color += (upTap(in_uv, float2(-1, 0)) + upTap(in_uv, float2(1, 0)) + upTap(in_uv, float2(0, -1)) + upTap(in_uv, float2(0, 1))) * 2.0;
    color += upTap(in_uv, float2(-1, -1)) + upTap(in_uv, float2(1, -1)) + upTap(in_uv, float2(-1, 1)) + upTap(in_uv, float2(1, 1));
    return float4(color / 16.0, 1.0);
}
