#version 460
#include "common.glsl"

// Shadow tint of translucent casters for a cascade: color is multiplied in;
// alpha keeps the depth of the caster nearest the sun.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
} push;

layout(location = 1) flat in uint in_material;
layout(location = 2) in vec2 in_uv;

layout(location = 0) out vec4 out_tint;

void main() {
    Material material = push.frame.materials.data[in_material];
    if ((material.flags & MATERIAL_BLEND) == 0u) discard;
    vec4 base = material.base_color;
    if (material.base_color_texture != INVALID_ID)
        base *= texture(TEX(material.base_color_texture, material.sampler_index), materialUv(material, in_uv));
    float opacity = base.a * (1.0 - material.transmission * 0.85);
    vec3 passed = (1.0 - opacity) * mix(vec3(1.0), base.rgb, clamp(base.a + material.transmission, 0.0, 1.0));
    out_tint = vec4(passed, gl_FragCoord.z);
}
