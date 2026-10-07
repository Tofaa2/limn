#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    // 1 when translucent casters go into the tint pass instead.
    uint tinted;
} push;

layout(location = 1) flat in uint in_material;
layout(location = 2) in vec2 in_uv;

void main() {
    Material material = push.frame.materials.data[in_material];
    if ((material.flags & (MATERIAL_ALPHA_TEST | MATERIAL_BLEND)) == 0u) return;
    float alpha = material.base_color.a;
    if (material.base_color_texture != INVALID_ID)
        alpha *= texture(TEX(material.base_color_texture, material.sampler_index), materialUv(material, in_uv)).a;
    if ((material.flags & MATERIAL_BLEND) != 0u) {
        if (push.tinted != 0u) discard;
        // Translucent casters write a dither pattern as dense as their opacity.
        float opacity = alpha * (1.0 - material.transmission * 0.85);
        // Pattern offset per material, so stacked surfaces darken together.
        if (opacity <= interleavedGradientNoise(gl_FragCoord.xy + vec2(float(in_material % 61u) * 5.0, float(in_material % 37u) * 3.0), 0u)) discard;
    } else if (alpha < material.alpha_cutoff) {
        discard;
    }
}
