#version 460
#ifdef RAY_TRACED
#extension GL_EXT_ray_query : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#endif
#include "common.glsl"
#ifdef RAY_TRACED
#include "rt.glsl"
#endif

// Screen-space reflections: marches the reflection ray through the depth buffer
// and outputs the hit color with a confidence; zero confidence falls back to
// the sky.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint depth_texture;
    uint color_texture;
    uint reflection_texture;
    uint surface_texture;
    float max_roughness;
    float thickness;
    float max_distance;
    int step_count;
    // Last frame's result, or INVALID_ID.
    uint history_texture;
    float history_blend;
#ifdef RAY_TRACED
    // TLAS: rays are traced where the screen has no answer.
    uint64_t tlas;
#endif
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_reflection;

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 pixel = min(ivec2(in_uv * frame.resolution), ivec2(frame.resolution) - 1);
    out_reflection = vec4(0.0);
    float depth = texelFetch(TEX(push.depth_texture, nearest), pixel, 0).r;
    if (depth <= 0.0) return;
    vec4 mirror = texelFetch(TEX(push.reflection_texture, nearest), pixel, 0);
    float roughness = mirror.a;
    if (roughness >= push.max_roughness || dot(mirror.rgb, vec3(1.0)) < 1e-4) return;

    vec3 normal = decodeNormal(texelFetch(TEX(push.surface_texture, nearest), pixel, 0).rg);
    vec3 position = worldPositionFromDepth(in_uv, depth, frame.inv_view_proj);
    vec3 incoming = normalize(position - frame.camera_position);
    vec3 direction = reflect(incoming, normal);
    float view_depth = linearDepth(depth, frame.near);
    vec3 origin = position + normal * (0.01 + view_depth * 0.004);
    float reach = min(push.max_distance, view_depth * 6.0 + 2.0);

    // Fixed jitter: a temporal pattern makes thin reflections sparkle.
    float jitter = interleavedGradientNoise(gl_FragCoord.xy, 0u);
    float previous_t = 0.0;
    float hit_t = -1.0;
    for (int i = 0; i < push.step_count; i++) {
        float fraction = (float(i) + jitter) / float(push.step_count);
        float t = reach * fraction * fraction;
        vec4 clip = frame.view_proj * vec4(origin + direction * t, 1.0);
        if (clip.w <= frame.near) break;
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;
        float scene = linearDepth(textureLod(TEX(push.depth_texture, nearest), uv, 0.0).r, frame.near);
        float behind = clip.w - scene;
        if (behind > 0.0 && behind < push.thickness + (t - previous_t)) {
            hit_t = t;
            break;
        }
        previous_t = t;
    }
    vec4 result = vec4(0.0);
    if (hit_t >= 0.0) {

    // Binary search refinement.
    float low = previous_t;
    float high = hit_t;
    for (int i = 0; i < 5; i++) {
        float middle = 0.5 * (low + high);
        vec4 clip = frame.view_proj * vec4(origin + direction * middle, 1.0);
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
        float scene = linearDepth(textureLod(TEX(push.depth_texture, nearest), uv, 0.0).r, frame.near);
        if (clip.w > scene) high = middle; else low = middle;
    }
    vec4 clip = frame.view_proj * vec4(origin + direction * high, 1.0);
    vec2 hit_uv = clip.xy / clip.w * 0.5 + 0.5;
    float scene = linearDepth(textureLod(TEX(push.depth_texture, nearest), hit_uv, 0.0).r, frame.near);
    if (abs(clip.w - scene) <= push.thickness) {

    vec2 border = min(hit_uv, 1.0 - hit_uv);
    float confidence = smoothstep(0.0, 0.08, min(border.x, border.y));
    confidence *= 1.0 - smoothstep(push.max_roughness * 0.6, push.max_roughness, roughness);
    confidence *= 1.0 - smoothstep(0.75, 1.0, high / reach);
    confidence *= 1.0 - smoothstep(0.5, 0.9, dot(direction, -incoming));
    vec3 color = textureLod(TEX(push.color_texture, frame.sampler_linear_clamp), hit_uv, 0.0).rgb;
    result = vec4(color, confidence);
    }
    }

#ifdef RAY_TRACED
    if (result.a < 0.999) {
        vec3 radiance;
        float distance_hit;
        int met = rtTracePicture(frame, push.tlas, origin, direction, push.max_distance, 1.0 + roughness * 8.0, radiance, distance_hit);
        if ((frame.flags & FRAME_FLUID_RAYS) != 0u) {
            if (met != RT_MISS) radiance = rtThroughFluids(frame, origin, direction, distance_hit, radiance);
        }
        if (met != RT_MISS) {
            float fade = 1.0 - smoothstep(push.max_roughness * 0.6, push.max_roughness, roughness);
            fade *= 1.0 - smoothstep(0.75, 1.0, distance_hit / push.max_distance);
            vec3 blended = mix(radiance, result.rgb, result.a);
            result = vec4(blended, max(result.a, fade));
        }
    }
#endif
    if (push.history_texture != INVALID_ID) {
        vec4 previous = frame.prev_view_proj_unjittered * vec4(position, 1.0);
        vec2 previous_uv = previous.xy / previous.w * 0.5 + 0.5;
        if (previous.w > 0.0 && all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0)))) {
            vec4 history = textureLod(TEX(push.history_texture, frame.sampler_linear_clamp), previous_uv, 0.0);
            // Premultiplied by confidence.
            vec4 blended = mix(vec4(history.rgb * history.a, history.a), vec4(result.rgb * result.a, result.a), push.history_blend);
            result = vec4(blended.a > 1e-4 ? blended.rgb / blended.a : vec3(0.0), blended.a);
        }
    }
    out_reflection = result;
}
