#version 460
#include "common.glsl"
#include "water.glsl"

layout(push_constant, scalar) uniform Push {
    WaterRef water;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_state;

vec2 state(ivec2 cell, ivec2 size) {
    cell = clamp(cell, ivec2(0), size - 1);
    return texelFetch(TEX(push.water.data.state_texture, push.water.data.sampler_linear), cell, 0).rg;
}

void main() {
    WaterRef water = push.water;
    ivec2 size = water.data.size;
    ivec2 cell = ivec2(gl_FragCoord.xy);
    vec2 here = state(cell, size);
    float around = state(cell + ivec2(1, 0), size).r + state(cell - ivec2(1, 0), size).r +
        state(cell + ivec2(0, 1), size).r + state(cell - ivec2(0, 1), size).r;
    float dt = min(water.data.dt, 0.65 / max(water.data.speed, 1e-6));
    float courant = water.data.speed * dt;
    float velocity = (here.g + courant * courant * (around - 4.0 * here.r) / max(dt, 1e-5)) * water.data.keep;
    float height = here.r + velocity * dt;
    height *= exp(-dt * 0.02);
    vec2 uv = (vec2(cell) + 0.5) / vec2(size);
    for (uint i = 0u; i < water.data.ripple_count; i++) {
        WaterRipple ripple = water.data.ripples[i];
        vec2 offset = (uv - ripple.position) / max(ripple.radius, 1e-4);
        float away = dot(offset, offset);
        height -= ripple.depth * (1.0 - 2.0 * away) * exp(-away * 2.0);
    }
    out_state = vec4(height, velocity, 0.0, 0.0);
}
