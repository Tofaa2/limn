#include "common.slang"

#include "shadow.MaskedPush.slang"

[[vk::push_constant]] MaskedPush masked_push;

[shader("fragment")]
void maskedMain([[vk::location(1)]] nointerpolation uint in_material, [[vk::location(2)]] float2 in_uv, float4 fragment : SV_Position) {
    Material material = masked_push.frame.materials.data[in_material];
    if ((material.flags & (MATERIAL_ALPHA_TEST | MATERIAL_BLEND)) == 0u) return;
    float alpha = material.base_color.a;
    if (material.base_color_texture != INVALID_ID)
        alpha *= sampleTexture(material.base_color_texture, material.sampler_index, materialUv(material, in_uv)).a;
    if ((material.flags & MATERIAL_BLEND) != 0u) {
        if (masked_push.tinted != 0u) discard;
        float opacity = alpha * (1.0 - material.transmission * 0.85);
        if (opacity <= interleavedGradientNoise(fragment.xy + float2(float(in_material % 61u) * 5.0, float(in_material % 37u) * 3.0), 0u)) discard;
    } else if (alpha < material.alpha_cutoff) {
        discard;
    }
}

#include "shadow.ColorPush.slang"

[[vk::push_constant]] ColorPush color_push;

[shader("fragment")]
float4 colorMain([[vk::location(1)]] nointerpolation uint in_material, [[vk::location(2)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    Material material = color_push.frame.materials.data[in_material];
    if ((material.flags & MATERIAL_BLEND) == 0u) discard;
    float4 base = material.base_color;
    if (material.base_color_texture != INVALID_ID)
        base *= sampleTexture(material.base_color_texture, material.sampler_index, materialUv(material, in_uv));
    float opacity = base.a * (1.0 - material.transmission * 0.85);
    float3 passed = (1.0 - opacity) * lerp(float3(1.0), base.rgb, clamp(base.a + material.transmission, 0.0, 1.0));
    return float4(passed, fragment.z);
}
