#include "common.slang"

#include "tonemap.Push.slang"

[[vk::push_constant]] Push push;

float3 agxDefaultContrast(float3 x) {
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

float3 agx(float3 color) {
    const float3x3 inset = float3x3(
        0.842479062253094, 0.0423282422610123, 0.0423756549057051,
        0.0784335999999992, 0.878468636469772, 0.0784336,
        0.0792237451477643, 0.0791661274605434, 0.879142973793104);
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;
    color = mul(color, inset);
    color = clamp(log2(max(color, float3(1e-10))), min_ev, max_ev);
    color = (color - min_ev) / (max_ev - min_ev);
    return agxDefaultContrast(color);
}

float3 agxLook(float3 color) {
    const float3 slope = float3(1.0);
    const float3 power = float3(1.2);
    const float saturation = 1.25;
    color = pow(max(color * slope, float3(0.0)), power);
    float luma = luminance(color);
    return luma + saturation * (color - luma);
}

float3 agxEotf(float3 color) {
    const float3x3 outset = float3x3(
        1.19687900512017, -0.0528968517574562, -0.0529716355144438,
        -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
        -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
    color = mul(color, outset);
    return pow(max(color, float3(0.0)), float3(2.2));
}

float3 colorAt(int2 pixel) {
    return fetchTexel(push.color_texture, pixel).rgb;
}

[shader("fragment")]
float4 fragmentMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = push.frame;
    uint linear = frame.sampler_linear_clamp;
    int2 pixel = int2(fragment.xy) - push.origin;
    int2 limit = int2(textureSize(push.color_texture)) - 1;
    float3 color = colorAt(pixel);
    if (push.aberration > 0.0) {
        int2 shift = int2(round((in_uv - 0.5) * push.aberration * 0.008 * frame.resolution));
        color.r = colorAt(clamp(pixel + shift, int2(0), limit)).r;
        color.b = colorAt(clamp(pixel - shift, int2(0), limit)).b;
    }

    if (push.sharpen > 0.0) {
        float3 n = colorAt(clamp(pixel + int2(0, -1), int2(0), limit));
        float3 s = colorAt(clamp(pixel + int2(0, 1), int2(0), limit));
        float3 w = colorAt(clamp(pixel + int2(-1, 0), int2(0), limit));
        float3 e = colorAt(clamp(pixel + int2(1, 0), int2(0), limit));
        float lc = luminance(color);
        float ln = luminance(n);
        float ls = luminance(s);
        float lw = luminance(w);
        float le = luminance(e);
        float low = min(lc, min(min(ln, ls), min(lw, le)));
        float high = max(lc, max(max(ln, ls), max(lw, le)));
        float amount = sqrt(clamp(low / max(high, 1e-5), 0.0, 1.0));
        float weight = -amount * push.sharpen * 0.2;
        color = max((color + (n + s + w + e) * weight) / (1.0 + 4.0 * weight), float3(0.0));
    }

    if (push.passthrough != 0u) {
        if (push.encode_srgb == 1u) color = linearToSrgb(clamp(color, 0.0, 1.0));
        if (push.encode_srgb == 2u) color = hdr10Encode(clamp(color, 0.0, 1.0) * push.hdr_paper_white);
        return float4(color, 1.0);
    }

    float exposure = frame.exposure.data.exposure;
    float3 bloom = sampleTextureLod(push.bloom_texture, linear, in_uv, 0.0).rgb;
    color = lerp(color, bloom * push.bloom_scale, push.bloom_strength);
    if (push.flare > 0.0) {
        float2 mirrored = float2(1.0) - in_uv;
        float2 toward_center = float2(0.5) - mirrored;
        float3 flare = float3(0.0);
        for (int i = 0; i < 4; i++) {
            float2 uv = mirrored + toward_center * (float(i) * 0.55 - 0.3);
            float falloff = 1.0 - smoothstep(0.2, 0.75, length(uv - 0.5));
            float3 seen = sampleTextureLod(push.bloom_texture, linear, uv, 0.0).rgb * push.bloom_scale * exposure;
            float3 tint = i == 0 ? float3(1.0, 0.8, 0.6) : (i == 1 ? float3(0.6, 0.9, 1.0) : (i == 2 ? float3(0.9, 0.7, 1.0) : float3(0.7, 1.0, 0.8)));
            flare += max(seen - 2.0, float3(0.0)) * tint * falloff;
        }
        float2 ring = mirrored + normalize(toward_center + 1e-5) * 0.42;
        float ring_weight = pow(1.0 - smoothstep(0.0, 0.25, abs(length(toward_center) - 0.42)), 4.0);
        flare += max(sampleTextureLod(push.bloom_texture, linear, ring, 0.0).rgb * push.bloom_scale * exposure - 2.0, float3(0.0)) * ring_weight * float3(0.8, 0.9, 1.0);
        color += flare * push.flare * 0.15 / max(exposure, 1e-6);
    }
    color *= exposure * push.color_filter;

    if (push.encode_srgb == 2u) {
        float peak = max(push.hdr_peak / max(push.hdr_paper_white, 1.0), 1.0);
        color = color * (1.0 + color / (peak * peak)) / (1.0 + color);
        color *= min(peak, 2.0) * 0.5 + 0.5;
    } else {
        color = agxEotf(agxLook(agx(color)));
    }

    color = lerp(float3(luminance(color)), color, push.saturation);
    color = 0.18 * pow(max(color, float3(0.0)) / 0.18, float3(push.contrast));
    float corner = length(in_uv - 0.5) * 1.4142;
    color *= 1.0 - push.vignette * smoothstep(0.35, 1.0, corner);

    if (push.lut_texture != INVALID_ID && push.encode_srgb != 2u) {
        float3 encoded = linearToSrgb(clamp(color, 0.0, 1.0));
        float n = textureSize(push.lut_texture).y;
        float slice = encoded.b * (n - 1.0);
        float below = floor(slice);
        float2 in_slice = (encoded.rg * (n - 1.0) + 0.5) / float2(n * n, n);
        float3 a = sampleTextureLod(push.lut_texture, linear, in_slice + float2(below / n, 0.0), 0.0).rgb;
        float3 b = sampleTextureLod(push.lut_texture, linear, in_slice + float2(min(below + 1.0, n - 1.0) / n, 0.0), 0.0).rgb;
        float3 graded = srgbToLinear(lerp(a, b, slice - below));
        color = lerp(color, graded, push.lut_strength);
    }
    if (push.encode_srgb == 1u) color = linearToSrgb(clamp(color, 0.0, 1.0));
    if (push.encode_srgb == 2u) color = hdr10Encode(max(color, float3(0.0)) * push.hdr_paper_white);
    float dither = interleavedGradientNoise(float2(pixel) + 0.5, frame.frame_index) - 0.5;
    float grain = (frac(sin(dot(float2(pixel) + float(frame.frame_index % 61u) * 7.31, float2(12.9898, 78.233))) * 43758.5453) - 0.5) * push.grain * 0.12;
    grain *= 1.0 - 0.6 * clamp(luminance(color), 0.0, 1.0);
    return float4(color + grain + dither / 255.0, 1.0);
}
