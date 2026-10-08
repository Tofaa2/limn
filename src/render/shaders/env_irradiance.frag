#version 460
#include "common.glsl"
#include "brdf.glsl"
#include "environment.glsl"

layout(push_constant, scalar) uniform Push {
    uint source_texture;
    uint sampler_index;
    uint face;
    float source_size;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = cubeDirection(push.face, in_uv);
    mat3 basis = tangentBasis(n);
    const uint sample_count = 512u;
    vec3 total = vec3(0.0);
    for (uint i = 0u; i < sample_count; i++) {
        vec2 xi = hammersley(i, sample_count);
        float phi = 2.0 * PI * xi.x;
        float cos_theta = sqrt(1.0 - xi.y);
        float sin_theta = sqrt(xi.y);
        vec3 l = basis * vec3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
        float pdf = cos_theta / PI;
        float sample_solid_angle = 1.0 / (float(sample_count) * pdf + 1e-4);
        float texel_solid_angle = 4.0 * PI / (6.0 * push.source_size * push.source_size);
        float mip = max(0.5 * log2(sample_solid_angle / texel_solid_angle) + 1.0, 0.0);
        total += textureLod(TEX_CUBE(push.source_texture, push.sampler_index), l, mip).rgb;
    }
    out_color = vec4(total / float(sample_count), 1.0);
}
