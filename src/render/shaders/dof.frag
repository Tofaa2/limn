#version 460
#include "common.glsl"

// Depth of field: gathers over a disc sized by the circle of confusion.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint color_texture;
    uint depth_texture;
    float focus_distance;
    // Blur radius in pixels at infinity.
    float strength;
    float max_radius;
    int tap_count;
    // Aperture blade count; fewer than 3 for a round bokeh.
    uint blades;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

// Focus distance; negative in the push constant selects autofocus.
float focus_distance;

float blurRadius(float view_depth) {
    return min(push.strength * abs(view_depth - focus_distance) / max(view_depth, 1e-3), push.max_radius);
}

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    uint linear = frame.sampler_linear_clamp;
    focus_distance = push.focus_distance;
    if (focus_distance < 0.0) focus_distance = max(frame.exposure.focus, frame.near);
    float center_depth = linearDepth(textureLod(TEX(push.depth_texture, nearest), in_uv, 0.0).r, frame.near);
    float center_radius = blurRadius(center_depth);
    vec3 total = textureLod(TEX(push.color_texture, linear), in_uv, 0.0).rgb;
    float weight_total = 1.0;
    // Golden-angle spiral.
    float spin = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index) * 6.2831853;
    for (int i = 0; i < push.tap_count; i++) {
        float distance_pixels = push.max_radius * sqrt((float(i) + 0.5) / float(push.tap_count));
        float angle = float(i) * 2.39996323 + spin;
        float reach = distance_pixels;
        if (push.blades >= 3u) {
            float sector = 6.2831853 / float(push.blades);
            float within = mod(angle, sector) - 0.5 * sector;
            distance_pixels *= cos(0.5 * sector) / cos(within);
        }
        vec2 uv = in_uv + vec2(cos(angle), sin(angle)) * distance_pixels * frame.inv_resolution;
        float tap_depth = linearDepth(textureLod(TEX(push.depth_texture, nearest), uv, 0.0).r, frame.near);
        float tap_radius = blurRadius(tap_depth);
        // Background taps are limited to this pixel's own blur radius.
        if (tap_depth > center_depth) tap_radius = min(tap_radius, center_radius);
        float weight = smoothstep(reach - 1.0, reach + 1.0, tap_radius);
        total += textureLod(TEX(push.color_texture, linear), uv, 0.0).rgb * weight;
        weight_total += weight;
    }
    // Alpha: normalized blur radius, for the composite.
    out_color = vec4(total / weight_total, clamp(center_radius / max(push.max_radius, 1e-3), 0.0, 1.0));
}
