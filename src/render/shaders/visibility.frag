#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
} push;

layout(location = 0) flat in uint in_id;
layout(location = 1) flat in uint in_material;
layout(location = 2) in vec2 in_uv;
layout(location = 3) flat in vec2 in_fade;

layout(location = 0) out uint out_id;

void main() {
#ifdef ALPHA_TEST
    if (in_fade.x < 1.0 || in_fade.y > 0.0) {
        float noise = interleavedGradientNoise(gl_FragCoord.xy, (push.frame.flags & FRAME_TEMPORAL) != 0u ? push.frame.frame_index : 0u);
        if (noise >= in_fade.x || noise < in_fade.y) discard;
    }
    Material material = push.frame.materials.data[in_material];
    if ((material.flags & MATERIAL_ALPHA_TEST) != 0u) {
        float alpha = material.base_color.a;
        if (material.base_color_texture != INVALID_ID)
            alpha *= texture(TEX(material.base_color_texture, material.sampler_index), materialUv(material, in_uv)).a;
        if (alpha < material.alpha_cutoff) discard;
    }
#endif
    out_id = in_id | uint(gl_PrimitiveID);
}
