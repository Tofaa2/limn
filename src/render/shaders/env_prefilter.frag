#version 460
#include "common.glsl"
#include "brdf.glsl"
#include "environment.glsl"

layout(push_constant, scalar) uniform Push {
    uint source_texture;
    uint sampler_index;
    uint face;
    float source_size;
    float roughness;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = cubeDirection(push.face, in_uv);
    if (push.roughness <= 0.0) {
        out_color = vec4(textureLod(TEX_CUBE(push.source_texture, push.sampler_index), n, 0.0).rgb, 1.0);
        return;
    }
    mat3 basis = tangentBasis(n);
    float alpha = push.roughness * push.roughness;
    const uint sample_count = 256u;
    vec3 total = vec3(0.0);
    float weight_total = 0.0;
    for (uint i = 0u; i < sample_count; i++) {
        vec3 h = basis * importanceSampleGgx(hammersley(i, sample_count), alpha);
        vec3 l = reflect(-n, h);
        float n_dot_l = dot(n, l);
        if (n_dot_l <= 0.0) continue;
        float n_dot_h = max(dot(n, h), 0.0);
        float pdf = distributionGgx(n_dot_h, alpha) * 0.25;
        float sample_solid_angle = 1.0 / (float(sample_count) * pdf + 1e-4);
        float texel_solid_angle = 4.0 * PI / (6.0 * push.source_size * push.source_size);
        float mip = max(0.5 * log2(sample_solid_angle / texel_solid_angle) + 1.0, 0.0);
        total += textureLod(TEX_CUBE(push.source_texture, push.sampler_index), l, mip).rgb * n_dot_l;
        weight_total += n_dot_l;
    }
    out_color = vec4(total / max(weight_total, 1e-4), 1.0);
}
