#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    mat4 node;
    vec3 center;
    float radius;
    vec3 right;
    uint vertex_offset;
    vec3 up;
    uint material;
    vec3 toward;
    float pad;
} push;

layout(location = 0) out vec3 out_normal;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out vec4 out_vertex_color;

void main() {
    Vertex vertex = push.frame.vertices.data[push.vertex_offset + gl_VertexIndex];
    vec3 position = (push.node * vec4(vertex.position, 1.0)).xyz;
    vec3 from_middle = (position - push.center) / push.radius;
    out_normal = transpose(inverse(mat3(push.node))) * vertexNormal(vertex);
    out_uv = vertex.uv;
    out_vertex_color = unpackUnorm4x8(vertex.color);
    gl_Position = vec4(dot(from_middle, push.right), -dot(from_middle, push.up), 0.5 + 0.5 * dot(from_middle, push.toward), 1.0);
}
