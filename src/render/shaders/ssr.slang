#ifdef RAY_TRACED
#include "ray_light.slang"
#else
#include "common.slang"
#endif

struct Push {
    FrameConstants frame;
    uint depth_texture;
    uint color_texture;
    uint reflection_texture;
    uint surface_texture;
    float max_roughness;
    float thickness;
    float max_distance;
    int step_count;
    uint history_texture;
    float history_blend;
#ifdef RAY_TRACED
    uint64_t tlas;
#endif
};

[[vk::push_constant]] Push push;

float sceneDepth(FrameConstants frame, float2 uv) {
    return linearDepth(sampleTextureLod(push.depth_texture, frame.sampler_nearest_clamp, uv, 0.0).r, frame.depth_terms);
}

/// The reflection the screen holds along a ray, with how far it can be
/// trusted in alpha; zero where the ray leaves the screen or meets nothing.
float4 screenReflection(FrameConstants frame, float3 origin, float3 direction, float3 incoming, float reach, float roughness, float jitter) {
    float previous_t = 0.0;
    float hit_t = -1.0;
    for (int i = 0; i < push.step_count; i++) {
        float fraction = (float(i) + jitter) / float(push.step_count);
        float t = reach * fraction * fraction;
        float4 clip = mul(frame.view_proj, float4(origin + direction * t, 1.0));
        float along = clipDepth(frame, clip);
        if (along <= frame.near) break;
        float2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (any(uv < 0.0) || any(uv > 1.0)) break;
        float behind = along - sceneDepth(frame, uv);
        if (behind > 0.0 && behind < push.thickness + (t - previous_t)) {
            hit_t = t;
            break;
        }
        previous_t = t;
    }
    if (hit_t < 0.0) return float4(0.0);

    float low = previous_t;
    float high = hit_t;
    for (int i = 0; i < 5; i++) {
        float middle = 0.5 * (low + high);
        float4 clip = mul(frame.view_proj, float4(origin + direction * middle, 1.0));
        float2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (clipDepth(frame, clip) > sceneDepth(frame, uv)) high = middle; else low = middle;
    }
    float4 clip = mul(frame.view_proj, float4(origin + direction * high, 1.0));
    float2 hit_uv = clip.xy / clip.w * 0.5 + 0.5;
    if (abs(clipDepth(frame, clip) - sceneDepth(frame, hit_uv)) > push.thickness) return float4(0.0);

    float2 border = min(hit_uv, 1.0 - hit_uv);
    float confidence = smoothstep(0.0, 0.08, min(border.x, border.y));
    confidence *= 1.0 - smoothstep(push.max_roughness * 0.6, push.max_roughness, roughness);
    confidence *= 1.0 - smoothstep(0.75, 1.0, high / reach);
    confidence *= 1.0 - smoothstep(0.5, 0.9, dot(direction, -incoming));
    return float4(sampleTextureLod(push.color_texture, frame.sampler_linear_clamp, hit_uv, 0.0).rgb, confidence);
}

[shader("fragment")]
float4 fragmentMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = push.frame;
    int2 pixel = min(int2(in_uv * frame.resolution), int2(frame.resolution) - 1);
    float depth = fetchTexel(push.depth_texture, pixel).r;
    if (depth <= 0.0) return float4(0.0);
    float4 mirror = fetchTexel(push.reflection_texture, pixel);
    float roughness = mirror.a;
    if (roughness >= push.max_roughness || dot(mirror.rgb, float3(1.0)) < 1e-4) return float4(0.0);

    float3 normal = decodeNormal(fetchTexel(push.surface_texture, pixel).rg);
    float3 position = worldPositionFromDepth(in_uv, depth, frame.inv_view_proj);
    float3 incoming = normalize(position - eyePoint(frame, position));
    float3 direction = reflect(incoming, normal);
    float view_depth = linearDepth(depth, frame.depth_terms);
    float3 origin = position + normal * (0.01 + view_depth * 0.004);
    float reach = min(push.max_distance, view_depth * 6.0 + 2.0);

    float4 result = screenReflection(frame, origin, direction, incoming, reach, roughness, interleavedGradientNoise(fragment.xy, 0u));

#ifdef RAY_TRACED
    if (result.a < 0.999) {
        Tracer tracer;
        tracer.frame = frame;
        tracer.scene = push.tlas;
        LitRay seen = tracePicture(tracer, origin, direction, push.max_distance, 1.0 + roughness * 8.0);
        if (seen.met != RAY_MISS) {
            float3 radiance = throughFluids(frame, origin, direction, seen.distance, seen.radiance);
            float fade = 1.0 - smoothstep(push.max_roughness * 0.6, push.max_roughness, roughness);
            fade *= 1.0 - smoothstep(0.75, 1.0, seen.distance / push.max_distance);
            result = float4(lerp(radiance, result.rgb, result.a), max(result.a, fade));
        }
    }
#endif
    float own = luminance(sampleTextureLod(push.color_texture, frame.sampler_linear_clamp, in_uv, 0.0).rgb);
    float ceiling = (own + 0.02) * lerp(256.0, 3.0, smoothstep(0.08, 0.35, roughness));
    result.rgb *= min(1.0, ceiling / max(luminance(result.rgb), 1e-6));
    if (push.history_texture != INVALID_ID) {
        float4 previous = mul(frame.prev_view_proj_unjittered, float4(position, 1.0));
        float2 previous_uv = previous.xy / previous.w * 0.5 + 0.5;
        if (previous.w > 0.0 && all(previous_uv >= 0.0) && all(previous_uv <= 1.0)) {
            float4 history = sampleTextureLod(push.history_texture, frame.sampler_linear_clamp, previous_uv, 0.0);
            float4 blended = lerp(float4(history.rgb * history.a, history.a), float4(result.rgb * result.a, result.a), push.history_blend);
            result = float4(blended.a > 1e-4 ? blended.rgb / blended.a : float3(0.0), blended.a);
        }
    }
    return result;
}
