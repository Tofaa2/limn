#include "common.slang"

#include "cluster.Push.slang"

[[vk::push_constant]] Push push;

/// The view-space box of one cluster: its depth range and the slopes of its
/// sides, or their offsets under a parallel projection.
struct ClusterBounds {
    float z0;
    float z1;
    float2 slope_min;
    float2 slope_max;
    bool parallel;
};

ClusterBounds clusterBounds(FrameConstants frame, uint3 cell) {
    ClusterBounds bounds;
    bounds.z0 = push.z_near * pow(push.z_ratio, float(cell.z));
    bounds.z1 = bounds.z0 * push.z_ratio;
    if (cell.z == 0u) bounds.z0 = 0.0;
    if (cell.z == CLUSTERS_Z - 1u) bounds.z1 = 1e30;
    float2 ndc0 = float2(cell.xy) / float2(CLUSTERS_X, CLUSTERS_Y) * 2.0 - 1.0;
    float2 ndc1 = float2(cell.xy + 1u) / float2(CLUSTERS_X, CLUSTERS_Y) * 2.0 - 1.0;
    bounds.parallel = frame.parallel != 0.0;
    float2 off_axis = bounds.parallel ? -float2(frame.proj[0][3], frame.proj[1][3]) : float2(frame.proj[0][2], frame.proj[1][2]);
    float2 slope0 = (ndc0 + off_axis) / float2(frame.proj[0][0], frame.proj[1][1]);
    float2 slope1 = (ndc1 + off_axis) / float2(frame.proj[0][0], frame.proj[1][1]);
    bounds.slope_min = min(slope0, slope1);
    bounds.slope_max = max(slope0, slope1);
    return bounds;
}

/// Whether a sphere at view-space `center` reaches the cluster.
bool reaches(ClusterBounds bounds, float3 center, float range) {
    float depth = -center.z;
    if (depth + range < bounds.z0 || depth - range > bounds.z1) return false;
    float z = clamp(depth, max(bounds.z0, 1e-4), max(min(bounds.z1, depth + range), 1e-4));
    float spread = bounds.parallel ? 1.0 : z;
    float3 closest = float3(clamp(center.xy, bounds.slope_min * spread, bounds.slope_max * spread), -z);
    float slack = bounds.parallel ? 0.0 : range * max(max(abs(bounds.slope_min.x), abs(bounds.slope_max.x)), max(abs(bounds.slope_min.y), abs(bounds.slope_max.y)));
    float3 delta = closest - center;
    return dot(delta, delta) <= (range + slack) * (range + slack);
}

static const uint group_size = 64u;
static const uint most_waves = group_size;
groupshared uint wave_hits[most_waves];
groupshared uint decal_masks[CLUSTER_DECAL_WORDS];
groupshared uint list_start;

bool lightReaches(FrameConstants frame, ClusterBounds bounds, uint index) {
    if (index >= frame.lights.light_count) return false;
    Light light = frame.lights.lights.data[index];
    if ((light.flags & LIGHT_DIRECTIONAL) != 0u) return true;
    return reaches(bounds, mul(frame.view, float4(light.position, 1.0)).xyz, light.range);
}

/// How many lanes of the group before this one hit, and how many hit in all.
uint groupPrefix(bool hit, uint lane, out uint total) {
    uint wave = lane / WaveGetLaneCount();
    uint waves = (group_size + WaveGetLaneCount() - 1u) / WaveGetLaneCount();
    uint in_wave = WavePrefixCountBits(hit);
    uint wave_total = WaveActiveCountBits(hit);
    if (WaveIsFirstLane()) wave_hits[wave] = wave_total;
    GroupMemoryBarrierWithGroupSync();
    uint before = 0u;
    total = 0u;
    for (uint w = 0u; w < waves; w++) {
        if (w < wave) before += wave_hits[w];
        total += wave_hits[w];
    }
    GroupMemoryBarrierWithGroupSync();
    return before + in_wave;
}

/// One group per cluster. Its lanes test 64 lights at a time: a first round
/// counts the lights that reach the cluster, one atomic takes room for its
/// list, and a second round writes them in light order, so that shading adds
/// them up the same way every frame. Decals are kept as bits.
[shader("compute")]
[numthreads(64, 1, 1)]
void computeMain(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
    uint index = group.x;
    uint lane = thread.x;
    FrameConstants frame = push.frame;
    uint3 cell = uint3(index % CLUSTERS_X, (index / CLUSTERS_X) % CLUSTERS_Y, index / (CLUSTERS_X * CLUSTERS_Y));
    ClusterBounds bounds = clusterBounds(frame, cell);
    uint light_count = frame.lights.light_count;

    uint count = 0u;
    for (uint first = 0u; first < light_count; first += group_size) {
        uint batch;
        groupPrefix(lightReaches(frame, bounds, first + lane), lane, batch);
        count += batch;
    }
    if (lane == 0u) {
        uint start;
        InterlockedAdd(push.cursors[0], count, start);
        list_start = start;
        frame.lights.clusters.data[index].offset = min(start, push.capacity);
        frame.lights.clusters.data[index].count = start >= push.capacity ? 0u : min(count, push.capacity - start);
    }
    if (lane < CLUSTER_DECAL_WORDS) decal_masks[lane] = 0u;
    GroupMemoryBarrierWithGroupSync();
    uint start = list_start;
    uint end = min(start + count, push.capacity);
    uint written = 0u;
    for (uint first = 0u; first < light_count; first += group_size) {
        bool hit = lightReaches(frame, bounds, first + lane);
        uint batch;
        uint at = start + written + groupPrefix(hit, lane, batch);
        if (hit && at < end) frame.lights.light_indices[at] = first + lane;
        written += batch;
    }

    for (uint i = lane; i < min(frame.shading.decal_count, CLUSTER_DECAL_WORDS * 32u); i += group_size) {
        float4 decal = frame.shading.decals.data[i].bounds;
        if (reaches(bounds, mul(frame.view, float4(decal.xyz, 1.0)).xyz, decal.w)) InterlockedOr(decal_masks[i >> 5u], 1u << (i & 31u));
    }
    GroupMemoryBarrierWithGroupSync();
    if (lane < CLUSTER_DECAL_WORDS) frame.lights.clusters.data[index].decals[lane] = decal_masks[lane];
}
