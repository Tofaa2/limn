#version 460
#include "common.glsl"
#include "shading.glsl"

// Adds reflections to the lit image: the traced result where confident, the sky
// elsewhere.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint depth_texture;
    uint reflection_texture;
    uint surface_texture;
    uint traced_texture;
    float max_roughness;
    // Roughness blur taps; 0 for none.
    int blur_taps;
    // 1 when the trace is at reduced resolution.
    uint reduced;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(TEX(push.depth_texture, nearest), pixel, 0).r;
    vec4 mirror = texelFetch(TEX(push.reflection_texture, nearest), pixel, 0);
    if (depth <= 0.0 || dot(mirror.rgb, vec3(1.0)) < 1e-4) discard;
    vec4 surface = texelFetch(TEX(push.surface_texture, nearest), pixel, 0);
    vec4 traced;
    if (push.reduced == 0u) {
        traced = texelFetch(TEX(push.traced_texture, nearest), pixel, 0);
    } else {
        vec2 traced_size = vec2(textureSize(TEX(push.traced_texture, nearest), 0));
        vec2 at = in_uv * traced_size - 0.5;
        ivec2 base = ivec2(floor(at));
        vec2 f = at - vec2(base);
        float center_depth = linearDepth(depth, frame.near);
        vec4 total = vec4(0.0);
        float weight_total = 0.0;
        for (int i = 0; i < 4; i++) {
            ivec2 offset = ivec2(i & 1, i >> 1);
            ivec2 texel = clamp(base + offset, ivec2(0), ivec2(traced_size) - 1);
            ivec2 source = min(ivec2((vec2(texel) + 0.5) / traced_size * frame.resolution), ivec2(frame.resolution) - 1);
            float tap_depth = linearDepth(texelFetch(TEX(push.depth_texture, nearest), source, 0).r, frame.near);
            float weight = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);
            weight *= 1.0 - smoothstep(0.02, 0.1, abs(tap_depth - center_depth) / center_depth);
            vec4 tap = texelFetch(TEX(push.traced_texture, nearest), texel, 0);
            total += vec4(tap.rgb * tap.a, tap.a) * weight;
            weight_total += weight;
        }
        traced = weight_total > 1e-4 ? vec4(total.a > 1e-4 ? total.rgb / total.a : vec3(0.0), total.a / weight_total) : vec4(0.0);
    }
    if (push.blur_taps > 0 && mirror.a > 0.02 && mirror.a < push.max_roughness) {
        float radius = mirror.a * mirror.a * 0.09 * frame.resolution.y;
        float spin = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index) * 6.2831853;
        float center_depth = linearDepth(depth, frame.near);
        // Premultiplied by confidence.
        vec4 total = vec4(traced.rgb * traced.a, traced.a);
        float weight_total = 1.0;
        for (int i = 0; i < push.blur_taps; i++) {
            float distance_pixels = radius * sqrt((float(i) + 0.5) / float(push.blur_taps));
            float angle = float(i) * 2.39996323 + spin;
            vec2 uv = in_uv + vec2(cos(angle), sin(angle)) * distance_pixels * frame.inv_resolution;
            float tap_depth = linearDepth(textureLod(TEX(push.depth_texture, nearest), uv, 0.0).r, frame.near);
            float weight = 1.0 - smoothstep(0.02, 0.1, abs(tap_depth - center_depth) / center_depth);
            vec4 tap = textureLod(TEX(push.traced_texture, frame.sampler_linear_clamp), uv, 0.0);
            total += vec4(tap.rgb * tap.a, tap.a) * weight;
            weight_total += weight;
        }
        total /= weight_total;
        traced = vec4(total.a > 1e-4 ? total.rgb / total.a : vec3(0.0), total.a);
    }

    vec3 sky = vec3(0.0);
    if (((frame.flags & FRAME_ENVIRONMENT) != 0u || frame.probe_count != 0u) && traced.a < 1.0) {
        vec3 position = worldPositionFromDepth(in_uv, depth, frame.inv_view_proj);
        vec3 view = normalize(frame.camera_position - position);
        sky = ambientReflection(frame, position, view, decodeNormal(surface.rg), mirror.a, surface.b);
    }
    out_color = vec4(mirror.rgb * mix(sky, traced.rgb, traced.a), 0.0);
}
