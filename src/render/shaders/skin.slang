#include "common.slang"

struct MorphDelta {
    float3 position;
    float3 normal;
    float3 tangent;
};

struct SkinJob {
    uint source_offset;
    uint destination_offset;
    uint skin_offset;
    uint joint_offset;
    uint vertex_count;
    uint morph_offset;
    uint target_count;
    uint first_group;
    uint weights_offset;
    uint job_pad0;
    uint job_pad1;
    uint job_pad2;
};

static const uint GROUPS_PER_ROW = 1024u;

struct SkinPush {
    Vertex* vertices;
    SkinVertex* skin;
    float4x4* joints;
    MorphDelta* morph;
    SkinJob* jobs;
    uint* group_jobs;
    float* weights;
    uint group_count;
};

[[vk::push_constant]] SkinPush skin_push;

[shader("compute")]
[numthreads(64, 1, 1)]
void skinMain(uint3 workgroup : SV_GroupID, uint3 local : SV_GroupThreadID) {
    uint group = workgroup.y * GROUPS_PER_ROW + workgroup.x;
    if (group >= skin_push.group_count) return;
    SkinJob job = skin_push.jobs[skin_push.group_jobs[group]];
    uint index = (group - job.first_group) * 64u + local.x;
    if (index >= job.vertex_count) return;
    Vertex vertex = skin_push.vertices[job.source_offset + index];
    float3 normal = vertexNormal(vertex);
    float4 tangent = vertexTangent(vertex);
    for (uint target = 0u; target < job.target_count; target++) {
        float weight = skin_push.weights[job.weights_offset + target];
        if (weight == 0.0) continue;
        MorphDelta delta = skin_push.morph[job.morph_offset + target * job.vertex_count + index];
        vertex.position += delta.position * weight;
        normal += delta.normal * weight;
        tangent.xyz += delta.tangent * weight;
    }
    SkinVertex influence = skin_push.skin[job.skin_offset + index];
    float4x4 blend =
        skin_push.joints[job.joint_offset + influence.joints.x] * influence.weights.x +
        skin_push.joints[job.joint_offset + influence.joints.y] * influence.weights.y +
        skin_push.joints[job.joint_offset + influence.joints.z] * influence.weights.z +
        skin_push.joints[job.joint_offset + influence.joints.w] * influence.weights.w;
    float3x3 rotation = (float3x3)blend;
    vertex.position = mul(blend, float4(vertex.position, 1.0)).xyz;
    vertex.normal = packDirection(mul(rotation, normal));
    vertex.tangent = packTangent(float4(mul(rotation, tangent.xyz), tangent.w));
    skin_push.vertices[job.destination_offset + index] = vertex;
}

struct BoundsJob {
    uint vertex_offset;
    uint meshlet_offset;
    uint meshlet_count;
    uint bounds_offset;
    uint first_group;
    uint job_pad0;
    uint job_pad1;
    uint job_pad2;
};

struct BoundsPush {
    Vertices vertices;
    Indices indices;
    Meshlets meshlets;
    float4* bounds;
    BoundsJob* jobs;
    uint* group_jobs;
    uint group_count;
};

[[vk::push_constant]] BoundsPush bounds_push;

[shader("compute")]
[numthreads(64, 1, 1)]
void boundsMain(uint3 workgroup : SV_GroupID, uint3 local : SV_GroupThreadID) {
    uint group = workgroup.y * GROUPS_PER_ROW + workgroup.x;
    if (group >= bounds_push.group_count) return;
    BoundsJob job = bounds_push.jobs[bounds_push.group_jobs[group]];
    uint index = (group - job.first_group) * 64u + local.x;
    if (index >= job.meshlet_count) return;
    Meshlet meshlet = bounds_push.meshlets.data[job.meshlet_offset + index];
    float3 low = float3(1e30);
    float3 high = float3(-1e30);
    for (uint corner = 0u; corner < meshlet.index_count; corner++) {
        float3 position = bounds_push.vertices.data[job.vertex_offset + bounds_push.indices.data[meshlet.index_offset + corner]].position;
        low = min(low, position);
        high = max(high, position);
    }
    float3 center = (low + high) * 0.5;
    float reach = 0.0;
    for (uint corner = 0u; corner < meshlet.index_count; corner++) {
        float3 position = bounds_push.vertices.data[job.vertex_offset + bounds_push.indices.data[meshlet.index_offset + corner]].position;
        float3 offset = position - center;
        reach = max(reach, dot(offset, offset));
    }
    bounds_push.bounds[job.bounds_offset + index] = float4(center, sqrt(reach));
}
