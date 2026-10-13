#version 460
#include "common.glsl"
#include "gi.glsl"

layout(buffer_reference, scalar) readonly buffer Rays { vec4 data[]; };
layout(buffer_reference, scalar) readonly buffer Directions { vec4 data[]; };

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    Rays rays;
    Directions directions;
    uint rays_per_probe;
    float hysteresis;
    float max_distance;
    uint probe_stride;
    uint probe_phase;
    float fast_hysteresis;
    ivec3 shift;
    uint grid_index;
    float far_distance;
    uint turn;
    vec3 axis;
    float axis_pad;
} push;

layout(location = 0) out vec4 out_value;
#ifndef VISIBILITY
layout(location = 1) out vec4 out_fast;
#endif

#ifdef VISIBILITY
const int texels = GI_VISIBILITY_TEXELS;
/// Rays further off a texel's direction than this weigh under a thousandth
/// of one along it and are not read.
const float least_cosine = 0.87;
/// How far along `Push.axis` a ray that near can be from the texel. Rays
/// are ordered by how far along the axis they point, the first furthest, so
/// only a run of them needs visiting.
const float reach_along = 0.51;
#else
const int texels = GI_IRRADIANCE_TEXELS;
const float least_cosine = 0.0;
#endif


ivec2 interiorTexel(ivec2 t) {
    int last = texels - 1;
    bool border_x = t.x == 0 || t.x == last;
    bool border_y = t.y == 0 || t.y == last;
    if (border_x && border_y) return ivec2(t.x == 0 ? last - 1 : 1, t.y == 0 ? last - 1 : 1);
    if (border_x) return ivec2(t.x == 0 ? 1 : last - 1, last - t.y);
    if (border_y) return ivec2(last - t.x, t.y == 0 ? 1 : last - 1);
    return t;
}

/// Blends this frame's rays into the probes that were traced. A probe the
/// grid has just moved onto starts from what the next coarser grid holds
/// there, with nothing in its way, and is traced when its turn comes.
void main() {
    FrameConstants frame = push.frame;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    ivec2 tile = pixel / texels;
    GiGrid probe_grid = giGrid(frame, push.grid_index);
    ivec3 counts = probe_grid.counts;
    int probe = tile.x % counts.x + tile.y * counts.x + (tile.x / counts.x) * counts.x * counts.y;
    ivec3 grid = giGridCoord(probe_grid, ivec3(tile.x % counts.x, tile.y, tile.x / counts.x));
    bool fresh = false;
    for (int axis = 0; axis < 3; axis++) {
        int moved = push.shift[axis];
        if (moved > 0 && grid[axis] >= counts[axis] - moved) fresh = true;
        if (moved < 0 && grid[axis] < -moved) fresh = true;
    }
    bool seeded = fresh && push.grid_index + 1u < frame.gi_cascade_count;
    bool due = uint(probe) % push.probe_stride == push.probe_phase &&
        giProbeDue(frame, giProbePosition(probe_grid, grid), uint(probe), push.turn, push.far_distance);
    if (!seeded && !due) discard;
    ivec2 local = interiorTexel(pixel - tile * texels);
    vec3 direction = decodeNormal((vec2(local) - 0.5) / float(texels - 2));
    if (seeded) {
#ifdef VISIBILITY
        out_value = vec4(push.max_distance, push.max_distance * push.max_distance, 0.0, 1.0);
#else
        vec3 around = giGridIrradiance(frame, giGrid(frame, push.grid_index + 1u), giProbeGridPosition(probe_grid, grid), direction, direction);
        out_value = vec4(around, 1.0);
        out_fast = vec4(around, 1.0);
#endif
        return;
    }

    vec3 total = vec3(0.0);
    float weight_total = 0.0;
    uint first = uint(probe) * push.rays_per_probe;
    uint from = 0u;
    uint to = push.rays_per_probe;
#ifdef VISIBILITY
    float along = dot(direction, push.axis);
    float half_count = 0.5 * float(push.rays_per_probe);
    from = uint(clamp(floor((1.0 - along - reach_along) * half_count), 0.0, float(push.rays_per_probe)));
    to = uint(clamp(ceil((1.0 - along + reach_along) * half_count), 0.0, float(push.rays_per_probe)));
#endif
    for (uint i = from; i < to; i++) {
        float weight = dot(direction, push.directions.data[i].xyz);
        if (weight <= least_cosine) continue;
        vec4 ray = push.rays.data[first + i];
#ifdef VISIBILITY
        float squared = weight * weight;
        float sixteenth = squared * squared;
        sixteenth *= sixteenth;
        sixteenth *= sixteenth;
        weight = sixteenth * sixteenth * sixteenth * squared;
        float distance = min(abs(ray.a), push.max_distance);
        total.rg += vec2(distance, distance * distance) * weight;
#else
        total += ray.rgb * weight;
#endif
        weight_total += weight;
    }
    out_value = vec4(total / max(weight_total, 1e-5), fresh ? 1.0 : 1.0 - push.hysteresis);
#ifndef VISIBILITY
    out_fast = vec4(out_value.rgb, fresh ? 1.0 : 1.0 - push.fast_hysteresis);
#endif
}
