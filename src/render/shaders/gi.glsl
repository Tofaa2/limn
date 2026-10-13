#ifndef GI_GLSL
#define GI_GLSL

const int GI_IRRADIANCE_TEXELS = 8;
const int GI_VISIBILITY_TEXELS = 16;

struct GiGrid {
    vec3 origin;
    float spacing;
    ivec3 counts;
    uint irradiance;
    uint visibility;
    ivec3 scroll;
    uint offsets;
    uint nearest;
};

ivec3 giUnpackScroll(uint packed) {
    return ivec3(packed & 1023u, (packed >> 10) & 1023u, (packed >> 20) & 1023u);
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

ivec3 giProbeCoord(int index, ivec3 counts) {
    return ivec3(index % counts.x, (index / counts.x) % counts.y, index / (counts.x * counts.y));
}

ivec3 giStorageCoord(GiGrid grid, ivec3 coord) {
    return (coord + grid.scroll) % grid.counts;
}

ivec3 giGridCoord(GiGrid grid, ivec3 storage) {
    return (storage - grid.scroll + grid.counts) % grid.counts;
}

vec3 giProbeGridPosition(GiGrid grid, ivec3 coord) {
    return grid.origin + vec3(coord) * grid.spacing;
}

float giProbeMark(GiGrid grid, vec3 grid_position) {
    return fract(dot(round(grid_position / grid.spacing), vec3(0.3731, 0.6113, 0.8297)));
}

vec3 giProbeOffset(GiGrid grid, ivec3 coord, vec3 grid_position) {
    if ((SHADE_FEATURES & FEATURE_GI_RELOCATION) == 0u || grid.offsets == INVALID_ID) return vec3(0.0);
    ivec3 storage = giStorageCoord(grid, coord);
    vec4 moved = texelFetch(TEX(grid.offsets, grid.nearest), ivec2(storage.x + storage.z * grid.counts.x, storage.y), 0);
    float apart = abs(moved.w - giProbeMark(grid, grid_position));
    return min(apart, 1.0 - apart) < 0.004 ? moved.xyz : vec3(0.0);
}

vec3 giProbePosition(GiGrid grid, ivec3 coord) {
    vec3 grid_position = giProbeGridPosition(grid, coord);
    return grid_position + giProbeOffset(grid, coord, grid_position);
}

vec2 giProbeUv(ivec3 coord, vec3 direction, int texels, ivec3 counts) {
    vec2 tile = vec2(coord.x + coord.z * counts.x, coord.y);
    vec2 inner = encodeNormal(direction) * float(texels - 2) + 1.0;
    return (tile * float(texels) + inner) / (vec2(counts.x * counts.z, counts.y) * float(texels));
}

bool giProbeDue(FrameConstants frame, vec3 position, uint probe, uint turn, float far_distance) {
    if (far_distance <= 0.0 || distance(position, eyePoint(frame, position)) < far_distance) return true;
    return (turn + probe) % 8u == 0u;
}

float giGridCoverage(GiGrid grid, vec3 position) {
    vec3 extent = vec3(grid.counts - 1) * grid.spacing;
    vec3 outside = max(grid.origin - position, position - (grid.origin + extent));
    float distance_outside = max(outside.x, max(outside.y, outside.z));
    return clamp(1.0 - distance_outside / grid.spacing, 0.0, 1.0);
}

float giNestedCoverage(GiGrid grid, vec3 position) {
    vec3 half_extent = 0.5 * vec3(grid.counts - 1) * grid.spacing;
    vec3 inside = (half_extent - abs(position - (grid.origin + half_extent))) / max(half_extent * 0.25, vec3(grid.spacing));
    return clamp(min(inside.x, min(inside.y, inside.z)), 0.0, 1.0);
}

float giCoverage(FrameConstants frame, vec3 position) {
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

vec3 giGridIrradiance(FrameConstants frame, GiGrid grid, vec3 position, vec3 normal, vec3 view) {
    ivec3 counts = grid.counts;
    uint s = frame.sampler_linear_clamp;
    vec3 cell = (position - grid.origin) / grid.spacing;
    ivec3 base = clamp(ivec3(floor(cell)), ivec3(0), counts - 2);
    vec3 alpha = clamp(cell - vec3(base), 0.0, 1.0);
    vec3 biased = position + (normal * 0.2 + view * 0.8) * (0.3 * grid.spacing);

    vec3 total = vec3(0.0);
    float weight_total = 0.0;
    for (int i = 0; i < 8; i++) {
        ivec3 offset = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        ivec3 coord = base + offset;
        ivec3 stored = giStorageCoord(grid, coord);
        vec3 probe = giProbePosition(grid, coord);
        vec3 trilinear = mix(1.0 - alpha, alpha, vec3(offset));
        float weight = trilinear.x * trilinear.y * trilinear.z;

        vec3 to_probe = normalize(probe - position);
        float facing = (dot(to_probe, normal) + 1.0) * 0.5;
        weight *= facing * facing + 0.2;

        vec3 from_probe = biased - probe;
        float distance_to_probe = length(from_probe);
        vec2 moments = textureLod(TEX(grid.visibility, s), giProbeUv(stored, from_probe / distance_to_probe, GI_VISIBILITY_TEXELS, counts), 0.0).rg;
        if (distance_to_probe > moments.x) {
            float variance = abs(moments.x * moments.x - moments.y);
            float delta = distance_to_probe - moments.x;
            float chebyshev = variance / (variance + delta * delta);
            weight *= max(chebyshev * chebyshev * chebyshev, 0.0);
        }
        weight = max(weight, 1e-6);
        const float threshold = 0.2;
        if (weight < threshold) weight *= weight * weight / (threshold * threshold);

        vec3 irradiance = textureLod(TEX(grid.irradiance, s), giProbeUv(stored, normal, GI_IRRADIANCE_TEXELS, counts), 0.0).rgb;
        total += irradiance * weight;
        weight_total += weight;
    }
    return total / weight_total;
}

vec3 giIrradiance(FrameConstants frame, vec3 position, vec3 normal, vec3 view) {
    uint last = max(frame.gi_cascade_count, 1u) - 1u;
    vec3 result = vec3(0.0);
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

vec3 giGridAmbient(FrameConstants frame, GiGrid grid, vec3 position) {
    ivec3 counts = grid.counts;
    uint s = frame.sampler_linear_clamp;
    vec3 cell = (position - grid.origin) / grid.spacing;
    ivec3 base = clamp(ivec3(floor(cell)), ivec3(0), counts - 2);
    vec3 alpha = clamp(cell - vec3(base), 0.0, 1.0);
    vec3 total = vec3(0.0);
    for (int i = 0; i < 8; i++) {
        ivec3 offset = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        ivec3 stored = giStorageCoord(grid, base + offset);
        vec3 trilinear = mix(1.0 - alpha, alpha, vec3(offset));
        vec3 up = textureLod(TEX(grid.irradiance, s), giProbeUv(stored, vec3(0.0, 1.0, 0.0), GI_IRRADIANCE_TEXELS, counts), 0.0).rgb;
        vec3 down = textureLod(TEX(grid.irradiance, s), giProbeUv(stored, vec3(0.0, -1.0, 0.0), GI_IRRADIANCE_TEXELS, counts), 0.0).rgb;
        total += 0.5 * (up + down) * (trilinear.x * trilinear.y * trilinear.z);
    }
    return total;
}

vec3 giAmbient(FrameConstants frame, vec3 position) {
    uint last = max(frame.gi_cascade_count, 1u) - 1u;
    vec3 result = vec3(0.0);
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
