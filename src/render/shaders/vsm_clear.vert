#version 460
#include "common.glsl"
#include "vsm.glsl"

// Clears virtual shadow map pages about to be redrawn: a far-depth rectangle
// over each.
layout(push_constant, scalar) uniform Push {
    VsmPageViews page_views;
} push;

void main() {
    vec4 bounds = push.page_views.data[gl_InstanceIndex].bounds;
    vec2 corner = vec2(gl_VertexIndex == 1 || gl_VertexIndex == 4 || gl_VertexIndex == 5 ? bounds.z : bounds.x, gl_VertexIndex == 2 || gl_VertexIndex == 3 || gl_VertexIndex == 5 ? bounds.w : bounds.y);
    gl_Position = vec4(corner, 1.0, 1.0);
}
