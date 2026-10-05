#version 460
#include "common.glsl"

// Example custom pass: outlines depth discontinuities over the finished
// picture. Lives outside the renderer and only uses its public interface.
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
    // Reverse-Z with an infinite far plane; the sky sits at depth 0.
    return depth > 0.0 ? linearDepth(depth, frame.near) : 1e6;
}

void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float center = viewDepth(pixel);
    float nearest = min(min(viewDepth(pixel + ivec2(1, 0)), viewDepth(pixel - ivec2(1, 0))),
        min(viewDepth(pixel + ivec2(0, 1)), viewDepth(pixel - ivec2(0, 1))));
    // Relative step towards the camera: this pixel is just behind an edge.
    float edge = smoothstep(0.08, 0.25, (center - nearest) / center);
    out_color = vec4(push.color.rgb, push.color.a * edge * push.strength);
}
