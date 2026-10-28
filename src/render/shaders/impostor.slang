#ifndef IMPOSTOR_SLANG
#define IMPOSTOR_SLANG
#include "common.slang"

static const float impostor_frames = 8.0;

/// An instance as culling reads it.
struct StaticCull {
    float4 sphere;
    uint first_ref;
    uint ref_count;
    uint impostor;
    uint pad;
};

float2 impostorFold(float3 direction) {
    direction /= abs(direction.x) + abs(direction.y) + abs(direction.z);
    if (direction.z < 0.0) direction.xy = (1.0 - abs(direction.yx)) * float2(direction.x >= 0.0 ? 1.0 : -1.0, direction.y >= 0.0 ? 1.0 : -1.0);
    return direction.xy * 0.5 + 0.5;
}

float3 impostorUnfold(float2 place) {
    float2 e = place * 2.0 - 1.0;
    float3 direction = float3(e, 1.0 - abs(e.x) - abs(e.y));
    if (direction.z < 0.0) direction.xy = (1.0 - abs(direction.yx)) * float2(direction.x >= 0.0 ? 1.0 : -1.0, direction.y >= 0.0 ? 1.0 : -1.0);
    return normalize(direction);
}

void impostorBasis(float3 toward, out float3 right, out float3 up) {
    float3 hint = abs(toward.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    right = normalize(cross(hint, toward));
    up = cross(toward, right);
}

struct Impostor {
    float3 center;
    float radius;
    uint color_texture;
    uint normal_texture;
    float pixels;
    float pad;
};

#endif
