#version 460
#include "common.glsl"

// Draw lists: screen-space and world-space quads.
struct DrawVertex {
    vec3 position;
    vec2 offset;
    vec2 uv;
    uint color;
    uint texture_mode;
};

layout(buffer_reference, scalar) readonly buffer DrawVertices { DrawVertex data[]; };

layout(push_constant, scalar) uniform Push {
    DrawVertices vertices;
    Indices indices;
    // Pixels to clip space for screen batches, view-projection for world ones.
    mat4 transform;
    vec3 camera_right;
    uint encode_srgb;
    vec3 camera_up;
    float sdf_spread;
    vec2 viewport;
    uint sampler_linear;
    uint sampler_nearest;
    // Scene depth for world-space items, or INVALID_ID, and the view's origin
    // in the target.
    uint depth_texture;
    // HDR10 targets: white level in nits.
    float hdr_paper_white;
    vec2 origin;
} push;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;
layout(location = 2) flat out uint out_texture_mode;
// Per-shape flat data (half size of rounded rectangles).
layout(location = 3) flat out vec2 out_extra;

const uint MODE_LINE_3D = 5u;

vec3 srgbToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// Clips `p` toward `q` at the near plane.
vec4 clipNear(vec4 p, vec4 q) {
    const float epsilon = 1e-4;
    if (p.w >= epsilon) return p;
    return mix(p, q, (epsilon - p.w) / max(q.w - p.w, 1e-9));
}

void main() {
    DrawVertex vertex = push.vertices.data[push.indices.data[gl_VertexIndex]];
    uint mode = vertex.texture_mode >> 24;
    vec4 color = unpackUnorm4x8(vertex.color);
    out_color = vec4(srgbToLinear(color.rgb), color.a);
    out_texture_mode = vertex.texture_mode;
    out_uv = vertex.uv;
    out_extra = vertex.offset;

    if (mode == MODE_LINE_3D) {
        vec3 other = vec3(vertex.offset, vertex.uv.x);
        vec4 here = push.transform * vec4(vertex.position, 1.0);
        vec4 there = push.transform * vec4(other, 1.0);
        if (here.w < 1e-4 && there.w < 1e-4) {
            gl_Position = vec4(0.0, 0.0, 2.0, 1.0); // entirely behind the camera
            return;
        }
        vec4 clipped_here = clipNear(here, there);
        vec4 clipped_there = clipNear(there, here);
        vec2 direction = (clipped_there.xy / clipped_there.w - clipped_here.xy / clipped_here.w) * push.viewport;
        float len = length(direction);
        direction = len > 1e-6 ? direction / len : vec2(1.0, 0.0);
        vec2 normal = vec2(-direction.y, direction.x) * vertex.uv.y;
        clipped_here.xy += normal * 2.0 / push.viewport * clipped_here.w;
        gl_Position = clipped_here;
        out_uv = vec2(0.0);
        return;
    }

    vec3 position = vertex.position + push.camera_right * vertex.offset.x + push.camera_up * vertex.offset.y;
    gl_Position = push.transform * vec4(position, 1.0);
}
