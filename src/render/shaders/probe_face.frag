#version 460
#include "common.glsl"
#include "environment.glsl"

layout(push_constant, scalar) uniform Push {
    uint source_texture;
    uint sampler_index;
    uint face;
    float max_radiance;
    vec3 right;
    vec3 up;
    vec3 forward;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    vec3 direction = cubeDirection(push.face, in_uv);
    vec2 across = vec2(dot(direction, push.right), dot(direction, push.up)) / max(dot(direction, push.forward), 1e-4);
    vec2 uv = clamp(vec2(across.x * 0.5 + 0.5, 0.5 - across.y * 0.5), vec2(0.0), vec2(1.0));
    vec3 color = textureLod(TEX(push.source_texture, push.sampler_index), uv, 0.0).rgb;
    out_color = vec4(min(max(color, vec3(0.0)), vec3(push.max_radiance)), 1.0);
}
