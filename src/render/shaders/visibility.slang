#include "common.slang"
#include "visibility_page.slang"

struct VisibilityPush {
    FrameConstants frame;
};

[[vk::push_constant]] VisibilityPush visibility_push;

[shader("fragment")]
uint visibilityMain(
    [[vk::location(0)]] nointerpolation uint in_id,
    [[vk::location(1)]] nointerpolation uint in_material,
    [[vk::location(2)]] float2 in_uv,
    [[vk::location(3)]] nointerpolation float2 in_fade,
    float4 fragment : SV_Position,
    uint primitive : SV_PrimitiveID) : SV_Target {
#ifdef ALPHA_TEST
    if (in_fade.x < 1.0 || in_fade.y > 0.0) {
        float noise = interleavedGradientNoise(fragment.xy, (visibility_push.frame.flags & FRAME_TEMPORAL) != 0u ? visibility_push.frame.frame_index : 0u);
        if (noise >= in_fade.x || noise < in_fade.y) discard;
    }
    Material material = visibility_push.frame.materials.data[in_material];
    if ((material.flags & MATERIAL_ALPHA_TEST) != 0u) {
        float alpha = material.base_color.a;
        if (material.base_color_texture != INVALID_ID)
            alpha *= sampleTexture(material.base_color_texture, material.sampler_index, materialUv(material, in_uv)).a;
        if (alpha < material.alpha_cutoff) discard;
    }
#endif
    return in_id | primitive;
}

/// Triangles per mesh shader group; larger meshlets take two.
static const uint triangles_per_group = 64u;
/// Listed meshlets per task shader group.
static const uint meshlets_per_task = 32u;

struct MeshletTasks {
    /// Per mesh shader group: meshlet reference << 1 | which half of its
    /// triangles.
    uint entries[meshlets_per_task * 2u];
};

struct GeometryPush {
    FrameConstants frame;
    /// 1 in a shadow pass whose translucent casters go into the tint pass.
    uint tinted;
    /// Nonzero when `page` supplies the view.
    uint paged;
    float4x4 view_proj;
    /// LOD cross-fade, main camera pass only: LOD camera (xyz), error-to-pixels
    /// scale (w), band width (1 for none) and near plane.
    float4 lod;
    float lod_band;
    float lod_near;
    /// Meshlet references written by cull.slang, and their count.
    uint* list;
    uint* count;
    VisibilityPage page;
};

[[vk::push_constant]] GeometryPush geometry_push;

struct VisibilityVertex {
    float4 position : SV_Position;
    float clip[4] : SV_ClipDistance;
    [[vk::location(0)]] nointerpolation uint id;
    [[vk::location(1)]] nointerpolation uint material;
    [[vk::location(2)]] float2 uv;
    [[vk::location(3)]] nointerpolation float2 fade;
};

VisibilityVertex visibilityVertex(uint ref_index, uint vertex_index) {
    FrameConstants frame = geometry_push.frame;
    VisibilityVertex result;
    MeshletRef ref = frame.meshlet_refs.data[ref_index];
    Instance instance = frame.instances.data[ref.instance];
    Vertex vertex = frame.vertices.data[instance.vertex_offset + vertex_index];
    float4 world = float4(mul(instance.transform, float4(vertex.position, 1.0)), 1.0);
    float sway = frame.materials.data[instance.material].sway;
    if (sway != 0.0) world.xyz += swayOffset(sway, frame.materials.data[instance.material].flags, matrixColumn(instance.transform, 3), world.xyz, vertex.uv1, frame.time);
    result.position = mul(geometry_push.view_proj, world);
    float4 inside = float4(1.0);
    if (geometry_push.paged != 0u) {
        result.position = mul(geometry_push.page.data.view_proj, world);
        float4 bounds = geometry_push.page.data.bounds;
        inside = float4(result.position.xy - bounds.xy, bounds.zw - result.position.xy);
    }
    result.clip[0] = inside.x;
    result.clip[1] = inside.y;
    result.clip[2] = inside.z;
    result.clip[3] = inside.w;
    result.id = ref_index << 7;
    result.material = instance.material;
    result.uv = vertex.uv;
    result.fade = float2(1.0, 0.0);
    if (geometry_push.lod_band > 1.0) {
        Mesh mesh = loadAligned<16>(frame.meshes.data + instance.mesh);
        Meshlet meshlet = loadAligned<16>(frame.meshlets.data + ref.meshlet);
        bool skinned = (instance.flags & INSTANCE_SKINNED) != 0u;
        float scale = max(length(matrixColumn(instance.transform, 0)), max(length(matrixColumn(instance.transform, 1)), length(matrixColumn(instance.transform, 2))));
        float3 mesh_center = skinned ? instance.bounding_sphere.xyz : mul(instance.transform, float4(mesh.center, 1.0));
        float mesh_radius = skinned ? instance.bounding_sphere.w : mesh.radius * scale;
        float to_threshold = scale * geometry_push.lod.w / max(distance(geometry_push.lod.xyz, mesh_center) - mesh_radius, geometry_push.lod_near);
        float floor_error = instance.coarse_error;
        float own_error = max(meshlet.lod_error, floor_error);
        float parent_error = max(meshlet.parent_error, floor_error);
        bool at_floor = floor_error > 0.0 && own_error <= floor_error;
        float coarse = own_error * to_threshold;
        float finer = parent_error * to_threshold;
        if (meshlet.self_sphere.w >= 0.0 && !skinned) {
            coarse = lodProjected(own_error, meshlet.self_sphere, instance.transform, scale, geometry_push.lod.xyz, geometry_push.lod.w, geometry_push.lod_near);
            finer = lodProjected(parent_error, meshlet.parent_sphere, instance.transform, scale, geometry_push.lod.xyz, geometry_push.lod.w, geometry_push.lod_near);
        }
        if (coarse > 1.0 && !at_floor) result.fade.x = clamp((geometry_push.lod_band - coarse) / (geometry_push.lod_band - 1.0), 0.0, 1.0);
        if (finer < geometry_push.lod_band) result.fade.y = clamp((geometry_push.lod_band - finer) / (geometry_push.lod_band - 1.0), 0.0, 1.0);
    }
    return result;
}

/// One meshlet's triangle per instance, drawn with the classic vertex
/// pipeline where mesh shaders are missing.
[shader("vertex")]
VisibilityVertex geometryVertexMain(uint vertex : SV_VulkanVertexID, uint instance : SV_VulkanInstanceID) {
    return visibilityVertex(instance, vertex);
}

groupshared MeshletTasks tasks;

/// Dispatches the meshlets cull.slang listed for a view to `geometryMeshMain`, 32
/// per group.
[shader("amplification")]
[numthreads(1, 1, 1)]
void geometryTaskMain(uint3 group : SV_GroupID) {
    FrameConstants frame = geometry_push.frame;
    uint first = group.x * meshlets_per_task;
    uint listed = *geometry_push.count;
    uint groups = 0u;
    for (uint i = 0u; i < meshlets_per_task && first + i < listed; i++) {
        uint ref_index = geometry_push.list[first + i];
        MeshletRef ref = frame.meshlet_refs.data[ref_index];
        uint triangles = frame.meshlets.data[ref.meshlet].index_count / 3u;
        for (uint part = 0u; part * triangles_per_group < triangles; part++) {
            tasks.entries[groups] = (ref_index << 1) | part;
            groups++;
        }
    }
    DispatchMesh(groups, 1u, 1u, tasks);
}

struct Primitive {
    uint id : SV_PrimitiveID;
};

/// Draws up to 64 triangles of one meshlet, one per invocation.
[shader("mesh")]
[outputtopology("triangle")]
[numthreads(64, 1, 1)]
void geometryMeshMain(
    uint3 group : SV_GroupID,
    uint triangle : SV_GroupIndex,
    in payload MeshletTasks listed,
    out indices uint3 corners[64],
    out vertices VisibilityVertex points[192],
    out primitives Primitive primitives[64]) {
    FrameConstants frame = geometry_push.frame;
    uint entry = listed.entries[group.x];
    uint ref_index = entry >> 1;
    uint first_triangle = (entry & 1u) * triangles_per_group;
    MeshletRef ref = frame.meshlet_refs.data[ref_index];
    Instance instance = frame.instances.data[ref.instance];
    Mesh mesh = loadAligned<16>(frame.meshes.data + instance.mesh);
    Meshlet meshlet = loadAligned<16>(frame.meshlets.data + ref.meshlet);
    uint triangles = min(meshlet.index_count / 3u - first_triangle, triangles_per_group);
    SetMeshOutputCounts(triangles * 3u, triangles);
    if (triangle >= triangles) return;
    uint first_index = mesh.index_offset + meshlet.index_offset + (first_triangle + triangle) * 3u;
    for (uint corner = 0u; corner < 3u; corner++)
        points[triangle * 3u + corner] = visibilityVertex(ref_index, frame.indices.data[first_index + corner]);
    corners[triangle] = uint3(triangle * 3u, triangle * 3u + 1u, triangle * 3u + 2u);
    Primitive primitive;
    primitive.id = first_triangle + triangle;
    primitives[triangle] = primitive;
}
