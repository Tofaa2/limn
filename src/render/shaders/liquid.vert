#version 460
#include "common.glsl"
#include "liquid.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    LiquidRef liquid;
    LiquidParticles particles;
    uint depth_texture;
    float swell;
} push;

layout(location = 0) out vec2 out_corner;
layout(location = 1) out vec4 out_sphere;

void main() {
    FrameConstants frame = push.frame;
    LiquidData liquid = push.liquid.data;
    uint slot = uint(gl_VertexIndex) / 6u;
    const vec2 corners[6] = vec2[](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));
    vec2 corner = corners[gl_VertexIndex % 6];
    if (slot >= liquid.live) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        out_corner = corner;
        out_sphere = vec4(0.0);
        return;
    }
    vec3 world = (liquid.from_box * vec4(push.particles.data[slot].position, 1.0)).xyz;
    vec3 center = (frame.view * vec4(world, 1.0)).xyz;
    float radius = liquid.radius * push.swell;
    out_corner = corner;
    out_sphere = vec4(center, radius);
    gl_Position = frame.proj * vec4(center + vec3(corner * radius, 0.0), 1.0);
}
