#ifndef BRDF_SLANG
#define BRDF_SLANG
#include "common.slang"

float distributionGgx(float n_dot_h, float alpha) {
    float a2 = alpha * alpha;
    float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

float visibilitySmithGgx(float n_dot_l, float n_dot_v, float alpha) {
    float a2 = alpha * alpha;
    float lambda_v = n_dot_l * sqrt(n_dot_v * n_dot_v * (1.0 - a2) + a2);
    float lambda_l = n_dot_v * sqrt(n_dot_l * n_dot_l * (1.0 - a2) + a2);
    return 0.5 / max(lambda_v + lambda_l, 1e-5);
}

float3 fresnelSchlick(float cos_theta, float3 f0) {
    float f = pow(1.0 - cos_theta, 5.0);
    return f0 + (1.0 - f0) * f;
}

/// Two directions across a surface and its normal.
struct TangentBasis {
    float3 side;
    float3 other;
    float3 normal;

    float3 toWorld(float3 local) {
        return side * local.x + other * local.y + normal * local.z;
    }

    float3 toLocal(float3 world) {
        return float3(dot(world, side), dot(world, other), dot(world, normal));
    }
};

TangentBasis tangentBasis(float3 n) {
    float3 up = abs(n.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    TangentBasis basis;
    basis.side = normalize(cross(up, n));
    basis.other = cross(n, basis.side);
    basis.normal = n;
    return basis;
}

float2 hammersley(uint i, uint count) {
    uint bits = (i << 16u) | (i >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float2(float(i) / float(count), float(bits) * 2.3283064365386963e-10);
}

float3 importanceSampleGgx(float2 xi, float alpha) {
    float phi = 2.0 * PI * xi.x;
    float cos_theta = sqrt((1.0 - xi.y) / (1.0 + (alpha * alpha - 1.0) * xi.y));
    float sin_theta = sqrt(max(1.0 - cos_theta * cos_theta, 0.0));
    return float3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
}

#endif
