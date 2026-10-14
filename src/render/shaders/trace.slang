#ifndef TRACE_SLANG
#define TRACE_SLANG
#include "common.slang"

struct TraceHit {
    float t;
    uint instance;
    uint primitive;
    float2 barycentric;
};

static const uint RAY_SOLID = 0x01u;
static const uint RAY_ALL = 0x03u;
static const uint RAY_EVERYTHING = 0xffu;

/// Whether a ray lets the cut-out parts of alpha tested surfaces through
/// (`cut`) or takes those surfaces whole.
enum Cutouts { whole, cut };

float3 barycentricWeights(float2 barycentric) {
    return float3(1.0 - barycentric.x - barycentric.y, barycentric.x, barycentric.y);
}

/// Whether a hit on alpha tested geometry lands on a drawn part of it.
bool rayCandidateSolid(FrameConstants frame, uint instance_index, uint primitive, float2 barycentric) {
    Instance instance = frame.instances.data[instance_index];
    Material material = loadAligned<16>(frame.materials.data + instance.material);
    if ((material.flags & MATERIAL_ALPHA_TEST) == 0u) return true;
    Mesh mesh = loadAligned<16>(frame.meshes.data + instance.mesh);
    uint base = mesh.index_offset + primitive * 3u;
    Vertex v0 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base]];
    Vertex v1 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]];
    Vertex v2 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]];
    float3 lambda = barycentricWeights(barycentric);
    float alpha = material.base_color.a * (unpackUnorm(v0.color).a * lambda.x + unpackUnorm(v1.color).a * lambda.y + unpackUnorm(v2.color).a * lambda.z);
    if (material.base_color_texture != INVALID_ID) {
        float2 uv = (material.uv_sets & 1u) != 0u
            ? v0.uv1 * lambda.x + v1.uv1 * lambda.y + v2.uv1 * lambda.z
            : v0.uv * lambda.x + v1.uv * lambda.y + v2.uv * lambda.z;
        alpha *= sampleTextureLod(material.base_color_texture, material.sampler_index, materialUv(material, uv), 0.0).a;
    }
    return alpha >= material.alpha_cutoff;
}

#ifdef SOFTWARE_RAYS
struct BvhNode {
    float3 lo;
    uint first;
    float3 hi;
    uint count;
};

struct BvhInstance {
    float3x4 to_mesh;
    uint instance;
    uint pad0;
    uint pad1;
    uint pad2;
};

float traceBox(float3 lo, float3 hi, float3 origin, float3 inverse, float nearest) {
    float3 a = (lo - origin) * inverse;
    float3 b = (hi - origin) * inverse;
    float3 enter = min(a, b);
    float3 leave = max(a, b);
    float t_enter = max(max(enter.x, enter.y), max(enter.z, 0.0));
    float t_leave = min(min(leave.x, leave.y), min(leave.z, nearest));
    return t_enter <= t_leave ? t_enter : -1.0;
}

float3 traceInverse(float3 direction) {
    return 1.0 / select(abs(direction) < 1e-20, float3(1e-20), direction);
}

/// The scene as rays see it, walked in the shader: a tree of instances over a
/// tree of triangles per mesh. It has no ray masks and takes cut-out surfaces
/// whole.
struct Tracer {
    FrameConstants frame;
    BvhNode* scene_nodes;
    BvhInstance* scene_instances;
    BvhNode* mesh_nodes;
    uint* mesh_items;

    bool mesh(Instance instance, uint instance_index, float3 origin, float3 direction, bool any_hit, inout float nearest, inout TraceHit hit) {
        Mesh mesh = loadAligned<16>(frame.meshes.data + instance.mesh);
        if (mesh.bvh == INVALID_ID) return false;
        float3 inverse = traceInverse(direction);
        uint root = mesh.bvh;
        BvhNode top = mesh_nodes[root];
        if (traceBox(top.lo, top.hi, origin, inverse, nearest) < 0.0) return false;
        bool found = false;
        uint stack[32];
        int depth = 0;
        uint current = root;
        while (true) {
            BvhNode node = mesh_nodes[current];
            if (node.count != 0u) {
                for (uint i = 0u; i < node.count; i++) {
                    uint primitive = mesh_items[node.first + i];
                    uint base = mesh.index_offset + primitive * 3u;
                    float3 p0 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base]].position;
                    float3 p1 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]].position;
                    float3 p2 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]].position;
                    float3 edge1 = p1 - p0;
                    float3 edge2 = p2 - p0;
                    float3 across = cross(direction, edge2);
                    float determinant = dot(edge1, across);
                    if (abs(determinant) < 1e-20) continue;
                    float scale = 1.0 / determinant;
                    float3 from = origin - p0;
                    float u = dot(from, across) * scale;
                    if (u < 0.0 || u > 1.0) continue;
                    float3 other = cross(from, edge1);
                    float v = dot(direction, other) * scale;
                    if (v < 0.0 || u + v > 1.0) continue;
                    float t = dot(edge2, other) * scale;
                    if (t <= 1e-6 || t >= nearest) continue;
                    nearest = t;
                    hit.t = t;
                    hit.instance = instance_index;
                    hit.primitive = primitive;
                    hit.barycentric = float2(u, v);
                    found = true;
                    if (any_hit) return true;
                }
                if (depth == 0) break;
                current = stack[--depth];
                continue;
            }
            uint left = root + node.first;
            BvhNode a = mesh_nodes[left];
            BvhNode b = mesh_nodes[left + 1u];
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

    bool walk(float3 origin, float3 direction, float reach, bool any_hit, out TraceHit hit) {
        hit.t = reach;
        hit.instance = 0u;
        hit.primitive = 0u;
        hit.barycentric = float2(0.0);
        float nearest = reach;
        float3 inverse = traceInverse(direction);
        BvhNode top = scene_nodes[0];
        if (traceBox(top.lo, top.hi, origin, inverse, nearest) < 0.0) return false;
        bool found = false;
        uint stack[32];
        int depth = 0;
        uint current = 0u;
        while (true) {
            BvhNode node = scene_nodes[current];
            if (node.count != 0u) {
                for (uint i = 0u; i < node.count; i++) {
                    BvhInstance placed = scene_instances[node.first + i];
                    Instance instance = frame.instances.data[placed.instance];
                    float3 mesh_origin = mul(placed.to_mesh, float4(origin, 1.0));
                    float3 mesh_direction = mul(placed.to_mesh, float4(direction, 0.0));
                    if (mesh(instance, placed.instance, mesh_origin, mesh_direction, any_hit, nearest, hit)) {
                        found = true;
                        if (any_hit) return true;
                    }
                }
                if (depth == 0) break;
                current = stack[--depth];
                continue;
            }
            uint left = node.first;
            BvhNode a = scene_nodes[left];
            BvhNode b = scene_nodes[left + 1u];
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

    bool closest(float3 origin, float3 direction, float reach, uint mask, Cutouts cutouts, out TraceHit hit) {
        return walk(origin, direction, reach, false, hit);
    }

    bool any(float3 origin, float3 direction, float reach, uint mask, Cutouts cutouts) {
        TraceHit hit;
        return walk(origin, direction, reach, true, hit);
    }
};

#else
/// The scene as rays see it. Every shader that traces goes through this.
struct Tracer {
    FrameConstants frame;
    uint64_t scene;

    RayDesc ray(float3 origin, float3 direction, float reach) {
        RayDesc result;
        result.Origin = origin;
        result.Direction = direction;
        result.TMin = 0.0;
        result.TMax = reach;
        return result;
    }

    bool closest(float3 origin, float3 direction, float reach, uint mask, Cutouts cutouts, out TraceHit hit) {
        hit.t = reach;
        hit.instance = 0u;
        hit.primitive = 0u;
        hit.barycentric = float2(0.0);
        RayQuery<RAY_FLAG_NONE> query;
        query.TraceRayInline(RaytracingAccelerationStructure(scene), cutouts == Cutouts.cut ? RAY_FLAG_NONE : RAY_FLAG_FORCE_OPAQUE, mask, ray(origin, direction, reach));
        while (query.Proceed()) {
            if (query.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE &&
                rayCandidateSolid(frame, query.CandidateInstanceID(), query.CandidatePrimitiveIndex(), query.CandidateTriangleBarycentrics()))
                query.CommitNonOpaqueTriangleHit();
        }
        if (query.CommittedStatus() != COMMITTED_TRIANGLE_HIT) return false;
        hit.t = query.CommittedRayT();
        hit.instance = query.CommittedInstanceID();
        hit.primitive = query.CommittedPrimitiveIndex();
        hit.barycentric = query.CommittedTriangleBarycentrics();
        return true;
    }

    bool any(float3 origin, float3 direction, float reach, uint mask, Cutouts cutouts) {
        RayQuery<RAY_FLAG_NONE> query;
        uint flags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | (cutouts == Cutouts.cut ? RAY_FLAG_NONE : RAY_FLAG_FORCE_OPAQUE);
        query.TraceRayInline(RaytracingAccelerationStructure(scene), flags, mask, ray(origin, direction, reach));
        while (query.Proceed()) {
            if (query.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE &&
                rayCandidateSolid(frame, query.CandidateInstanceID(), query.CandidatePrimitiveIndex(), query.CandidateTriangleBarycentrics()))
                query.CommitNonOpaqueTriangleHit();
        }
        return query.CommittedStatus() != COMMITTED_NOTHING;
    }
};

#endif

#endif
