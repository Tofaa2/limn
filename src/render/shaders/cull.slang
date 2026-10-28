#include "common.slang"
#include "cull_view.slang"
#include "cull_occlusion.slang"
#include "impostor.slang"

struct DrawCommand {
    uint index_count;
    uint instance_count;
    uint first_index;
    int vertex_offset;
    uint first_instance;
};

struct MeshDraw {
    uint x;
    uint y;
    uint z;
    uint pad;
};

static const uint meshlets_per_task = 32u;

#include "cull.MeshletPush.slang"

[[vk::push_constant]] MeshletPush meshlet_push;

Occlusion meshletOcclusion() {
    Occlusion occlusion = { meshlet_push.frame, meshlet_push.view, meshlet_push.hiz_texture, meshlet_push.hiz_size };
    return occlusion;
}

void markSeen(uint instance) {
    if (meshlet_push.mark_seen == 0u) return;
    uint before;
    InterlockedExchange(meshlet_push.seen[instance], 1u, before);
    if (before == 0u) InterlockedAdd(meshlet_push.seen[meshlet_push.seen_total], 1u);
}

bool shadowUnseen(float3 center, float radius) {
    radius += meshlet_push.view.receiver_margin;
    float3 travel = meshlet_push.view.light_travel;
    float from = 0.0;
    float to = 1.0e30;
    for (uint i = 0u; i < 6u; i++) {
        float4 plane = meshlet_push.view.receiver_planes[i];
        float start = dot(plane.xyz, center) + plane.w + radius;
        float change = dot(plane.xyz, travel);
        if (abs(change) < 1.0e-9) {
            if (start < 0.0) return true;
            continue;
        }
        float crossing = -start / change;
        if (change > 0.0) from = max(from, crossing);
        else to = min(to, crossing);
        if (from > to) return true;
    }
    if (meshlet_push.view.receiver_culling < 2u) return false;
    float3 a = mul(meshlet_push.view.receiver_view, float4(center + travel * from, 1.0)).xyz;
    float3 b = mul(meshlet_push.view.receiver_view, float4(center + travel * to, 1.0)).xyz;
    a.z = -a.z;
    b.z = -b.z;
    float4 box_a;
    float4 box_b;
    if (!projectSphere(meshlet_push.view, a, radius, meshlet_push.view.receiver_near, meshlet_push.view.receiver_p00, meshlet_push.view.receiver_p11, box_a)) return false;
    if (!projectSphere(meshlet_push.view, b, radius, meshlet_push.view.receiver_near, meshlet_push.view.receiver_p00, meshlet_push.view.receiver_p11, box_b)) return false;
    float2 uv_min = clamp(min(min(box_a.xy, box_a.zw), min(box_b.xy, box_b.zw)), 0.0, 1.0);
    float2 uv_max = clamp(max(max(box_a.xy, box_a.zw), max(box_b.xy, box_b.zw)), 0.0, 1.0);
    float nearest = meshlet_push.view.receiver_near / (min(a.z, b.z) - radius);
    return nearest < farthestDepth(meshletOcclusion(), uv_min, uv_max);
}

/// Lists one meshlet's draw at `at` of a view's lists, in the form
/// `mesh_lists` names: index draws, pulled draws or mesh shader references.
void writeDraw(uint mesh_lists, DrawCommand* commands, uint* lists, uint at, uint ref_index, uint index_count, uint first_index) {
    if (mesh_lists == 2u) {
        lists[at * 4u] = index_count;
        lists[at * 4u + 1u] = 1u;
        lists[at * 4u + 2u] = first_index;
        lists[at * 4u + 3u] = ref_index;
        return;
    }
    if (mesh_lists != 0u) {
        lists[at] = ref_index;
        return;
    }
    DrawCommand command;
    command.index_count = index_count;
    command.instance_count = 1u;
    command.first_index = first_index;
    command.vertex_offset = 0;
    command.first_instance = ref_index;
    commands[at] = command;
}

float largestScale(float3x4 transform) {
    return max(length(matrixColumn(transform, 0)), max(length(matrixColumn(transform, 1)), length(matrixColumn(transform, 2))));
}

[shader("compute")]
[numthreads(64, 1, 1)]
void meshletMain(uint3 id : SV_DispatchThreadID) {
    uint listed = id.x;
    if (listed >= meshlet_push.dispatch.count) return;
    uint ref_index = meshlet_push.candidates[listed];
    FrameConstants frame = meshlet_push.frame;
    MeshletRef ref = frame.meshlet_refs.data[ref_index];
    if (ref.instance == INVALID_ID) return;
    Instance instance = frame.instances.data[ref.instance];
    if (instance.mesh == INVALID_ID) return;
    Mesh mesh = loadAligned<16>(frame.meshes.data + instance.mesh);
    Meshlet meshlet = loadAligned<16>(frame.meshlets.data + ref.meshlet);
    Material material = loadAligned<16>(frame.materials.data + instance.material);
    bool skinned = (instance.flags & INSTANCE_SKINNED) != 0u;
    bool blended = (material.flags & MATERIAL_BLEND) != 0u;
    if (blended && meshlet_push.view.blended_casters == 0u) {
        markSeen(ref.instance);
        return;
    }

    bool fading = false;
    if (meshlet_push.view.lod_scale > 0.0) {
        float scale = largestScale(instance.transform);
        float3 mesh_center = skinned ? instance.bounding_sphere.xyz : mul(instance.transform, float4(mesh.center, 1.0));
        float mesh_radius = skinned ? instance.bounding_sphere.w : mesh.radius * scale;
        float distance_to_mesh = max(distance(meshlet_push.view.lod_camera, mesh_center) - mesh_radius, meshlet_push.view.near);
        float to_threshold = scale * meshlet_push.view.lod_scale / distance_to_mesh;
        float band = max(meshlet_push.view.lod_band, 1.0);
        float floor_error = instance.coarse_error;
        float own_error = max(meshlet.lod_error, floor_error);
        float parent_error = max(meshlet.parent_error, floor_error);
        if (floor_error > 0.0 && parent_error <= floor_error) return;
        bool at_floor = floor_error > 0.0 && own_error <= floor_error;
        float own = own_error * to_threshold;
        float coarser = parent_error * to_threshold;
        if (meshlet.self_sphere.w >= 0.0 && !skinned) {
            own = lodProjected(own_error, meshlet.self_sphere, instance.transform, scale, meshlet_push.view.lod_camera, meshlet_push.view.lod_scale, meshlet_push.view.near);
            coarser = lodProjected(parent_error, meshlet.parent_sphere, instance.transform, scale, meshlet_push.view.lod_camera, meshlet_push.view.lod_scale, meshlet_push.view.near);
        }
        if ((own > band && !at_floor) || coarser <= 1.0) return;
        fading = band > 1.0 && ((own > 1.0 && !at_floor) || coarser < band);
    } else {
        bool skipped;
        if (instance.coarse_error > 0.0) skipped = max(meshlet.parent_error, instance.coarse_error) <= instance.coarse_error || meshlet.lod_error > instance.coarse_error;
        else skipped = meshlet.lod_error > 0.0;
        if (skipped) return;
    }
    bool was_visible = meshlet_push.phase != PHASE_SINGLE && meshlet_push.visibility[ref_index] != 0u;
    if (was_visible && meshlet_push.phase == PHASE_LATE)
        was_visible = (meshlet_push.instance_visibility[ref.instance] & 2u) != 0u;
    if (meshlet_push.phase == PHASE_EARLY && !was_visible) return;

    float3 center;
    float radius;
    bool own_bounds = skinned && instance.bounds_offset != INVALID_ID;
    if (own_bounds) {
        float4 deformed = loadAligned<16>(meshlet_push.skin_bounds + instance.bounds_offset + (ref.meshlet - mesh.meshlet_offset));
        center = mul(instance.transform, float4(deformed.xyz, 1.0));
        radius = deformed.w * largestScale(instance.transform);
    } else if (skinned) {
        center = instance.bounding_sphere.xyz;
        radius = instance.bounding_sphere.w;
    } else {
        center = mul(instance.transform, float4(meshlet.center, 1.0));
        radius = meshlet.radius * largestScale(instance.transform);
    }

    bool visible = true;
    if (meshlet_push.view.min_radius > 0.0) {
        float whole = skinned ? instance.bounding_sphere.w : mesh.radius * largestScale(instance.transform);
        visible = whole >= meshlet_push.view.min_radius;
    }
    for (uint i = 0u; i < meshlet_push.view.plane_count; i++) {
        float4 plane = meshlet_push.view.planes[i];
        if (dot(plane.xyz, center) + plane.w < -radius) visible = false;
    }

    if (visible && meshlet_push.view.receiver_culling != 0u && shadowUnseen(center, radius)) visible = false;

    float3 axis_x = matrixColumn(instance.transform, 0);
    bool mirrored = dot(axis_x, cross(matrixColumn(instance.transform, 1), matrixColumn(instance.transform, 2))) < 0.0;
    bool two_sided = (material.flags & MATERIAL_DOUBLE_SIDED) != 0u || mirrored;
    if (visible && meshlet_push.view.cone_culling != 0u && !skinned && !two_sided && meshlet.cone_cutoff < 1.0) {
        float3 axis = normalize(mul((float3x3)instance.transform, meshlet.cone_axis));
        float3 to_center = center - meshlet_push.view.camera_position;
        if (dot(to_center, axis) >= meshlet.cone_cutoff * length(to_center) + radius) visible = false;
    }

    if (meshlet_push.phase == PHASE_LATE) {
        if (visible && occluded(meshletOcclusion(), center, radius)) visible = false;
        meshlet_push.visibility[ref_index] = visible ? 1u : 0u;
        if (visible) markSeen(ref.instance);
        if (was_visible) return;
    }
    if (!visible) return;
    if (meshlet_push.phase == PHASE_SINGLE) markSeen(ref.instance);

    uint bucket = fading || mirrored || (material.flags & (MATERIAL_ALPHA_TEST | MATERIAL_DOUBLE_SIDED | MATERIAL_BLEND)) != 0u ? 1u : 0u;
    if (meshlet_push.ordered != 0u) {
        meshlet_push.marks[ref_index] = bucket + 1u;
        return;
    }
    uint slot;
    InterlockedAdd(meshlet_push.counts[bucket], 1u, slot);
    if (slot >= (bucket == 0u ? meshlet_push.bucket_capacity : meshlet_push.masked_capacity)) {
        InterlockedAdd(meshlet_push.counts[bucket], 0xffffffffu);
        return;
    }
    writeDraw(meshlet_push.mesh_lists, meshlet_push.commands, meshlet_push.lists, bucket * meshlet_push.bucket_capacity + slot, ref_index, meshlet.index_count, mesh.index_offset + meshlet.index_offset);
    if (meshlet_push.mesh_lists == 1u) InterlockedMax(meshlet_push.mesh_draws[bucket].x, (slot + meshlets_per_task) / meshlets_per_task);
}

#include "cull.OrderPush.slang"

[[vk::push_constant]] OrderPush order_push;

static const uint order_block = 1024u;
static const uint order_threads = 256u;
static const uint order_per_thread = order_block / order_threads;

groupshared uint2 order_wave_sums[order_threads];
groupshared uint2 order_scan[1024];

/// The bucket `ref_index` was marked for, plus one; 0 when unmarked.
uint orderMark(uint ref_index) {
    return ref_index < order_push.ref_count ? order_push.marks[ref_index] : 0u;
}

/// How many of a thread's references each bucket holds.
uint2 orderCount(uint first, out uint marks[order_per_thread]) {
    uint2 counted = uint2(0u, 0u);
    for (uint i = 0u; i < order_per_thread; i++) {
        marks[i] = orderMark(first + i);
        if (marks[i] == 1u) counted.x++;
        if (marks[i] == 2u) counted.y++;
    }
    return counted;
}

/// Adds up the counts of the workgroup's earlier waves, and of all its
/// waves in `total`.
uint2 orderBefore(uint thread, uint2 counted, out uint2 total) {
    uint lanes = WaveGetLaneCount();
    uint2 sum = uint2(WaveActiveSum(counted.x), WaveActiveSum(counted.y));
    if (WaveIsFirstLane()) order_wave_sums[thread / lanes] = sum;
    GroupMemoryBarrierWithGroupSync();
    uint2 before = uint2(0u, 0u);
    total = uint2(0u, 0u);
    for (uint wave = 0u; wave < order_threads / lanes; wave++) {
        if (wave < thread / lanes) before += order_wave_sums[wave];
        total += order_wave_sums[wave];
    }
    return before + uint2(WavePrefixSum(counted.x), WavePrefixSum(counted.y));
}

/// Counts each block's marked references per bucket.
[shader("compute")]
[numthreads(256, 1, 1)]
void orderCountMain(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
    uint marks[order_per_thread];
    uint2 counted = orderCount(group.x * order_block + thread.x * order_per_thread, marks);
    uint2 total;
    orderBefore(thread.x, counted, total);
    if (thread.x == 0u) {
        order_push.blocks[group.x * 2u] = total.x;
        order_push.blocks[group.x * 2u + 1u] = total.y;
    }
}

/// Turns the block counts into each block's first place per bucket, and
/// sets the lists' lengths.
[shader("compute")]
[numthreads(1024, 1, 1)]
void orderScanMain(uint3 thread : SV_GroupThreadID) {
    uint blocks = (order_push.ref_count + order_block - 1u) / order_block;
    uint per = (blocks + 1023u) / 1024u;
    uint first = thread.x * per;
    uint last = min(first + per, blocks);
    uint2 sum = uint2(0u, 0u);
    for (uint block = first; block < last; block++) sum += uint2(order_push.blocks[block * 2u], order_push.blocks[block * 2u + 1u]);
    order_scan[thread.x] = sum;
    GroupMemoryBarrierWithGroupSync();
    for (uint step = 1u; step < 1024u; step <<= 1u) {
        uint2 add = thread.x >= step ? order_scan[thread.x - step] : uint2(0u, 0u);
        GroupMemoryBarrierWithGroupSync();
        order_scan[thread.x] += add;
        GroupMemoryBarrierWithGroupSync();
    }
    uint2 running = thread.x == 0u ? uint2(0u, 0u) : order_scan[thread.x - 1u];
    for (uint block = first; block < last; block++) {
        uint2 here = uint2(order_push.blocks[block * 2u], order_push.blocks[block * 2u + 1u]);
        order_push.blocks[block * 2u] = running.x;
        order_push.blocks[block * 2u + 1u] = running.y;
        running += here;
    }
    if (thread.x == 1023u) {
        uint2 listed = uint2(min(order_scan[1023u].x, order_push.bucket_capacity), min(order_scan[1023u].y, order_push.masked_capacity));
        order_push.counts[0] = listed.x;
        order_push.counts[1] = listed.y;
        if (order_push.mesh_lists == 1u) {
            order_push.mesh_draws[0].x = (listed.x + meshlets_per_task - 1u) / meshlets_per_task;
            order_push.mesh_draws[1].x = (listed.y + meshlets_per_task - 1u) / meshlets_per_task;
        }
    }
}

/// Lists each block's marked references at its places, in reference order,
/// and clears the marks for the next view.
[shader("compute")]
[numthreads(256, 1, 1)]
void orderWriteMain(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
    uint first = group.x * order_block + thread.x * order_per_thread;
    uint marks[order_per_thread];
    uint2 counted = orderCount(first, marks);
    uint2 total;
    uint2 slot = orderBefore(thread.x, counted, total) + uint2(order_push.blocks[group.x * 2u], order_push.blocks[group.x * 2u + 1u]);
    FrameConstants frame = order_push.frame;
    for (uint i = 0u; i < order_per_thread; i++) {
        if (marks[i] == 0u) continue;
        uint ref_index = first + i;
        order_push.marks[ref_index] = 0u;
        uint bucket = marks[i] - 1u;
        uint at = bucket == 0u ? slot.x++ : slot.y++;
        if (at >= (bucket == 0u ? order_push.bucket_capacity : order_push.masked_capacity)) continue;
        MeshletRef ref = frame.meshlet_refs.data[ref_index];
        Instance instance = frame.instances.data[ref.instance];
        Mesh mesh = loadAligned<16>(frame.meshes.data + instance.mesh);
        Meshlet meshlet = loadAligned<16>(frame.meshlets.data + ref.meshlet);
        writeDraw(order_push.mesh_lists, order_push.commands, order_push.lists, bucket * order_push.bucket_capacity + at, ref_index, meshlet.index_count, mesh.index_offset + meshlet.index_offset);
    }
}

struct ImpostorDraw {
    uint vertex_count;
    uint instance_count;
    uint first_vertex;
    uint first_instance;
};

#include "cull.InstancePush.slang"

[[vk::push_constant]] InstancePush instance_push;

Occlusion instanceOcclusion() {
    Occlusion occlusion = { instance_push.frame, instance_push.view, instance_push.hiz_texture, instance_push.hiz_size };
    return occlusion;
}

/// Culls one instance by its bounding sphere in this view, `slot` being its
/// instance record, and returns the meshlet references to list for it:
/// first and count, none when culled or drawn as an impostor.
uint2 cullInstance(uint slot, StaticCull instance) {
    bool was_visible = instance_push.phase != PHASE_SINGLE && (instance_push.visibility[slot] & 1u) != 0u;
    if (instance_push.phase == PHASE_EARLY && !was_visible) return uint2(0u, 0u);

    float3 center = instance.sphere.xyz;
    float radius = instance.sphere.w;
    bool as_impostor = false;
    if (instance_push.impostor_view != 0u && instance.impostor != 0u) {
        float across = radius * abs(instance_push.view.p11) * instance_push.frame.resolution.y / (instance_push.view.far > 0.0 ? 1.0 : max(distance(instance_push.view.camera_position, center), instance_push.view.near));
        as_impostor = across < instance_push.impostors[instance.impostor - 1u].pixels;
        if (as_impostor && instance_push.phase == PHASE_EARLY) return uint2(0u, 0u);
    }
    bool visible = radius >= instance_push.view.min_radius;
    for (uint i = 0u; i < instance_push.view.plane_count; i++) {
        float4 plane = instance_push.view.planes[i];
        if (dot(plane.xyz, center) + plane.w < -radius) visible = false;
    }
    if (instance_push.phase == PHASE_LATE) {
        if (visible && occluded(instanceOcclusion(), center, radius)) visible = false;
        instance_push.visibility[slot] = (was_visible ? 2u : 0u) | (visible ? 1u : 0u);
    }
    if (!visible || instance.ref_count == 0u) return uint2(0u, 0u);
    if (as_impostor) {
        uint listed;
        InterlockedAdd(instance_push.impostor_draw.instance_count, 1u, listed);
        instance_push.impostor_list[listed] = slot - instance_push.entity_count;
        return uint2(0u, 0u);
    }
    return uint2(instance.first_ref, instance.ref_count);
}

/// Spans up to this long are listed by their own lane; longer ones by the
/// whole wave, one span at a time.
static const uint lane_span = 8u;

/// Appends each lane's span of meshlet references to this view's
/// candidates, with one atomic for the wave.
void listRefs(uint2 refs) {
    uint offset = WavePrefixSum(refs.y);
    uint total = WaveActiveSum(refs.y);
    if (total == 0u) return;
    uint base = 0u;
    if (WaveIsFirstLane()) InterlockedAdd(instance_push.dispatch.count, total, base);
    base = WaveReadLaneFirst(base);
    uint first = base + offset;
    bool long_span = refs.y > lane_span;
    if (!long_span) for (uint i = 0u; i < refs.y; i++) instance_push.candidates[first + i] = refs.x + i;
    uint lane = WaveGetLaneIndex();
    while (WaveActiveAnyTrue(long_span)) {
        uint leader = WaveActiveMin(long_span ? lane : 0xffffffffu);
        uint span_ref = WaveReadLaneAt(refs.x, leader);
        uint span_at = WaveReadLaneAt(first, leader);
        uint span_count = WaveReadLaneAt(refs.y, leader);
        for (uint i = lane; i < span_count; i += WaveGetLaneCount()) instance_push.candidates[span_at + i] = span_ref + i;
        if (lane == leader) long_span = false;
    }
    if (WaveIsFirstLane()) InterlockedMax(instance_push.dispatch.x, (base + total + 63u) / 64u);
}

/// Instance groups' instances, which come with their bounds.
[shader("compute")]
[numthreads(64, 1, 1)]
void instanceMain(uint3 id : SV_DispatchThreadID) {
    uint index = id.x;
    uint2 refs = uint2(0u, 0u);
    if (index < instance_push.instance_count) refs = cullInstance(instance_push.entity_count + index, loadAligned<16>(instance_push.instances + index));
    listRefs(refs);
}

/// Entities' instances, bounded by their mesh and record as they are now.
[shader("compute")]
[numthreads(64, 1, 1)]
void entityMain(uint3 id : SV_DispatchThreadID) {
    uint index = id.x;
    uint2 refs = uint2(0u, 0u);
    if (index < instance_push.entity_count) {
        uint2 span = instance_push.entity_cull[index];
        Instance record = instance_push.frame.instances.data[index];
        if (span.y != 0u && record.mesh != INVALID_ID) {
            Mesh mesh = loadAligned<16>(instance_push.frame.meshes.data + record.mesh);
            StaticCull instance;
            bool skinned = (record.flags & INSTANCE_SKINNED) != 0u;
            instance.sphere = skinned ? record.bounding_sphere : float4(mul(record.transform, float4(mesh.center, 1.0)), mesh.radius * largestScale(record.transform));
            instance.first_ref = span.x;
            instance.ref_count = span.y;
            instance.impostor = 0u;
            instance.pad = 0u;
            refs = cullInstance(index, instance);
        }
    }
    listRefs(refs);
}
