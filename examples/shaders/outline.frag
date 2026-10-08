#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint depth_texture;
    float strength;
    vec2 pad;
    vec4 color;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

float viewDepth(ivec2 pixel) {
    FrameConstants frame = push.frame;
    ivec2 limit = ivec2(frame.resolution) - 1;
    float depth = texelFetch(TEX(push.depth_texture, frame.sampler_nearest_clamp), clamp(pixel, ivec2(0), limit), 0).r;
    return depth > 0.0 ? linearDepth(depth, frame.near) : 1e6;
}

void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float center = viewDepth(pixel);
    float nearest = min(min(viewDepth(pixel + ivec2(1, 0)), viewDepth(pixel - ivec2(1, 0))),
        min(viewDepth(pixel + ivec2(0, 1)), viewDepth(pixel - ivec2(0, 1))));
    float edge = smoothstep(0.08, 0.25, (center - nearest) / center);
    out_color = vec4(push.color.rgb, push.color.a * edge * push.strength);
}
