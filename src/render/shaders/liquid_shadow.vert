#version 460
#include "common.glsl"
#include "liquid.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    LiquidRef liquid;
    LiquidParticles particles;
    mat4 view_proj;
    float swell;
    float strength;
} push;

layout(location = 0) out vec2 out_corner;
layout(location = 1) flat out uint out_slot;

void main() {
    LiquidData liquid = push.liquid.data;
    uint slot = uint(gl_VertexIndex) / 6u;
    const vec2 corners[6] = vec2[](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));
    vec2 corner = corners[gl_VertexIndex % 6];
    out_corner = corner;
    out_slot = slot;
    if (slot >= liquid.live) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        return;
    }
    vec3 world = (liquid.from_box * vec4(push.particles.data[slot].position, 1.0)).xyz;
    vec3 across = normalize(vec3(push.view_proj[0][0], push.view_proj[1][0], push.view_proj[2][0]));
    vec3 up = normalize(vec3(push.view_proj[0][1], push.view_proj[1][1], push.view_proj[2][1]));
    float radius = liquid.radius * push.swell;
    gl_Position = push.view_proj * vec4(world + (across * corner.x + up * corner.y) * radius, 1.0);
}
