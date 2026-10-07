#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    mat4 node;
    vec3 center;
    float radius;
    vec3 right;
    uint vertex_offset;
    vec3 up;
    uint material;
    vec3 toward;
    float pad;
} push;

layout(location = 0) in vec3 in_normal;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_vertex_color;

// Unlit base color; alpha is coverage.
layout(location = 0) out vec4 out_color;
// Model-space normal, as 0..1.
layout(location = 1) out vec4 out_normal;

void main() {
    Material material = push.frame.materials.data[push.material];
    vec4 color = material.base_color * in_vertex_color;
    if (material.base_color_texture != INVALID_ID)
        color *= texture(TEX(material.base_color_texture, material.sampler_index), materialUv(material, in_uv));
    if ((material.flags & MATERIAL_ALPHA_TEST) != 0u && color.a < material.alpha_cutoff) discard;
    vec3 normal = normalize(in_normal);
    if (!gl_FrontFacing) normal = -normal;
    out_color = vec4(color.rgb, 1.0);
    out_normal = vec4(normal * 0.5 + 0.5, 1.0);
}
