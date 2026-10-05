#version 460
#include "common.glsl"

// Shared by the visibility pass and the shadow passes: vertices are pulled
// from the global buffers using the draw's meshlet reference.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint pad0;
    uint pad1;
    mat4 view_proj;
    // Cross-fading between levels of detail: the camera the levels are
    // chosen for (xyz) and the scale that turns an error into pixels (w),
    // then how wide the band is in which two levels are both drawn (1
    // for none) and the near plane. Only the camera's own pass sets them.
    vec4 lod;
    float lod_band;
    float lod_near;
} push;

layout(location = 0) flat out uint out_id;
layout(location = 1) flat out uint out_material;
layout(location = 2) out vec2 out_uv;
// Share of the pixels this meshlet keeps while it fades: those whose
// noise is under x and not under y.
layout(location = 3) flat out vec2 out_fade;

void main() {
    MeshletRef ref = push.frame.meshlet_refs.data[gl_InstanceIndex];
    Instance instance = push.frame.instances.data[ref.instance];
    Vertex vertex = push.frame.vertices.data[instance.vertex_offset + gl_VertexIndex];
    vec4 world = instance.transform * vec4(vertex.position, 1.0);
    float sway = push.frame.materials.data[instance.material].sway;
    if (sway != 0.0) world.xyz += swayOffset(sway, instance.transform[3].xyz, world.xyz, push.frame.time);
    gl_Position = push.view_proj * world;
    out_id = uint(gl_InstanceIndex) << 7;
    out_material = instance.material;
    out_uv = vertex.uv;
    out_fade = vec2(1.0, 0.0);
    if (push.lod_band > 1.0) {
        // The same sum the culling pass did to choose this level.
        Mesh mesh = push.frame.meshes.data[instance.mesh];
        Meshlet meshlet = push.frame.meshlets.data[ref.meshlet];
        bool skinned = (instance.flags & INSTANCE_SKINNED) != 0u;
        float scale = max(length(instance.transform[0].xyz), max(length(instance.transform[1].xyz), length(instance.transform[2].xyz)));
        vec3 mesh_center = skinned ? instance.bounding_sphere.xyz : (instance.transform * vec4(mesh.center, 1.0)).xyz;
        float mesh_radius = skinned ? instance.bounding_sphere.w : mesh.radius * scale;
        float to_threshold = scale * push.lod.w / max(distance(push.lod.xyz, mesh_center) - mesh_radius, push.lod_near);
        // As in the culling pass: with only its coarse part in memory,
        // no error counts as smaller than that part's.
        float floor_error = instance.coarse_error;
        float own_error = max(meshlet.lod_error, floor_error);
        float parent_error = max(meshlet.parent_error, floor_error);
        bool at_floor = floor_error > 0.0 && own_error <= floor_error;
        float coarse = own_error * to_threshold;
        float finer = parent_error * to_threshold;
        if (meshlet.self_sphere.w >= 0.0 && !skinned) {
            coarse = lodProjected(own_error, meshlet.self_sphere, instance.transform, scale, push.lod.xyz, push.lod.w, push.lod_near);
            finer = lodProjected(parent_error, meshlet.parent_sphere, instance.transform, scale, push.lod.xyz, push.lod.w, push.lod_near);
        }
        // Coming in as the coarser of two levels, going out as the finer.
        if (coarse > 1.0 && !at_floor) out_fade.x = clamp((push.lod_band - coarse) / (push.lod_band - 1.0), 0.0, 1.0);
        if (finer < push.lod_band) out_fade.y = clamp((push.lod_band - finer) / (push.lod_band - 1.0), 0.0, 1.0);
    }
}
