#version 460
#include "common.glsl"
#include "brdf.glsl"

// Split-sum DFG lookup: x = N.V, y = perceptual roughness.
layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    float n_dot_v = max(in_uv.x, 1e-3);
    float alpha = in_uv.y * in_uv.y;
    vec3 v = vec3(sqrt(1.0 - n_dot_v * n_dot_v), 0.0, n_dot_v);
    const uint sample_count = 512u;
    vec2 total = vec2(0.0);
    for (uint i = 0u; i < sample_count; i++) {
        vec3 h = importanceSampleGgx(hammersley(i, sample_count), max(alpha, 1e-4));
        vec3 l = reflect(-v, h);
        float n_dot_l = clamp(l.z, 0.0, 1.0);
        float n_dot_h = clamp(h.z, 0.0, 1.0);
        float v_dot_h = clamp(dot(v, h), 0.0, 1.0);
        if (n_dot_l <= 0.0) continue;
        float visibility = visibilitySmithGgx(n_dot_l, n_dot_v, max(alpha, 1e-4)) * 4.0 * v_dot_h * n_dot_l / max(n_dot_h, 1e-5);
        float fresnel = pow(1.0 - v_dot_h, 5.0);
        total += vec2((1.0 - fresnel) * visibility, fresnel * visibility);
    }
    out_color = vec4(total / float(sample_count), 0.0, 1.0);
}
