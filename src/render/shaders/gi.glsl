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
    if (index == 0u)
        return GiGrid(frame.gi_origin, frame.gi_spacing, frame.gi_counts, frame.gi_irradiance, frame.gi_visibility, giUnpackScroll(frame.gi_scroll), frame.gi_offsets, frame.sampler_nearest_clamp);
    if (index == 2u)
        return GiGrid(frame.gi3_origin, frame.gi3_spacing, frame.gi3_counts, frame.gi3_irradiance, frame.gi3_visibility, giUnpackScroll(frame.gi3_scroll), frame.gi3_offsets, frame.sampler_nearest_clamp);
    return GiGrid(frame.gi2_origin, frame.gi2_spacing, frame.gi2_counts, frame.gi2_irradiance, frame.gi2_visibility, giUnpackScroll(frame.gi2_scroll), frame.gi2_offsets, frame.sampler_nearest_clamp);
}

bool giHasMiddle(FrameConstants frame) {
    return frame.gi3_irradiance != INVALID_ID;
}

bool giHasCoarse(FrameConstants frame) {
    return frame.gi2_irradiance != INVALID_ID;
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
    if (far_distance <= 0.0 || distance(position, frame.camera_position) < far_distance) return true;
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
    if (!giHasCoarse(frame)) return giGridCoverage(giGrid(frame, 0u), position);
    float main_coverage = giNestedCoverage(giGrid(frame, 0u), position);
    if (main_coverage >= 1.0) return main_coverage;
    float rest = 1.0 - main_coverage;
    if (giHasMiddle(frame)) {
        float middle = giNestedCoverage(giGrid(frame, 2u), position);
        main_coverage += rest * middle;
        rest *= 1.0 - middle;
    }
    return main_coverage + rest * giGridCoverage(giGrid(frame, 1u), position);
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
    GiGrid main_grid = giGrid(frame, 0u);
    if (!giHasCoarse(frame)) return giGridIrradiance(frame, main_grid, position, normal, view);
    float main_coverage = giNestedCoverage(main_grid, position);
    vec3 result = vec3(0.0);
    if (main_coverage > 0.0) result = giGridIrradiance(frame, main_grid, position, normal, view) * main_coverage;
    float rest = 1.0 - main_coverage;
    if (rest > 0.0 && giHasMiddle(frame)) {
        GiGrid middle_grid = giGrid(frame, 2u);
        float middle = giNestedCoverage(middle_grid, position);
        if (middle > 0.0) result += giGridIrradiance(frame, middle_grid, position, normal, view) * (rest * middle);
        rest *= 1.0 - middle;
    }
    if (rest > 0.0) result += giGridIrradiance(frame, giGrid(frame, 1u), position, normal, view) * rest;
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
    GiGrid main_grid = giGrid(frame, 0u);
    if (!giHasCoarse(frame)) return giGridAmbient(frame, main_grid, position);
    float main_coverage = giNestedCoverage(main_grid, position);
    vec3 result = vec3(0.0);
    if (main_coverage > 0.0) result = giGridAmbient(frame, main_grid, position) * main_coverage;
    float rest = 1.0 - main_coverage;
    if (rest > 0.0 && giHasMiddle(frame)) {
        GiGrid middle_grid = giGrid(frame, 2u);
        float middle = giNestedCoverage(middle_grid, position);
        if (middle > 0.0) result += giGridAmbient(frame, middle_grid, position) * (rest * middle);
        rest *= 1.0 - middle;
    }
    if (rest > 0.0) result += giGridAmbient(frame, giGrid(frame, 1u), position) * rest;
    return result;
}

#endif
