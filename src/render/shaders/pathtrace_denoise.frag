#version 460
#include "common.glsl"

// Clears the grain of a path-traced picture that has not gathered many
// frames yet. What is smoothed is the light arriving at each surface, not
// the surface's own color: each pixel is divided by the color of what it
// shows before its neighbours are averaged in and multiplied by it after,
// so textures stay sharp. Neighbours count by how nearly they lie in the
// same plane and how like their light is, and the likeness asked for
// grows with the frames gathered: a picture left alone is filtered less
// and less. Run twice, the second time with a wider step.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    // The picture (first run: light as gathered; second: already divided).
    uint color_texture;
    // The color of what each pixel shows; black where nothing is to be
    // smoothed (the sky, mirrors, what glows).
    uint guide_texture;
    uint depth_texture;
    // Pixels between samples.
    int step_size;
    uint gathered;
    // 0 for the first run, 1 for the second; 2 for a single run that
    // smooths nothing.
    uint last;
} push;

layout(location = 0) out vec4 out_color;

vec3 positionAt(FrameConstants frame, ivec2 pixel, out float depth) {
    depth = texelFetch(TEX(push.depth_texture, frame.sampler_nearest_clamp), pixel, 0).r;
    vec2 uv = (vec2(pixel) + 0.5) * frame.inv_resolution;
    return worldPositionFromDepth(uv, max(depth, 1e-6), frame.inv_view_proj);
}

vec3 lightAt(FrameConstants frame, ivec2 pixel, vec3 guide) {
    vec3 value = texelFetch(TEX(push.color_texture, frame.sampler_nearest_clamp), pixel, 0).rgb;
    // Already divided by the color of what it shows (pathtrace.frag).
    return value;
}

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    ivec2 last_pixel = ivec2(frame.resolution) - 1;
    vec3 guide = texelFetch(TEX(push.guide_texture, nearest), pixel, 0).rgb;
    vec4 own_texel = texelFetch(TEX(push.color_texture, nearest), pixel, 0);
    vec3 own_color = own_texel.rgb;
    // How many frames this pixel has gathered; carried in alpha.
    float frames = max(own_texel.a, 1.0);
    float depth;
    vec3 position = positionAt(frame, pixel, depth);
    bool colored = dot(guide, vec3(1.0)) > 0.0;
    if (!colored || depth <= 0.0 || push.last == 2u) {
        // Not smoothed (or, with 2 for `last`, nothing is): only the
        // color divided out when the light was gathered is put back,
        // once, by the run that ends the pass.
        out_color = vec4(colored && push.last != 0u ? own_color * max(guide, vec3(0.03)) : own_color, frames);
        return;
    }
    // The plane the pixel lies in, from its nearer neighbour each way.
    float depth_a;
    float depth_b;
    vec3 left = positionAt(frame, clamp(pixel - ivec2(1, 0), ivec2(0), last_pixel), depth_a);
    vec3 right = positionAt(frame, clamp(pixel + ivec2(1, 0), ivec2(0), last_pixel), depth_b);
    vec3 along_x = abs(depth_a - depth) < abs(depth_b - depth) ? position - left : right - position;
    vec3 up = positionAt(frame, clamp(pixel - ivec2(0, 1), ivec2(0), last_pixel), depth_a);
    vec3 down = positionAt(frame, clamp(pixel + ivec2(0, 1), ivec2(0), last_pixel), depth_b);
    vec3 along_y = abs(depth_a - depth) < abs(depth_b - depth) ? position - up : down - position;
    vec3 normal = normalize(cross(along_x, along_y));
    float distance_here = distance(position, frame.camera_position);

    vec3 own = lightAt(frame, pixel, guide);
    // What the light here is about, from the pixel and its ring: one
    // bright grain must not be the measure of its neighbours.
    vec3 around = own;
    float around_count = 1.0;
    for (int index = 0; index < 8; index++) {
        ivec2 offset = ivec2(index < 3 ? index - 1 : (index < 5 ? (index == 3 ? -1 : 1) : index - 6), index < 3 ? -1 : (index < 5 ? 0 : 1));
        ivec2 tap = clamp(pixel + offset * push.step_size, ivec2(0), last_pixel);
        vec3 tap_guide = texelFetch(TEX(push.guide_texture, nearest), tap, 0).rgb;
        if (dot(tap_guide, vec3(1.0)) <= 0.0) continue;
        around += lightAt(frame, tap, tap_guide);
        around_count += 1.0;
    }
    // A first frame's pixel says little about itself, so it is measured
    // by its ring; as frames are gathered it comes to be trusted, and
    // what differs from it (a highlight, a shadow's edge) is left out.
    float trust = 1.0 / pow(frames, 0.7);
    float reference = mix(luminance(own), luminance(around / around_count), trust);
    // How unlike a neighbour's light may be: wide for a first frame,
    // narrowing a little faster than the grain itself falls with the
    // frames gathered, so that shadows sharpen early.
    float allowed = (3.0 / pow(frames, 0.7)) * (reference + 0.02);

    vec3 total = vec3(0.0);
    float weight_total = 0.0;
    const float kernel[3] = float[](0.375, 0.25, 0.0625);
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            ivec2 tap = pixel + ivec2(x, y) * push.step_size;
            if (any(lessThan(tap, ivec2(0))) || any(greaterThan(tap, last_pixel))) continue;
            vec3 tap_guide = texelFetch(TEX(push.guide_texture, nearest), tap, 0).rgb;
            if (dot(tap_guide, vec3(1.0)) <= 0.0) continue;
            float tap_depth;
            vec3 tap_position = positionAt(frame, tap, tap_depth);
            if (tap_depth <= 0.0) continue;
            vec3 light = lightAt(frame, tap, tap_guide);
            float off_plane = abs(dot(normal, tap_position - position));
            float weight = kernel[abs(x)] * kernel[abs(y)];
            weight *= exp(-off_plane / (0.01 * distance_here + 1e-4));
            weight *= exp(-abs(luminance(light) - reference) / allowed);
            total += light * weight;
            weight_total += weight;
        }
    }
    vec3 smoothed = weight_total > 1e-6 ? total / weight_total : own;
    // A picture gathered for long is shown as it was traced.
    smoothed = mix(smoothed, own, clamp(frames / 4096.0, 0.0, 1.0));
    // A number that is not one must not leave this pass.
    if (any(isnan(smoothed)) || any(isinf(smoothed))) smoothed = any(isnan(own)) || any(isinf(own)) ? vec3(0.0) : own;
    out_color = vec4(push.last != 0u ? smoothed * max(guide, vec3(0.03)) : smoothed, frames);
}
