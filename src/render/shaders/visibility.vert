#version 460
#include "common.glsl"

#include "visibility_page.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint tinted;
    uint paged;
    mat4 view_proj;
    vec4 lod;
    float lod_band;
    float lod_near;
    uvec2 list;
    uvec2 count;
    VisibilityPage page;
} push;

layout(location = 0) flat out uint out_id;
layout(location = 1) flat out uint out_material;
layout(location = 2) out vec2 out_uv;
layout(location = 3) flat out vec2 out_fade;

#include "visibility_vertex.glsl"

void main() {
    VisibilityVertex vertex = visibilityVertex(uint(gl_InstanceIndex), uint(gl_VertexIndex));
    gl_Position = vertex.position;
    gl_ClipDistance[0] = vertex.inside.x;
    gl_ClipDistance[1] = vertex.inside.y;
    gl_ClipDistance[2] = vertex.inside.z;
    gl_ClipDistance[3] = vertex.inside.w;
    out_id = vertex.id;
    out_material = vertex.material;
    out_uv = vertex.uv;
    out_fade = vertex.fade;
}
