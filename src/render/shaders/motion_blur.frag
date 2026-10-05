#version 460
#include "common.glsl"

// Motion blur: smears each pixel along the path it travelled during the
// part of the frame the shutter was open.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint color_texture;
    uint motion_texture;
    // Fraction of the frame the shutter is open.
    float shutter;
    // Longest smear, as a fraction of the screen.
    float max_length;
    int tap_count;
    // 1 lets fast things smear over what is next to them.
    uint spread;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    FrameConstants frame = push.frame;
    uint linear = frame.sampler_linear_clamp;
    uint nearest = frame.sampler_nearest_clamp;
    vec2 own = textureLod(TEX(push.motion_texture, nearest), in_uv, 0.0).rg * push.shutter;
    float noise = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index);
    // Lengths are compared in pixels.
    vec2 pixels = frame.resolution;
    vec2 motion = own;
    if (push.spread != 0u) {
        // Something moving fast next to this pixel smears over it even if
        // the pixel itself is still: look around for the fastest thing
        // whose smear reaches here.
        float fastest = length(own * pixels);
        for (int i = 0; i < 8; i++) {
            float angle = (float(i) + noise) * 0.78539816;
            float radius = push.max_length * 0.5 * sqrt((float(i) + 0.5) / 8.0);
            vec2 offset = vec2(cos(angle), sin(angle)) * radius * vec2(pixels.y / pixels.x, 1.0);
            vec2 there = textureLod(TEX(push.motion_texture, nearest), in_uv + offset, 0.0).rg * push.shutter;
            float speed = length(there * pixels);
            if (speed > fastest && speed * 0.5 >= length(offset * pixels)) {
                fastest = speed;
                motion = there;
            }
        }
    }
    float travelled = length(motion);
    vec3 center = textureLod(TEX(push.color_texture, linear), in_uv, 0.0).rgb;
    // Less than about a pixel: nothing to blur.
    if (travelled * frame.resolution.y < 1.0) {
        out_color = vec4(center, 1.0);
        return;
    }
    if (travelled > push.max_length) motion *= push.max_length / travelled;
    float offset = noise - 0.5;
    float own_reach = length(own * pixels) * 0.5;
    vec3 total = vec3(0.0);
    for (int i = 0; i < push.tap_count; i++) {
        // Centered on the pixel: half the smear behind, half ahead.
        float t = (float(i) + 0.5 + offset) / float(push.tap_count) - 0.5;
        vec2 uv = in_uv - motion * t;
        float weight = 1.0;
        if (push.spread != 0u) {
            // A tap counts if what is there moves far enough to reach this
            // pixel, or if this pixel moves far enough to reach it; a
            // still background does not smear over a moving thing's trail.
            float distance_pixels = length(motion * t * pixels);
            float tap_reach = length(textureLod(TEX(push.motion_texture, nearest), uv, 0.0).rg * push.shutter * pixels) * 0.5;
            weight = clamp(max(tap_reach, own_reach) - distance_pixels + 1.0, 0.0, 1.0);
        }
        // Where a tap does not count, the pixel shows what it shows unblurred.
        total += mix(center, textureLod(TEX(push.color_texture, linear), uv, 0.0).rgb, weight);
    }
    out_color = vec4(total / float(push.tap_count), 1.0);
}
