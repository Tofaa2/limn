#version 460
#include "common.glsl"

// Motion blur along each pixel's motion vector.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint color_texture;
    uint motion_texture;
    // Shutter-open fraction of the frame.
    float shutter;
    // Maximum blur length, as a fraction of the screen.
    float max_length;
    int tap_count;
    // 1 lets fast neighbours blur over this pixel.
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
    vec2 pixels = frame.resolution;
    vec2 motion = own;
    if (push.spread != 0u) {
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
    if (travelled * frame.resolution.y < 1.0) {
        out_color = vec4(center, 1.0);
        return;
    }
    if (travelled > push.max_length) motion *= push.max_length / travelled;
    float offset = noise - 0.5;
    float own_reach = length(own * pixels) * 0.5;
    vec3 total = vec3(0.0);
    for (int i = 0; i < push.tap_count; i++) {
        float t = (float(i) + 0.5 + offset) / float(push.tap_count) - 0.5;
        vec2 uv = in_uv - motion * t;
        float weight = 1.0;
        if (push.spread != 0u) {
            // A tap counts if its motion reaches this pixel or this pixel's
            // reaches it.
            float distance_pixels = length(motion * t * pixels);
            float tap_reach = length(textureLod(TEX(push.motion_texture, nearest), uv, 0.0).rg * push.shutter * pixels) * 0.5;
            weight = clamp(max(tap_reach, own_reach) - distance_pixels + 1.0, 0.0, 1.0);
        }
        total += mix(center, textureLod(TEX(push.color_texture, linear), uv, 0.0).rgb, weight);
    }
    out_color = vec4(total / float(push.tap_count), 1.0);
}
