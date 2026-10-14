#include "common.slang"

struct UpscalePush {
    FrameConstants frame;
    uint source_texture;
};

[[vk::push_constant]] UpscalePush upscale_push;

[shader("fragment")]
float4 upscaleMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    uint s = upscale_push.frame.sampler_linear_clamp;
    uint source = upscale_push.source_texture;
    float2 size = textureSize(source);
    float2 position = in_uv * size;
    float2 center = floor(position - 0.5) + 0.5;
    float2 f = position - center;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 tc0 = (center - 1.0) / size;
    float2 tc12 = (center + w2 / w12) / size;
    float2 tc3 = (center + 2.0) / size;
    float4 result =
        float4(sampleTextureLod(source, s, float2(tc12.x, tc0.y), 0.0).rgb, 1.0) * (w12.x * w0.y) +
        float4(sampleTextureLod(source, s, float2(tc0.x, tc12.y), 0.0).rgb, 1.0) * (w0.x * w12.y) +
        float4(sampleTextureLod(source, s, float2(tc12.x, tc12.y), 0.0).rgb, 1.0) * (w12.x * w12.y) +
        float4(sampleTextureLod(source, s, float2(tc3.x, tc12.y), 0.0).rgb, 1.0) * (w3.x * w12.y) +
        float4(sampleTextureLod(source, s, float2(tc12.x, tc3.y), 0.0).rgb, 1.0) * (w12.x * w3.y);
    return float4(max(result.rgb / result.a, float3(0.0)), 1.0);
}

struct EasuPush {
    FrameConstants frame;
    uint source_texture;
    uint pad;
    uint4 con0;
    uint4 con1;
    uint4 con2;
    uint4 con3;
};

[[vk::push_constant]] EasuPush easu_push;

struct RcasPush {
    FrameConstants frame;
    uint source_texture;
    uint pad;
    uint4 con;
};

[[vk::push_constant]] RcasPush rcas_push;

#pragma warning(disable : 30056)
#define A_GPU 1
#define A_HLSL 1
#include "../../third_party/ffx_fsr1/ffx_a.h"

#define FSR_EASU_F 1
#define FSR_RCAS_F 1
AF4 squeezed(AF4 channel) {
    channel = max(channel, AF4_(0.0));
    return channel / (AF4_(1.0) + channel);
}
AF4 FsrEasuRF(AF2 p) { return squeezed(textures_2d[NonUniformResourceIndex(easu_push.source_texture)].GatherRed(samplers[NonUniformResourceIndex(easu_push.frame.sampler_linear_clamp)], p)); }
AF4 FsrEasuGF(AF2 p) { return squeezed(textures_2d[NonUniformResourceIndex(easu_push.source_texture)].GatherGreen(samplers[NonUniformResourceIndex(easu_push.frame.sampler_linear_clamp)], p)); }
AF4 FsrEasuBF(AF2 p) { return squeezed(textures_2d[NonUniformResourceIndex(easu_push.source_texture)].GatherBlue(samplers[NonUniformResourceIndex(easu_push.frame.sampler_linear_clamp)], p)); }
AF4 FsrRcasLoadF(ASU2 p) { return fetchTexel(rcas_push.source_texture, p); }
void FsrRcasInputF(inout AF1 r, inout AF1 g, inout AF1 b) {}
#include "../../third_party/ffx_fsr1/ffx_fsr1.h"

[shader("fragment")]
float4 easuMain(float4 fragment : SV_Position) : SV_Target {
    AF3 color;
    FsrEasuF(color, AU2(fragment.xy), easu_push.con0, easu_push.con1, easu_push.con2, easu_push.con3);
    return float4(color, 1.0);
}

[shader("fragment")]
float4 rcasMain(float4 fragment : SV_Position) : SV_Target {
    AF1 r;
    AF1 g;
    AF1 b;
    FsrRcasF(r, g, b, AU2(fragment.xy), rcas_push.con);
    float3 color = clamp(float3(r, g, b), 0.0, 0.9999);
    return float4(color / (1.0 - color), 1.0);
}
