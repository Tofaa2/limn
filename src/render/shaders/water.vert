#version 460
#include "common.glsl"
#include "water.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    WaterRef water;
    uint depth_texture;
    uint scene_texture;
    uint quads;
} push;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec3 out_position;

void main() {
    uint quad = uint(gl_VertexIndex) / 6u;
    const vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1));
    vec2 corner = corners[gl_VertexIndex % 6];
    vec2 uv = (vec2(quad % push.quads, quad / push.quads) + corner) / float(push.quads);
    vec3 world = waterPoint(push.water, uv, push.frame.time);
    out_uv = uv;
    out_position = world;
    gl_Position = push.frame.view_proj * vec4(world, 1.0);
}
