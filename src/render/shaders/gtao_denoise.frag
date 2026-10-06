#version 460
#include "common.glsl"

// Joint bilateral upsample of the half-resolution GTAO result: blurs away
// the sampling noise while keeping occlusion from bleeding across depth
// discontinuities. With BOUNCE the light gathered along with the occlusion
// is filtered in the same pass: it shares the taps, their weights and the
// reprojection, so that costs little more than the occlusion alone.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint ao_texture;
    uint depth_texture;
    // Last frame's result, or INVALID_ID to filter in space only.
    uint history_texture;
    float history_blend;
    // With BOUNCE: the gathered light, and last frame's filtered light or
    // INVALID_ID.
    uint bounce_texture;
    uint bounce_history_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out float out_ao;
#ifdef BOUNCE
layout(location = 1) out vec4 out_bounce;
#endif

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    float raw_depth = texelFetch(TEX(push.depth_texture, nearest), ivec2(gl_FragCoord.xy), 0).r;
    float center = linearDepth(raw_depth, frame.near);
    float lowest = 1e9;
    float highest = 0.0;
    float total = 0.0;
#ifdef BOUNCE
    vec3 bounce_lowest = vec3(1e9);
    vec3 bounce_highest = vec3(0.0);
    vec3 bounce_total = vec3(0.0);
#endif
    ivec2 ao_size = textureSize(TEX(push.ao_texture, nearest), 0);
    vec2 position = in_uv * vec2(ao_size) - 0.5;
    ivec2 base = ivec2(floor(position));
    vec2 f = position - vec2(base);
    float weight_total = 0.0;
    for (int y = -1; y <= 2; y++) {
        for (int x = -1; x <= 2; x++) {
            ivec2 tap = clamp(base + ivec2(x, y), ivec2(0), ao_size - 1);
            // Each tap carries the depth it was computed at.
            vec2 ao_depth = texelFetch(TEX(push.ao_texture, nearest), tap, 0).rg;
            float depth = ao_depth.g;
            vec2 offset = vec2(x, y) - f;
            float spatial = exp(-dot(offset, offset) * 0.45);
            float range = max(0.0, 1.0 - abs(depth - center) / (center * 0.04));
            float weight = spatial * range + 1e-5;
            total += ao_depth.r * weight;
            if (range > 0.0) {
                lowest = min(lowest, ao_depth.r);
                highest = max(highest, ao_depth.r);
            }
#ifdef BOUNCE
            vec3 light = texelFetch(TEX(push.bounce_texture, nearest), tap, 0).rgb;
            bounce_total += light * weight;
            if (range > 0.0) {
                bounce_lowest = min(bounce_lowest, light);
                bounce_highest = max(bounce_highest, light);
            }
#endif
            weight_total += weight;
        }
    }
    float ao = total / weight_total;
    bool reproject = push.history_texture != INVALID_ID;
#ifdef BOUNCE
    vec3 bounce = bounce_total / weight_total;
    reproject = reproject || push.bounce_history_texture != INVALID_ID;
#endif
    if (reproject && raw_depth > 0.0) {
        // Where this surface point was last frame. Things that moved are
        // looked up in the wrong place; clamping to what this frame's
        // samples allow keeps that from showing as a trail.
        vec3 world = worldPositionFromDepth(in_uv, raw_depth, frame.inv_view_proj);
        vec4 previous = frame.prev_view_proj_unjittered * vec4(world, 1.0);
        vec2 previous_uv = previous.xy / previous.w * 0.5 + 0.5;
        if (previous.w > 0.0 && all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0)))) {
            if (push.history_texture != INVALID_ID) {
                float history = textureLod(TEX(push.history_texture, frame.sampler_linear_clamp), previous_uv, 0.0).r;
                history = clamp(history, min(lowest, ao), max(highest, ao));
                ao = mix(history, ao, push.history_blend);
            }
#ifdef BOUNCE
            if (push.bounce_history_texture != INVALID_ID) {
                vec3 history = textureLod(TEX(push.bounce_history_texture, frame.sampler_linear_clamp), previous_uv, 0.0).rgb;
                history = clamp(history, min(bounce_lowest, bounce), max(bounce_highest, bounce));
                bounce = mix(history, bounce, push.history_blend);
            }
#endif
        }
    }
    out_ao = ao;
#ifdef BOUNCE
    out_bounce = vec4(bounce, 1.0);
#endif
}
