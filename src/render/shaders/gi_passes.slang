#include "ray_light.slang"
#include "gi.slang"
#include "common.slang"

#include "gi_passes.TracePush.slang"

[[vk::push_constant]] TracePush trace_push;

[shader("compute")]
[numthreads(64, 1, 1)]
void traceMain(uint3 id : SV_DispatchThreadID) {
    uint index = id.x;
    uint probe = (index / trace_push.rays_per_probe) * trace_push.probe_stride + trace_push.probe_phase;
    if (probe >= trace_push.probe_count) return;
    FrameConstants frame = trace_push.frame;
    uint ray = index % trace_push.rays_per_probe;
    uint slot = probe * trace_push.rays_per_probe + ray;
    if (trace_push.skip_buried != 0u && (frame.frame_index / max(trace_push.probe_stride, 1u) + probe) % 8u != 0u) {
        uint backs = 0u;
        uint spread = max(trace_push.rays_per_probe / 8u, 1u);
        for (uint k = 0u; k < 8u; k++) backs += uint(loadAligned<16>(trace_push.rays + probe * trace_push.rays_per_probe + min(k * spread, trace_push.rays_per_probe - 1u)).w < 0.0);
        if (backs >= 6u) return;
    }
    GiGrid grid = giGrid(frame, trace_push.grid);
    float3 origin = giProbePosition(grid, giGridCoord(grid, giProbeCoord(int(probe), grid.counts)));
    if (!giProbeDue(frame, origin, probe, trace_push.turn, trace_push.far_distance)) return;
    float3 direction = loadAligned<16>(trace_push.directions + ray).xyz;

    Tracer tracer;
    tracer.frame = frame;
    tracer.scene = trace_push.tlas;
    LitRay seen = traceLit(tracer, origin, direction, trace_push.max_distance, 3.0, trace_push.multibounce != 0u, RAY_SOLID);
    if (seen.met == RAY_MISS) {
        float3 sky = float3(0.0);
        if (frame.environment != 0u)
            sky = sampleCubeLod(frame.env_specular, frame.sampler_linear_clamp, direction, 2.0).rgb * frame.env_intensity;
        storeAligned<16>(trace_push.rays + slot, float4(throughFluids(frame, origin, direction, trace_push.max_distance, sky), trace_push.max_distance));
    } else if (seen.met == RAY_BACK) {
        storeAligned<16>(trace_push.rays + slot, float4(0.0, 0.0, 0.0, -0.2 * seen.distance));
    } else {
        storeAligned<16>(trace_push.rays + slot, float4(throughFluids(frame, origin, direction, seen.distance, seen.radiance), seen.distance));
    }
}

#include "gi_passes.UpdatePush.slang"
#include "gi_passes.RelocatePush.slang"

[[vk::push_constant]] RelocatePush relocate_push;

[shader("fragment")]
float4 relocateMain(float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = relocate_push.update.frame;
    int2 pixel = int2(fragment.xy);
    GiGrid grid = giGrid(frame, relocate_push.update.grid_index);
    int3 counts = grid.counts;
    int3 storage = int3(pixel.x % counts.x, pixel.y, pixel.x / counts.x);
    int probe = storage.x + storage.y * counts.x + storage.z * counts.x * counts.y;
    float3 grid_position = giProbeGridPosition(grid, giGridCoord(grid, storage));
    float mark = giProbeMark(grid, grid_position);

    float4 before = fetchTexel(relocate_push.previous_offsets, pixel);
    float apart = abs(before.w - mark);
    float3 offset = min(apart, 1.0 - apart) < 0.004 ? before.xyz : float3(0.0);
    if (uint(probe) % relocate_push.update.probe_stride != relocate_push.update.probe_phase) return float4(offset, mark);

    float count = float(relocate_push.update.rays_per_probe);
    float backs = 0.0;
    float nearest_back = 1e30;
    float3 nearest_back_way = float3(0.0);
    float nearest_front = 1e30;
    float3 nearest_front_way = float3(0.0);
    float farthest_front = 0.0;
    float3 farthest_front_way = float3(0.0);
    for (uint ray = 0u; ray < relocate_push.update.rays_per_probe; ray++) {
        float met = loadAligned<16>(relocate_push.update.rays + uint(probe) * relocate_push.update.rays_per_probe + ray).w;
        float3 way = loadAligned<16>(relocate_push.update.directions + ray).xyz;
        if (met < 0.0) {
            backs += 1.0;
            float distance_met = -met * 5.0;
            if (distance_met < nearest_back) {
                nearest_back = distance_met;
                nearest_back_way = way;
            }
        } else {
            if (met < nearest_front) {
                nearest_front = met;
                nearest_front_way = way;
            }
            if (met > farthest_front) {
                farthest_front = met;
                farthest_front_way = way;
            }
        }
    }

    float room = grid.spacing * 0.2;
    float3 moved = offset;
    if (backs / count > 0.25 && nearest_back < 1e29) {
        moved = offset + nearest_back_way * (nearest_back + room * 0.5);
    } else if (nearest_front < room) {
        if (dot(nearest_front_way, farthest_front_way) <= 0.0)
            moved = offset + farthest_front_way * min(farthest_front, room);
    } else if (dot(offset, offset) > 1e-8) {
        float back = min(nearest_front - room, length(offset));
        moved = offset - normalize(offset) * back;
    }
    if (all(abs(moved) < float3(grid.spacing * 0.45))) offset = moved;
    return float4(offset, mark);
}

#include "gi_passes.GatherPush.slang"

[[vk::push_constant]] GatherPush gather_push;

float3 worldAt(FrameConstants frame, float2 uv, out float depth) {
    depth = sampleTextureLod(gather_push.depth_texture, frame.sampler_nearest_clamp, uv, 0.0).r;
    return worldPositionFromDepth(uv, max(depth, 1e-7), frame.inv_view_proj);
}

[shader("fragment")]
float4 gatherMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    FrameConstants frame = gather_push.frame;
    float depth;
    float2 uv = (floor(in_uv * frame.resolution) + 0.5) * frame.inv_resolution;
    float3 position = worldAt(frame, uv, depth);
    if (depth == 0.0) return float4(0.0, 0.0, 0.0, 1e9);
    float dl, dr, du, dd;
    float3 left = worldAt(frame, uv - float2(frame.inv_resolution.x, 0.0), dl);
    float3 right = worldAt(frame, uv + float2(frame.inv_resolution.x, 0.0), dr);
    float3 up = worldAt(frame, uv - float2(0.0, frame.inv_resolution.y), du);
    float3 down = worldAt(frame, uv + float2(0.0, frame.inv_resolution.y), dd);
    float3 dx = abs(dl - depth) < abs(dr - depth) ? position - left : right - position;
    float3 dy = abs(du - depth) < abs(dd - depth) ? position - up : down - position;
    float3 view = normalize(eyePoint(frame, position) - position);
    float3 normal = normalize(cross(dx, dy));
    if (dot(normal, view) < 0.0) normal = -normal;

    return float4(giIrradiance(frame, position, normal, view) * frame.gi.gi_intensity, linearDepth(depth, frame.depth_terms));
}

#include "gi_passes.ClampPush.slang"

[[vk::push_constant]] ClampPush clamp_push;

[shader("fragment")]
float4 clampMain(float4 fragment : SV_Position) : SV_Target {
    float3 fast = fetchTexel(clamp_push.fast_texture, int2(fragment.xy)).rgb;
    return float4(max(fast * clamp_push.scale + clamp_push.offset, float3(0.0)), 1.0);
}


[[vk::push_constant]] UpdatePush update_push;

struct Output {
    float4 value : SV_Target0;
#ifndef VISIBILITY
    float4 fast : SV_Target1;
#endif
};

#ifdef VISIBILITY
static const int texels = GI_VISIBILITY_TEXELS;
/// Rays further off a texel's direction than this weigh under a thousandth
/// of one along it and are not read.
static const float least_cosine = 0.87;
/// How far along `UpdatePush.axis` a ray that near can be from the texel. Rays
/// are ordered by how far along the axis they point, the first furthest, so
/// only a run of them needs visiting.
static const float reach_along = 0.51;
#else
static const int texels = GI_IRRADIANCE_TEXELS;
static const float least_cosine = 0.0;
#endif

int2 interiorTexel(int2 t) {
    int last = texels - 1;
    bool border_x = t.x == 0 || t.x == last;
    bool border_y = t.y == 0 || t.y == last;
    if (border_x && border_y) return int2(t.x == 0 ? last - 1 : 1, t.y == 0 ? last - 1 : 1);
    if (border_x) return int2(t.x == 0 ? 1 : last - 1, last - t.y);
    if (border_y) return int2(last - t.x, t.y == 0 ? 1 : last - 1);
    return t;
}

/// Blends this frame's rays into the probes that were traced. A probe the
/// grid has just moved onto starts from what the next coarser grid holds
/// there, with nothing in its way, and is traced when its turn comes.
[shader("fragment")]
Output updateMain(float4 fragment : SV_Position) {
    FrameConstants frame = update_push.frame;
    int2 pixel = int2(fragment.xy);
    int2 tile = pixel / texels;
    GiGrid probe_grid = giGrid(frame, update_push.grid_index);
    int3 counts = probe_grid.counts;
    int probe = tile.x % counts.x + tile.y * counts.x + (tile.x / counts.x) * counts.x * counts.y;
    int3 grid = giGridCoord(probe_grid, int3(tile.x % counts.x, tile.y, tile.x / counts.x));
    bool fresh = false;
    for (int axis = 0; axis < 3; axis++) {
        int moved = update_push.shift[axis];
        if (moved > 0 && grid[axis] >= counts[axis] - moved) fresh = true;
        if (moved < 0 && grid[axis] < -moved) fresh = true;
    }
    bool seeded = fresh && update_push.grid_index + 1u < frame.gi.gi_cascade_count;
    bool due = uint(probe) % update_push.probe_stride == update_push.probe_phase &&
        giProbeDue(frame, giProbePosition(probe_grid, grid), uint(probe), update_push.turn, update_push.far_distance);
    if (!seeded && !due) discard;
    int2 local = interiorTexel(pixel - tile * texels);
    float3 direction = decodeNormal((float2(local) - 0.5) / float(texels - 2));
    Output result;
    if (seeded) {
#ifdef VISIBILITY
        result.value = float4(update_push.max_distance, update_push.max_distance * update_push.max_distance, 0.0, 1.0);
#else
        float3 around = giGridIrradiance(frame, giGrid(frame, update_push.grid_index + 1u), giProbeGridPosition(probe_grid, grid), direction, direction);
        result.value = float4(around, 1.0);
        result.fast = float4(around, 1.0);
#endif
        return result;
    }

    float3 total = float3(0.0);
    float weight_total = 0.0;
    uint first = uint(probe) * update_push.rays_per_probe;
    uint from = 0u;
    uint to = update_push.rays_per_probe;
#ifdef VISIBILITY
    float along = dot(direction, update_push.axis);
    float half_count = 0.5 * float(update_push.rays_per_probe);
    from = uint(clamp(floor((1.0 - along - reach_along) * half_count), 0.0, float(update_push.rays_per_probe)));
    to = uint(clamp(ceil((1.0 - along + reach_along) * half_count), 0.0, float(update_push.rays_per_probe)));
#endif
    for (uint i = from; i < to; i++) {
        float weight = dot(direction, loadAligned<16>(update_push.directions + i).xyz);
        if (weight <= least_cosine) continue;
        float4 ray = loadAligned<16>(update_push.rays + first + i);
#ifdef VISIBILITY
        float squared = weight * weight;
        float sixteenth = squared * squared;
        sixteenth *= sixteenth;
        sixteenth *= sixteenth;
        weight = sixteenth * sixteenth * sixteenth * squared;
        float distance = min(abs(ray.a), update_push.max_distance);
        total.rg += float2(distance, distance * distance) * weight;
#else
        total += ray.rgb * weight;
#endif
        weight_total += weight;
    }
    result.value = float4(total / max(weight_total, 1e-5), fresh ? 1.0 : 1.0 - update_push.hysteresis);
#ifndef VISIBILITY
    result.fast = float4(result.value.rgb, fresh ? 1.0 : 1.0 - update_push.fast_hysteresis);
#endif
    return result;
}
