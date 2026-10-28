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


/// Interference of a film `optical` nanometres of path long, as linear RGB
/// (Belcour and Barla 2017, fitted sensitivity).
float3 filmSensitivity(float optical, float3 shift) {
    float phase = 2.0 * PI * optical * 1.0e-9;
    float3 strength = float3(5.4856e-13, 4.4201e-13, 5.2481e-13);
    float3 place = float3(1.6810e+06, 1.7953e+06, 2.2084e+06);
    float3 spread = float3(4.3278e+09, 9.3046e+09, 6.6121e+09);
    float3 xyz = strength * sqrt(2.0 * PI * spread) * cos(place * phase + shift) * exp(-phase * phase * spread);
    xyz.x += 9.7470e-14 * sqrt(2.0 * PI * 4.5282e+09) * cos(2.2399e+06 * phase + shift.x) * exp(-4.5282e+09 * phase * phase);
    xyz /= 1.0685e-7;
    return float3(
        3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z,
        -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z,
        0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z);
}

/// The reflectance at normal incidence that gives, `cosine` from the
/// normal, what a thin film of index `film_ior` and `thickness` nanometres
/// over a surface of reflectance `f0` reflects (KHR_materials_iridescence).
float3 iridescentF0(float cosine, float film_ior, float thickness, float3 f0) {
    float c = clamp(cosine, 1e-4, 1.0);
    float sine_squared = (1.0 / film_ior) * (1.0 / film_ior) * (1.0 - c * c);
    if (sine_squared >= 1.0 || thickness <= 0.0) return f0;
    float inside = sqrt(1.0 - sine_squared);
    float outer = (film_ior - 1.0) / (film_ior + 1.0);
    float r12 = outer * outer + (1.0 - outer * outer) * pow(1.0 - c, 5.0);
    float t121 = 1.0 - r12;
    float phi21 = film_ior < 1.0 ? 0.0 : PI;
    float3 root = sqrt(clamp(f0, 0.0, 0.9999));
    float3 base_ior = (1.0 + root) / (1.0 - root);
    float3 inner = (base_ior - film_ior) / (base_ior + film_ior);
    float3 r1 = inner * inner;
    float3 r23 = r1 + (1.0 - r1) * pow(1.0 - inside, 5.0);
    float3 phi23 = float3(base_ior.x < film_ior ? PI : 0.0, base_ior.y < film_ior ? PI : 0.0, base_ior.z < film_ior ? PI : 0.0);
    float optical = 2.0 * film_ior * thickness * inside;
    float3 phi = phi21 + phi23;
    float3 r123 = clamp(r12 * r23, 1e-5, 0.9999);
    float3 amplitude = sqrt(r123);
    float3 rs = t121 * t121 * r23 / (1.0 - r123);
    float3 reflected = r12 + rs;
    float3 cm = rs - t121;
    for (int m = 1; m <= 2; m++) {
        cm *= amplitude;
        reflected += cm * 2.0 * filmSensitivity(float(m) * optical, float(m) * phi);
    }
    reflected = max(reflected, float3(0.0));
    float x = 1.0 - c;
    float x5 = clamp(x * x * x * x * x, 0.0, 0.9999);
    return clamp((reflected - x5) / (1.0 - x5), 0.0, 1.0);
}

#endif
