#version 460
#include "common.glsl"

// Depth of field: every pixel gathers its surroundings over a disc whose
// size depends on how far the surface is from the focus distance.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint color_texture;
    uint depth_texture;
    float focus_distance;
    // Blur radius in pixels of something infinitely far away.
    float strength;
    float max_radius;
    int tap_count;
    // Blades of the aperture: out-of-focus highlights take the shape of a
    // polygon with this many sides; fewer than 3 for a round one.
    uint blades;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

// Distance in focus; taken from the middle of the picture when the push
// constant asks for autofocus (a negative distance).
float focus_distance;

float blurRadius(float view_depth) {
    return min(push.strength * abs(view_depth - focus_distance) / max(view_depth, 1e-3), push.max_radius);
}

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    uint linear = frame.sampler_linear_clamp;
    focus_distance = push.focus_distance;
    // Autofocus: the distance eased toward the middle of the picture,
    // kept with the exposure state.
    if (focus_distance < 0.0) focus_distance = max(frame.exposure.focus, frame.near);
    float center_depth = linearDepth(textureLod(TEX(push.depth_texture, nearest), in_uv, 0.0).r, frame.near);
    float center_radius = blurRadius(center_depth);
    vec3 total = textureLod(TEX(push.color_texture, linear), in_uv, 0.0).rgb;
    float weight_total = 1.0;
    // A golden-angle spiral covers the largest possible disc evenly.
    float spin = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index) * 6.2831853;
    for (int i = 0; i < push.tap_count; i++) {
        float distance_pixels = push.max_radius * sqrt((float(i) + 0.5) / float(push.tap_count));
        float angle = float(i) * 2.39996323 + spin;
        // How far out on a round disc this tap is: what a blur radius has
        // to reach for the tap to count, whatever the shape pulls it in to.
        float reach = distance_pixels;
        if (push.blades >= 3u) {
            // Pull the disc in to the polygon the blades leave open, by
            // the direction the tap actually lies in.
            float sector = 6.2831853 / float(push.blades);
            float within = mod(angle, sector) - 0.5 * sector;
            distance_pixels *= cos(0.5 * sector) / cos(within);
        }
        vec2 uv = in_uv + vec2(cos(angle), sin(angle)) * distance_pixels * frame.inv_resolution;
        float tap_depth = linearDepth(textureLod(TEX(push.depth_texture, nearest), uv, 0.0).r, frame.near);
        float tap_radius = blurRadius(tap_depth);
        // Something behind this pixel may only smear over it as far as
        // this pixel itself is blurred; otherwise a sharp subject would
        // collect its blurry background.
        if (tap_depth > center_depth) tap_radius = min(tap_radius, center_radius);
        // The tap contributes if its own blur disc reaches this pixel.
        float weight = smoothstep(reach - 1.0, reach + 1.0, tap_radius);
        total += textureLod(TEX(push.color_texture, linear), uv, 0.0).rgb * weight;
        weight_total += weight;
    }
    // Alpha: how blurred this pixel is, for joining a reduced-resolution
    // gather back onto the sharp picture.
    out_color = vec4(total / weight_total, clamp(center_radius / max(push.max_radius, 1e-3), 0.0, 1.0));
}
