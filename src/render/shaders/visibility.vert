#version 460
#include "common.glsl"

// Visibility and shadow passes: vertices are pulled from the global buffers by
// the draw's meshlet reference.
#include "visibility_page.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    // 1 in a shadow pass whose translucent casters go into the tint pass.
    uint tinted;
    // Nonzero when `page` supplies the view.
    uint paged;
    mat4 view_proj;
    // LOD cross-fade, main camera pass only: LOD camera (xyz), error-to-pixels
    // scale (w), band width (1 for none) and near plane.
    vec4 lod;
    float lod_band;
    float lod_near;
    // Used by the mesh shader path (visibility.task).
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
