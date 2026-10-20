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

float largestScale(float3x4 transform) {
    return max(length(matrixColumn(transform, 0)), max(length(matrixColumn(transform, 1)), length(matrixColumn(transform, 2))));
}

[shader("compute")]
[numthreads(64, 1, 1)]
void meshletMain(uint3 id : SV_DispatchThreadID) {
    uint listed = id.x;
    if (listed >= meshlet_push.entity_refs + meshlet_push.dispatch.count) return;
    uint ref_index = listed;
    if (listed >= meshlet_push.entity_refs) ref_index = meshlet_push.candidates[listed - meshlet_push.entity_refs];
    FrameConstants frame = meshlet_push.frame;
    MeshletRef ref = frame.meshlet_refs.data[ref_index];
    Instance instance = frame.instances.data[ref.instance];
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
    if (was_visible && meshlet_push.phase == PHASE_LATE && ref.instance >= meshlet_push.entity_instances)
        was_visible = (meshlet_push.instance_visibility[ref.instance - meshlet_push.entity_instances] & 2u) != 0u;
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

    bool two_sided = (material.flags & MATERIAL_DOUBLE_SIDED) != 0u;
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

    uint bucket = fading || (material.flags & (MATERIAL_ALPHA_TEST | MATERIAL_DOUBLE_SIDED | MATERIAL_BLEND)) != 0u ? 1u : 0u;
    uint slot;
    InterlockedAdd(meshlet_push.counts[bucket], 1u, slot);
    if (slot >= (bucket == 0u ? meshlet_push.bucket_capacity : meshlet_push.masked_capacity)) return;
    if (meshlet_push.mesh_lists != 0u) {
        meshlet_push.lists[bucket * meshlet_push.bucket_capacity + slot] = ref_index;
        InterlockedMax(meshlet_push.mesh_draws[bucket].x, (slot + meshlets_per_task) / meshlets_per_task);
        return;
    }
    DrawCommand command;
    command.index_count = meshlet.index_count;
    command.instance_count = 1u;
    command.first_index = mesh.index_offset + meshlet.index_offset;
    command.vertex_offset = 0;
    command.first_instance = ref_index;
    meshlet_push.commands[bucket * meshlet_push.bucket_capacity + slot] = command;
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

[shader("compute")]
[numthreads(64, 1, 1)]
void instanceMain(uint3 id : SV_DispatchThreadID) {
    uint index = id.x;
    if (index >= instance_push.instance_count) return;
    StaticCull instance = loadAligned<16>(instance_push.instances + index);
    bool was_visible = instance_push.phase != PHASE_SINGLE && (instance_push.visibility[index] & 1u) != 0u;
    if (instance_push.phase == PHASE_EARLY && !was_visible) return;

    float3 center = instance.sphere.xyz;
    float radius = instance.sphere.w;
    bool as_impostor = false;
    if (instance_push.impostor_view != 0u && instance.impostor != 0u) {
        float across = radius * abs(instance_push.view.p11) * instance_push.frame.resolution.y / (instance_push.view.far > 0.0 ? 1.0 : max(distance(instance_push.view.camera_position, center), instance_push.view.near));
        as_impostor = across < instance_push.impostors[instance.impostor - 1u].pixels;
        if (as_impostor && instance_push.phase == PHASE_EARLY) return;
    }
    bool visible = radius >= instance_push.view.min_radius;
    for (uint i = 0u; i < instance_push.view.plane_count; i++) {
        float4 plane = instance_push.view.planes[i];
        if (dot(plane.xyz, center) + plane.w < -radius) visible = false;
    }
    if (instance_push.phase == PHASE_LATE) {
        if (visible && occluded(instanceOcclusion(), center, radius)) visible = false;
        instance_push.visibility[index] = (was_visible ? 2u : 0u) | (visible ? 1u : 0u);
    }
    if (!visible || instance.ref_count == 0u) return;
    if (as_impostor) {
        uint listed;
        InterlockedAdd(instance_push.impostor_draw.instance_count, 1u, listed);
        instance_push.impostor_list[listed] = index;
        return;
    }

    uint first;
    InterlockedAdd(instance_push.dispatch.count, instance.ref_count, first);
    for (uint i = 0u; i < instance.ref_count; i++) instance_push.candidates[first + i] = instance.first_ref + i;
    InterlockedMax(instance_push.dispatch.x, (instance_push.entity_refs + first + instance.ref_count + 63u) / 64u);
}
