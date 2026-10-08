#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
    uint first_level;
    vec2 source_texel;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

vec3 tap(vec2 offset) {
    return textureLod(TEX(push.source_texture, push.frame.sampler_linear_clamp), in_uv + offset * push.source_texel, 0.0).rgb;
}

float karis(vec3 c) {
    return 1.0 / (1.0 + luminance(c));
}

void main() {
    vec3 a = tap(vec2(-2, -2));
    vec3 b = tap(vec2(0, -2));
    vec3 c = tap(vec2(2, -2));
    vec3 d = tap(vec2(-2, 0));
    vec3 e = tap(vec2(0, 0));
    vec3 f = tap(vec2(2, 0));
    vec3 g = tap(vec2(-2, 2));
    vec3 h = tap(vec2(0, 2));
    vec3 i = tap(vec2(2, 2));
    vec3 j = tap(vec2(-1, -1));
    vec3 k = tap(vec2(1, -1));
    vec3 l = tap(vec2(-1, 1));
    vec3 m = tap(vec2(1, 1));

    vec3 color;
    if (push.first_level != 0u) {
        vec3 g0 = (a + b + d + e) * 0.25;
        vec3 g1 = (b + c + e + f) * 0.25;
        vec3 g2 = (d + e + g + h) * 0.25;
        vec3 g3 = (e + f + h + i) * 0.25;
        vec3 g4 = (j + k + l + m) * 0.25;
        float w0 = karis(g0) * 0.125;
        float w1 = karis(g1) * 0.125;
        float w2 = karis(g2) * 0.125;
        float w3 = karis(g3) * 0.125;
        float w4 = karis(g4) * 0.5;
        color = (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / (w0 + w1 + w2 + w3 + w4);
    } else {
        color = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    }
    out_color = vec4(max(color, vec3(0.0)), 1.0);
}
