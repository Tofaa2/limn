#version 460
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint64_t tlas;
    mat4 transform;
    uint vertex_offset;
    uint gathered_texture;
    uint rounds;
    uint rays;
    float reach;
} push;

layout(location = 0) out vec3 out_position;
layout(location = 1) out vec3 out_normal;

void main() {
    Vertex vertex = push.frame.vertices.data[push.vertex_offset + gl_VertexIndex];
    out_position = (push.transform * vec4(vertex.position, 1.0)).xyz;
    out_normal = transpose(inverse(mat3(push.transform))) * vertexNormal(vertex);
    gl_Position = vec4(vertex.uv1 * 2.0 - 1.0, 0.5, 1.0);
}
