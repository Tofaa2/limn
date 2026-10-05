#version 460
#include "common.glsl"

// Joint bilateral upsample of the half-resolution GTAO result: blurs away
// the sampling noise while keeping occlusion from bleeding across depth
// discontinuities.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint ao_texture;
    uint depth_texture;
    // Last frame's result, or INVALID_ID to filter in space only.
    uint history_texture;
    float history_blend;
    // With BOUNCE: the gathered light to filter in place of the occlusion,
    // which is still read for the depth each sample was taken at.
    uint bounce_texture;
} push;

layout(location = 0) in vec2 in_uv;
#ifdef BOUNCE
#define VALUE vec3
#define READ(tap) texelFetch(TEX(push.bounce_texture, nearest), tap, 0).rgb
#define HISTORY(uv) textureLod(TEX(push.history_texture, frame.sampler_linear_clamp), uv, 0.0).rgb
layout(location = 0) out vec4 out_ao;
#else
#define VALUE float
#define READ(tap) ao_depth.r
#define HISTORY(uv) textureLod(TEX(push.history_texture, frame.sampler_linear_clamp), uv, 0.0).r
layout(location = 0) out float out_ao;
#endif

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    float raw_depth = texelFetch(TEX(push.depth_texture, nearest), ivec2(gl_FragCoord.xy), 0).r;
    float center = linearDepth(raw_depth, frame.near);
    VALUE lowest = VALUE(1e9);
    VALUE highest = VALUE(0.0);
    ivec2 ao_size = textureSize(TEX(push.ao_texture, nearest), 0);
    vec2 position = in_uv * vec2(ao_size) - 0.5;
    ivec2 base = ivec2(floor(position));
    vec2 f = position - vec2(base);
    VALUE total = VALUE(0.0);
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
            VALUE value = READ(tap);
            total += value * weight;
            if (range > 0.0) {
                lowest = min(lowest, value);
                highest = max(highest, value);
            }
            weight_total += weight;
        }
    }
    VALUE ao = total / weight_total;
    if (push.history_texture != INVALID_ID && raw_depth > 0.0) {
        // Where this surface point was last frame. Things that moved are
        // looked up in the wrong place; clamping to what this frame's
        // samples allow keeps that from showing as a trail.
        vec3 world = worldPositionFromDepth(in_uv, raw_depth, frame.inv_view_proj);
        vec4 previous = frame.prev_view_proj_unjittered * vec4(world, 1.0);
        vec2 previous_uv = previous.xy / previous.w * 0.5 + 0.5;
        if (previous.w > 0.0 && all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0)))) {
            VALUE history = HISTORY(previous_uv);
            history = clamp(history, min(lowest, ao), max(highest, ao));
            ao = mix(history, ao, push.history_blend);
        }
    }
#ifdef BOUNCE
    out_ao = vec4(ao, 1.0);
#else
    out_ao = ao;
#endif
}
