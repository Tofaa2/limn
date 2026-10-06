#version 460
#include "common.glsl"

// Forward pass for blended materials: one indexed draw per instance.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint instance_index;
} push;

layout(location = 0) out vec3 out_position;
layout(location = 1) out vec3 out_normal;
layout(location = 2) out vec4 out_tangent;
layout(location = 3) out vec2 out_uv;
// Clip-space position now and last frame, both without jitter, for
// motion vectors.
layout(location = 4) out vec4 out_clip;
layout(location = 5) out vec4 out_previous_clip;
layout(location = 6) out vec4 out_vertex_color;
layout(location = 7) out vec2 out_uv1;

void main() {
    Instance instance = push.frame.instances.data[push.instance_index];
    Vertex vertex = push.frame.vertices.data[instance.vertex_offset + gl_VertexIndex];
    vec4 world = instance.transform * vec4(vertex.position, 1.0);
    float sway = push.frame.materials.data[instance.material].sway;
    if (sway != 0.0) world.xyz += swayOffset(sway, instance.transform[3].xyz, world.xyz, push.frame.time);
    mat3 normal_matrix = transpose(inverse(mat3(instance.transform)));
    out_position = world.xyz;
    out_normal = normal_matrix * vertexNormal(vertex);
    vec4 tangent = vertexTangent(vertex);
    out_tangent = vec4(mat3(instance.transform) * tangent.xyz, tangent.w);
    out_uv = vertex.uv;
    out_vertex_color = unpackUnorm4x8(vertex.color);
    out_uv1 = vertex.uv1;
    gl_Position = push.frame.view_proj * world;
    Vertex previous = push.frame.vertices.data[instance.previous_vertex_offset + gl_VertexIndex];
    out_clip = push.frame.view_proj_unjittered * world;
    vec4 previous_world = instance.previous_transform * vec4(previous.position, 1.0);
    if (sway != 0.0) previous_world.xyz += swayOffset(sway, instance.previous_transform[3].xyz, previous_world.xyz, push.frame.time - push.frame.delta_time);
    out_previous_clip = push.frame.prev_view_proj_unjittered * previous_world;
}
