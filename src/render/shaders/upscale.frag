#version 460
#include "common.glsl"

// Brings a picture rendered below (or above) the output resolution to it,
// with a bicubic filter that keeps edges crisper than plain bilinear.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    uint s = push.frame.sampler_linear_clamp;
    vec2 size = vec2(textureSize(TEX(push.source_texture, s), 0));
    // 5-tap approximation of bicubic Catmull-Rom (Jimenez, SIGGRAPH 2016).
    vec2 position = in_uv * size;
    vec2 center = floor(position - 0.5) + 0.5;
    vec2 f = position - center;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 tc0 = (center - 1.0) / size;
    vec2 tc12 = (center + w2 / w12) / size;
    vec2 tc3 = (center + 2.0) / size;
    vec4 result =
        vec4(textureLod(TEX(push.source_texture, s), vec2(tc12.x, tc0.y), 0.0).rgb, 1.0) * (w12.x * w0.y) +
        vec4(textureLod(TEX(push.source_texture, s), vec2(tc0.x, tc12.y), 0.0).rgb, 1.0) * (w0.x * w12.y) +
        vec4(textureLod(TEX(push.source_texture, s), vec2(tc12.x, tc12.y), 0.0).rgb, 1.0) * (w12.x * w12.y) +
        vec4(textureLod(TEX(push.source_texture, s), vec2(tc3.x, tc12.y), 0.0).rgb, 1.0) * (w3.x * w12.y) +
        vec4(textureLod(TEX(push.source_texture, s), vec2(tc12.x, tc3.y), 0.0).rgb, 1.0) * (w12.x * w3.y);
    out_color = vec4(max(result.rgb / result.a, vec3(0.0)), 1.0);
}
