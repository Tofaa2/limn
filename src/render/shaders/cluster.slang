#include "common.slang"

#include "cluster.Push.slang"

[[vk::push_constant]] Push push;

[shader("compute")]
[numthreads(64, 1, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    uint index = id.x;
    if (index >= CLUSTERS_X * CLUSTERS_Y * CLUSTERS_Z) return;
    FrameConstants frame = push.frame;
    uint3 cell = uint3(index % CLUSTERS_X, (index / CLUSTERS_X) % CLUSTERS_Y, index / (CLUSTERS_X * CLUSTERS_Y));

    float z0 = push.z_near * pow(push.z_ratio, float(cell.z));
    float z1 = z0 * push.z_ratio;
    if (cell.z == 0u) z0 = 0.0;
    if (cell.z == CLUSTERS_Z - 1u) z1 = 1e30;
    float2 ndc0 = float2(cell.xy) / float2(CLUSTERS_X, CLUSTERS_Y) * 2.0 - 1.0;
    float2 ndc1 = float2(cell.xy + 1u) / float2(CLUSTERS_X, CLUSTERS_Y) * 2.0 - 1.0;
    bool parallel = frame.parallel != 0.0;
    float2 off_axis = parallel ? -float2(frame.proj[0][3], frame.proj[1][3]) : float2(frame.proj[0][2], frame.proj[1][2]);
    float2 slope0 = (ndc0 + off_axis) / float2(frame.proj[0][0], frame.proj[1][1]);
    float2 slope1 = (ndc1 + off_axis) / float2(frame.proj[0][0], frame.proj[1][1]);
    float2 slope_min = min(slope0, slope1);
    float2 slope_max = max(slope0, slope1);
    Cluster* cluster = frame.lights.clusters.data + index;

    uint count = 0u;
    for (uint i = 0u; i < frame.lights.light_count && count < CLUSTER_CAPACITY; i++) {
        Light light = frame.lights.lights.data[i];
        float3 center = mul(frame.view, float4(light.position, 1.0)).xyz;
        float depth = -center.z;
        if ((light.flags & LIGHT_DIRECTIONAL) != 0u) {
            cluster.lights[count] = i;
            count++;
            continue;
        }
        if (depth + light.range < z0 || depth - light.range > z1) continue;
        float z = clamp(depth, max(z0, 1e-4), max(min(z1, depth + light.range), 1e-4));
        float spread = parallel ? 1.0 : z;
        float3 closest = float3(clamp(center.xy, slope_min * spread, slope_max * spread), -z);
        float slack = parallel ? 0.0 : light.range * max(max(abs(slope_min.x), abs(slope_max.x)), max(abs(slope_min.y), abs(slope_max.y)));
        float3 delta = closest - center;
        if (dot(delta, delta) > (light.range + slack) * (light.range + slack)) continue;
        cluster.lights[count] = i;
        count++;
    }
    cluster.count = count;

    uint masks[CLUSTER_DECAL_WORDS];
    for (uint word = 0u; word < CLUSTER_DECAL_WORDS; word++) masks[word] = 0u;
    for (uint i = 0u; i < min(frame.shading.decal_count, CLUSTER_DECAL_WORDS * 32u); i++) {
        float4 bounds = frame.shading.decals.data[i].bounds;
        float3 center = mul(frame.view, float4(bounds.xyz, 1.0)).xyz;
        float depth = -center.z;
        if (depth + bounds.w < z0 || depth - bounds.w > z1) continue;
        float z = clamp(depth, max(z0, 1e-4), max(min(z1, depth + bounds.w), 1e-4));
        float spread = parallel ? 1.0 : z;
        float3 closest = float3(clamp(center.xy, slope_min * spread, slope_max * spread), -z);
        float slack = parallel ? 0.0 : bounds.w * max(max(abs(slope_min.x), abs(slope_max.x)), max(abs(slope_min.y), abs(slope_max.y)));
        float3 delta = closest - center;
        if (dot(delta, delta) > (bounds.w + slack) * (bounds.w + slack)) continue;
        masks[i >> 5u] |= 1u << (i & 31u);
    }
    for (uint word = 0u; word < CLUSTER_DECAL_WORDS; word++) cluster.decals[word] = masks[word];
}
