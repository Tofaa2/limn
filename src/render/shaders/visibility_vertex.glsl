#ifndef VISIBILITY_VERTEX_GLSL
#define VISIBILITY_VERTEX_GLSL

// One meshlet vertex for the visibility and shadow passes. Shared by
// visibility.vert and visibility.mesh; include after their `push` block.
struct VisibilityVertex {
    vec4 position;
    uint id;
    uint material;
    vec2 uv;
    // LOD fade: pixels are kept where the noise is under x and not under y.
    vec2 fade;
    // Distance inside each edge of the page rectangle; negative is clipped.
    vec4 inside;
};

VisibilityVertex visibilityVertex(uint ref_index, uint vertex_index) {
    VisibilityVertex result;
    MeshletRef ref = push.frame.meshlet_refs.data[ref_index];
    Instance instance = push.frame.instances.data[ref.instance];
    Vertex vertex = push.frame.vertices.data[instance.vertex_offset + vertex_index];
    vec4 world = vec4(instance.transform * vec4(vertex.position, 1.0), 1.0);
    float sway = push.frame.materials.data[instance.material].sway;
    if (sway != 0.0) world.xyz += swayOffset(sway, instance.transform[3], world.xyz, push.frame.time);
    result.position = push.view_proj * world;
    result.inside = vec4(1.0);
    if (push.paged != 0u) {
        result.position = push.page.view_proj * world;
        vec4 bounds = push.page.bounds;
        result.inside = vec4(result.position.xy - bounds.xy, bounds.zw - result.position.xy);
    }
    result.id = ref_index << 7;
    result.material = instance.material;
    result.uv = vertex.uv;
    result.fade = vec2(1.0, 0.0);
    if (push.lod_band > 1.0) {
        Mesh mesh = push.frame.meshes.data[instance.mesh];
        Meshlet meshlet = push.frame.meshlets.data[ref.meshlet];
        bool skinned = (instance.flags & INSTANCE_SKINNED) != 0u;
        float scale = max(length(instance.transform[0].xyz), max(length(instance.transform[1].xyz), length(instance.transform[2].xyz)));
        vec3 mesh_center = skinned ? instance.bounding_sphere.xyz : (instance.transform * vec4(mesh.center, 1.0)).xyz;
        float mesh_radius = skinned ? instance.bounding_sphere.w : mesh.radius * scale;
        float to_threshold = scale * push.lod.w / max(distance(push.lod.xyz, mesh_center) - mesh_radius, push.lod_near);
        // With only the coarse part loaded, errors are floored at its error.
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
        if (coarse > 1.0 && !at_floor) result.fade.x = clamp((push.lod_band - coarse) / (push.lod_band - 1.0), 0.0, 1.0);
        if (finer < push.lod_band) result.fade.y = clamp((push.lod_band - finer) / (push.lod_band - 1.0), 0.0, 1.0);
    }
    return result;
}

#endif
