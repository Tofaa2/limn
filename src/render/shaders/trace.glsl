// Ray-scene intersection. With RAY_TRACED: ray queries against the TLAS.
// Without: a software BVH (bvh.zig), one over the instances and one per mesh.
// Both return instance, triangle and barycentrics.
#ifndef TRACE_GLSL
#define TRACE_GLSL

struct TraceHit {
    // Distance along the ray.
    float t;
    // Index into the frame's instances.
    uint instance;
    // Triangle index in the mesh's full-detail indices.
    uint primitive;
    // Barycentric weights of the second and third vertex.
    vec2 barycentric;
};

#ifdef RAY_TRACED

// The includer enables GL_EXT_ray_query and declares `traceScene()`, which
// returns the TLAS address.
bool traceClosest(vec3 origin, vec3 direction, float max_distance, out TraceHit hit) {
    rayQueryEXT query;
    rayQueryInitializeEXT(query, accelerationStructureEXT(traceScene()), gl_RayFlagsOpaqueEXT, 0xffu, origin, 0.0, direction, max_distance);
    while (rayQueryProceedEXT(query)) {}
    if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return false;
    hit.t = rayQueryGetIntersectionTEXT(query, true);
    hit.instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
    hit.primitive = uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, true));
    hit.barycentric = rayQueryGetIntersectionBarycentricsEXT(query, true);
    return true;
}

bool traceAny(vec3 origin, vec3 direction, float max_distance) {
    rayQueryEXT query;
    rayQueryInitializeEXT(query, accelerationStructureEXT(traceScene()), gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, 0xffu, origin, 0.0, direction, max_distance);
    while (rayQueryProceedEXT(query)) {}
    return rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionNoneEXT;
}

#else

// Must match `Node` in bvh.zig.
struct BvhNode {
    vec3 lo;
    uint first;
    vec3 hi;
    uint count;
};

// Scene BVH leaf: world-to-mesh transform and instance index.
struct BvhInstance {
    mat4x3 to_mesh;
    uint instance;
    uint pad0;
    uint pad1;
    uint pad2;
};

layout(buffer_reference, scalar) readonly buffer BvhNodes { BvhNode data[]; };
layout(buffer_reference, scalar) readonly buffer BvhItems { uint data[]; };
layout(buffer_reference, scalar) readonly buffer BvhInstances { BvhInstance data[]; };

// Declared by the includer: scene nodes and instances, mesh nodes, leaf
// triangle lists and the frame.
BvhNodes traceSceneNodes();
BvhInstances traceSceneInstances();
BvhNodes traceMeshNodes();
BvhItems traceMeshItems();
FrameConstants traceFrame();

// Entry distance into the box; negative on a miss or beyond `nearest`.
float traceBox(vec3 lo, vec3 hi, vec3 origin, vec3 inverse, float nearest) {
    vec3 a = (lo - origin) * inverse;
    vec3 b = (hi - origin) * inverse;
    vec3 enter = min(a, b);
    vec3 leave = max(a, b);
    float t_enter = max(max(enter.x, enter.y), max(enter.z, 0.0));
    float t_leave = min(min(leave.x, leave.y), min(leave.z, nearest));
    return t_enter <= t_leave ? t_enter : -1.0;
}

vec3 traceInverse(vec3 direction) {
    vec3 safe = mix(direction, vec3(1e-20), lessThan(abs(direction), vec3(1e-20)));
    return 1.0 / safe;
}

// Traces one mesh in its own space. `nearest` is the closest hit so far and is
// updated. Returns whether anything was hit.
bool traceMesh(Instance instance, uint instance_index, vec3 origin, vec3 direction, bool any_hit, inout float nearest, inout TraceHit hit) {
    FrameConstants frame = traceFrame();
    Mesh mesh = frame.meshes.data[instance.mesh];
    // Meshes without a BVH are invisible to rays.
    if (mesh.bvh == INVALID_ID) return false;
    BvhNodes nodes = traceMeshNodes();
    BvhItems items = traceMeshItems();
    vec3 inverse = traceInverse(direction);
    uint root = mesh.bvh;
    BvhNode top = nodes.data[root];
    if (traceBox(top.lo, top.hi, origin, inverse, nearest) < 0.0) return false;
    bool found = false;
    uint stack[32];
    int depth = 0;
    uint current = root;
    while (true) {
        BvhNode node = nodes.data[current];
        if (node.count != 0u) {
            for (uint i = 0u; i < node.count; i++) {
                uint primitive = items.data[node.first + i];
                uint base = mesh.index_offset + primitive * 3u;
                vec3 p0 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base]].position;
                vec3 p1 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]].position;
                vec3 p2 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]].position;
                // Möller and Trumbore.
                vec3 edge1 = p1 - p0;
                vec3 edge2 = p2 - p0;
                vec3 across = cross(direction, edge2);
                float determinant = dot(edge1, across);
                if (abs(determinant) < 1e-20) continue;
                float scale = 1.0 / determinant;
                vec3 from = origin - p0;
                float u = dot(from, across) * scale;
                if (u < 0.0 || u > 1.0) continue;
                vec3 other = cross(from, edge1);
                float v = dot(direction, other) * scale;
                if (v < 0.0 || u + v > 1.0) continue;
                float t = dot(edge2, other) * scale;
                if (t <= 1e-6 || t >= nearest) continue;
                nearest = t;
                hit.t = t;
                hit.instance = instance_index;
                hit.primitive = primitive;
                hit.barycentric = vec2(u, v);
                found = true;
                if (any_hit) return true;
            }
            if (depth == 0) break;
            current = stack[--depth];
            continue;
        }
        // Child indices are relative to the mesh root.
        uint left = root + node.first;
        BvhNode a = nodes.data[left];
        BvhNode b = nodes.data[left + 1u];
        float ta = traceBox(a.lo, a.hi, origin, inverse, nearest);
        float tb = traceBox(b.lo, b.hi, origin, inverse, nearest);
        if (ta < 0.0 && tb < 0.0) {
            if (depth == 0) break;
            current = stack[--depth];
        } else if (ta < 0.0) {
            current = left + 1u;
        } else if (tb < 0.0) {
            current = left;
        } else {
            bool a_first = ta <= tb;
            current = a_first ? left : left + 1u;
            if (depth < 32) stack[depth++] = a_first ? left + 1u : left;
        }
    }
    return found;
}

bool traceWalk(vec3 origin, vec3 direction, float max_distance, bool any_hit, out TraceHit hit) {
    FrameConstants frame = traceFrame();
    BvhNodes nodes = traceSceneNodes();
    BvhInstances instances = traceSceneInstances();
    hit.t = max_distance;
    hit.instance = 0u;
    hit.primitive = 0u;
    hit.barycentric = vec2(0.0);
    float nearest = max_distance;
    vec3 inverse = traceInverse(direction);
    BvhNode top = nodes.data[0];
    if (traceBox(top.lo, top.hi, origin, inverse, nearest) < 0.0) return false;
    bool found = false;
    uint stack[32];
    int depth = 0;
    uint current = 0u;
    while (true) {
        BvhNode node = nodes.data[current];
        if (node.count != 0u) {
            for (uint i = 0u; i < node.count; i++) {
                BvhInstance placed = instances.data[node.first + i];
                Instance instance = frame.instances.data[placed.instance];
                // The direction is not renormalized in mesh space, so t stays
                // in world units.
                vec3 mesh_origin = placed.to_mesh * vec4(origin, 1.0);
                vec3 mesh_direction = placed.to_mesh * vec4(direction, 0.0);
                if (traceMesh(instance, placed.instance, mesh_origin, mesh_direction, any_hit, nearest, hit)) {
                    found = true;
                    if (any_hit) return true;
                }
            }
            if (depth == 0) break;
            current = stack[--depth];
            continue;
        }
        uint left = node.first;
        BvhNode a = nodes.data[left];
        BvhNode b = nodes.data[left + 1u];
        float ta = traceBox(a.lo, a.hi, origin, inverse, nearest);
        float tb = traceBox(b.lo, b.hi, origin, inverse, nearest);
        if (ta < 0.0 && tb < 0.0) {
            if (depth == 0) break;
            current = stack[--depth];
        } else if (ta < 0.0) {
            current = left + 1u;
        } else if (tb < 0.0) {
            current = left;
        } else {
            bool a_first = ta <= tb;
            current = a_first ? left : left + 1u;
            if (depth < 32) stack[depth++] = a_first ? left + 1u : left;
        }
    }
    return found;
}

bool traceClosest(vec3 origin, vec3 direction, float max_distance, out TraceHit hit) {
    return traceWalk(origin, direction, max_distance, false, hit);
}

bool traceAny(vec3 origin, vec3 direction, float max_distance) {
    TraceHit hit;
    return traceWalk(origin, direction, max_distance, true, hit);
}

#endif
#endif
