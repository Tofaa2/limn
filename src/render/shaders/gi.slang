#ifndef GI_SLANG
#define GI_SLANG
#include "common.slang"

static const int GI_IRRADIANCE_TEXELS = 8;
static const int GI_VISIBILITY_TEXELS = 16;

struct GiGrid {
    float3 origin;
    float spacing;
    int3 counts;
    uint irradiance;
    uint visibility;
    int3 scroll;
    uint offsets;
    uint nearest;
};

int3 giUnpackScroll(uint packed) {
    return int3(packed & 1023u, (packed >> 10) & 1023u, (packed >> 20) & 1023u);
}

GiGrid giGrid(FrameConstants frame, uint index) {
    GiCascade cascade = frame.gi_cascades[index];
    GiGrid grid;
    grid.nearest = frame.sampler_nearest_clamp;
    grid.origin = cascade.origin;
    grid.spacing = cascade.spacing;
    grid.counts = cascade.counts;
    grid.irradiance = cascade.irradiance;
    grid.visibility = cascade.visibility;
    grid.scroll = giUnpackScroll(cascade.scroll);
    grid.offsets = cascade.offsets;
    return grid;
}

int3 giProbeCoord(int index, int3 counts) {
    return int3(index % counts.x, (index / counts.x) % counts.y, index / (counts.x * counts.y));
}

int3 giStorageCoord(GiGrid grid, int3 coord) {
    return (coord + grid.scroll) % grid.counts;
}

int3 giGridCoord(GiGrid grid, int3 storage) {
    return (storage - grid.scroll + grid.counts) % grid.counts;
}

float3 giProbeGridPosition(GiGrid grid, int3 coord) {
    return grid.origin + float3(coord) * grid.spacing;
}

float giProbeMark(GiGrid grid, float3 grid_position) {
    return frac(dot(round(grid_position / grid.spacing), float3(0.3731, 0.6113, 0.8297)));
}

float3 giProbeOffset(GiGrid grid, int3 coord, float3 grid_position) {
    if ((SHADE_FEATURES & FEATURE_GI_RELOCATION) == 0u || grid.offsets == INVALID_ID) return float3(0.0);
    int3 storage = giStorageCoord(grid, coord);
    float4 moved = fetchTexel(grid.offsets, int2(storage.x + storage.z * grid.counts.x, storage.y));
    float apart = abs(moved.w - giProbeMark(grid, grid_position));
    return min(apart, 1.0 - apart) < 0.004 ? moved.xyz : float3(0.0);
}

float3 giProbePosition(GiGrid grid, int3 coord) {
    float3 grid_position = giProbeGridPosition(grid, coord);
    return grid_position + giProbeOffset(grid, coord, grid_position);
}

float2 giProbeUv(int3 coord, float3 direction, int texels, int3 counts) {
    float2 tile = float2(coord.x + coord.z * counts.x, coord.y);
    float2 inner = encodeNormal(direction) * float(texels - 2) + 1.0;
    return (tile * float(texels) + inner) / (float2(counts.x * counts.z, counts.y) * float(texels));
}

bool giProbeDue(FrameConstants frame, float3 position, uint probe, uint turn, float far_distance) {
    if (far_distance <= 0.0 || distance(position, eyePoint(frame, position)) < far_distance) return true;
    return (turn + probe) % 8u == 0u;
}

float giGridCoverage(GiGrid grid, float3 position) {
    float3 extent = float3(grid.counts - 1) * grid.spacing;
    float3 outside = max(grid.origin - position, position - (grid.origin + extent));
    float distance_outside = max(outside.x, max(outside.y, outside.z));
    return clamp(1.0 - distance_outside / grid.spacing, 0.0, 1.0);
}

float giNestedCoverage(GiGrid grid, float3 position) {
    float3 half_extent = 0.5 * float3(grid.counts - 1) * grid.spacing;
    float3 inside = (half_extent - abs(position - (grid.origin + half_extent))) / max(half_extent * 0.25, float3(grid.spacing));
    return clamp(min(inside.x, min(inside.y, inside.z)), 0.0, 1.0);
}

float giCoverage(FrameConstants frame, float3 position) {
    uint last = max(frame.gi_cascade_count, 1u) - 1u;
    float covered = 0.0;
    float rest = 1.0;
    for (uint i = 0u; i < last && rest > 0.0; i++) {
        float inside = giNestedCoverage(giGrid(frame, i), position);
        covered += rest * inside;
        rest *= 1.0 - inside;
    }
    return covered + rest * giGridCoverage(giGrid(frame, last), position);
}

float3 giGridIrradiance(FrameConstants frame, GiGrid grid, float3 position, float3 normal, float3 view) {
    int3 counts = grid.counts;
    uint s = frame.sampler_linear_clamp;
    float3 cell = (position - grid.origin) / grid.spacing;
    int3 base = clamp(int3(floor(cell)), int3(0), counts - 2);
    float3 alpha = clamp(cell - float3(base), 0.0, 1.0);
    float3 biased = position + (normal * 0.2 + view * 0.8) * (0.3 * grid.spacing);

    float3 total = float3(0.0);
    float weight_total = 0.0;
    for (int i = 0; i < 8; i++) {
        int3 offset = int3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        int3 coord = base + offset;
        int3 stored = giStorageCoord(grid, coord);
        float3 probe = giProbePosition(grid, coord);
        float3 trilinear = lerp(1.0 - alpha, alpha, float3(offset));
        float weight = trilinear.x * trilinear.y * trilinear.z;

        float3 to_probe = normalize(probe - position);
        float facing = (dot(to_probe, normal) + 1.0) * 0.5;
        weight *= facing * facing + 0.2;

        float3 from_probe = biased - probe;
        float distance_to_probe = length(from_probe);
        float2 moments = sampleTextureLod(grid.visibility, s, giProbeUv(stored, from_probe / distance_to_probe, GI_VISIBILITY_TEXELS, counts), 0.0).rg;
        if (distance_to_probe > moments.x) {
            float variance = abs(moments.x * moments.x - moments.y);
            float delta = distance_to_probe - moments.x;
            float chebyshev = variance / (variance + delta * delta);
            weight *= max(chebyshev * chebyshev * chebyshev, 0.0);
        }
        weight = max(weight, 1e-6);
        const float threshold = 0.2;
        if (weight < threshold) weight *= weight * weight / (threshold * threshold);

        float3 irradiance = sampleTextureLod(grid.irradiance, s, giProbeUv(stored, normal, GI_IRRADIANCE_TEXELS, counts), 0.0).rgb;
        total += irradiance * weight;
        weight_total += weight;
    }
    return total / weight_total;
}

float3 giIrradiance(FrameConstants frame, float3 position, float3 normal, float3 view) {
    uint last = max(frame.gi_cascade_count, 1u) - 1u;
    float3 result = float3(0.0);
    float rest = 1.0;
    for (uint i = 0u; i < last && rest > 0.0; i++) {
        GiGrid grid = giGrid(frame, i);
        float inside = giNestedCoverage(grid, position);
        if (inside > 0.0) result += giGridIrradiance(frame, grid, position, normal, view) * (rest * inside);
        rest *= 1.0 - inside;
    }
    if (rest > 0.0) result += giGridIrradiance(frame, giGrid(frame, last), position, normal, view) * rest;
    return result;
}

float3 giGridAmbient(FrameConstants frame, GiGrid grid, float3 position) {
    int3 counts = grid.counts;
    uint s = frame.sampler_linear_clamp;
    float3 cell = (position - grid.origin) / grid.spacing;
    int3 base = clamp(int3(floor(cell)), int3(0), counts - 2);
    float3 alpha = clamp(cell - float3(base), 0.0, 1.0);
    float3 total = float3(0.0);
    for (int i = 0; i < 8; i++) {
        int3 offset = int3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        int3 stored = giStorageCoord(grid, base + offset);
        float3 trilinear = lerp(1.0 - alpha, alpha, float3(offset));
        float3 up = sampleTextureLod(grid.irradiance, s, giProbeUv(stored, float3(0.0, 1.0, 0.0), GI_IRRADIANCE_TEXELS, counts), 0.0).rgb;
        float3 down = sampleTextureLod(grid.irradiance, s, giProbeUv(stored, float3(0.0, -1.0, 0.0), GI_IRRADIANCE_TEXELS, counts), 0.0).rgb;
        total += 0.5 * (up + down) * (trilinear.x * trilinear.y * trilinear.z);
    }
    return total;
}

float3 giAmbient(FrameConstants frame, float3 position) {
    uint last = max(frame.gi_cascade_count, 1u) - 1u;
    float3 result = float3(0.0);
    float rest = 1.0;
    for (uint i = 0u; i < last && rest > 0.0; i++) {
        GiGrid grid = giGrid(frame, i);
        float inside = giNestedCoverage(grid, position);
        if (inside > 0.0) result += giGridAmbient(frame, grid, position) * (rest * inside);
        rest *= 1.0 - inside;
    }
    if (rest > 0.0) result += giGridAmbient(frame, giGrid(frame, last), position) * rest;
    return result;
}

#endif
