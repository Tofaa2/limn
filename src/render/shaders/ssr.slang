#include "ray_light.slang"
#include "common.slang"
#include "shading.slang"

#ifdef RAY_TRACED
#else
#endif

struct TracePush {
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

[[vk::push_constant]] TracePush trace_push;

float sceneDepth(FrameConstants frame, float2 uv) {
    return linearDepth(sampleTextureLod(trace_push.depth_texture, frame.sampler_nearest_clamp, uv, 0.0).r, frame.depth_terms);
}

/// The reflection the screen holds along a ray, with how far it can be
/// trusted in alpha; zero where the ray leaves the screen or meets nothing.
float4 screenReflection(FrameConstants frame, float3 origin, float3 direction, float3 incoming, float reach, float roughness, float jitter) {
    float previous_t = 0.0;
    float hit_t = -1.0;
    for (int i = 0; i < trace_push.step_count; i++) {
        float fraction = (float(i) + jitter) / float(trace_push.step_count);
        float t = reach * fraction * fraction;
        float4 clip = mul(frame.view_proj, float4(origin + direction * t, 1.0));
        float along = clipDepth(frame, clip);
        if (along <= frame.near) break;
        float2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (any(uv < 0.0) || any(uv > 1.0)) break;
        float behind = along - sceneDepth(frame, uv);
        if (behind > 0.0 && behind < trace_push.thickness + (t - previous_t)) {
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
    if (abs(clipDepth(frame, clip) - sceneDepth(frame, hit_uv)) > trace_push.thickness) return float4(0.0);

    float2 border = min(hit_uv, 1.0 - hit_uv);
    float confidence = smoothstep(0.0, 0.08, min(border.x, border.y));
    confidence *= 1.0 - smoothstep(trace_push.max_roughness * 0.6, trace_push.max_roughness, roughness);
    confidence *= 1.0 - smoothstep(0.75, 1.0, high / reach);
    confidence *= 1.0 - smoothstep(0.5, 0.9, dot(direction, -incoming));
    return float4(sampleTextureLod(trace_push.color_texture, frame.sampler_linear_clamp, hit_uv, 0.0).rgb, confidence);
}

[shader("fragment")]
float4 traceMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = trace_push.frame;
    int2 pixel = min(int2(in_uv * frame.resolution), int2(frame.resolution) - 1);
    float depth = fetchTexel(trace_push.depth_texture, pixel).r;
    if (depth <= 0.0) return float4(0.0);
    float4 mirror = fetchTexel(trace_push.reflection_texture, pixel);
    float roughness = mirror.a;
    if (roughness >= trace_push.max_roughness || dot(mirror.rgb, float3(1.0)) < 1e-4) return float4(0.0);

    float3 normal = decodeNormal(fetchTexel(trace_push.surface_texture, pixel).rg);
    float3 position = worldPositionFromDepth(in_uv, depth, frame.inv_view_proj);
    float3 incoming = normalize(position - eyePoint(frame, position));
    float3 direction = reflect(incoming, normal);
    float view_depth = linearDepth(depth, frame.depth_terms);
    float3 origin = position + normal * (0.01 + view_depth * 0.004);
    float reach = min(trace_push.max_distance, view_depth * 6.0 + 2.0);

    float4 result = screenReflection(frame, origin, direction, incoming, reach, roughness, interleavedGradientNoise(fragment.xy, 0u));

#ifdef RAY_TRACED
    if (result.a < 0.999) {
        Tracer tracer;
        tracer.frame = frame;
        tracer.scene = trace_push.tlas;
        LitRay seen = tracePicture(tracer, origin, direction, trace_push.max_distance, 1.0 + roughness * 8.0);
        if (seen.met != RAY_MISS) {
            float3 radiance = throughFluids(frame, origin, direction, seen.distance, seen.radiance);
            float fade = 1.0 - smoothstep(trace_push.max_roughness * 0.6, trace_push.max_roughness, roughness);
            fade *= 1.0 - smoothstep(0.75, 1.0, seen.distance / trace_push.max_distance);
            result = float4(lerp(radiance, result.rgb, result.a), max(result.a, fade));
        }
    }
#endif
    float own = luminance(sampleTextureLod(trace_push.color_texture, frame.sampler_linear_clamp, in_uv, 0.0).rgb);
    float ceiling = (own + 0.02) * lerp(256.0, 3.0, smoothstep(0.08, 0.35, roughness));
    result.rgb *= min(1.0, ceiling / max(luminance(result.rgb), 1e-6));
    if (trace_push.history_texture != INVALID_ID) {
        float4 previous = mul(frame.prev_view_proj_unjittered, float4(position, 1.0));
        float2 previous_uv = previous.xy / previous.w * 0.5 + 0.5;
        if (previous.w > 0.0 && all(previous_uv >= 0.0) && all(previous_uv <= 1.0)) {
            float4 history = sampleTextureLod(trace_push.history_texture, frame.sampler_linear_clamp, previous_uv, 0.0);
            float4 blended = lerp(float4(history.rgb * history.a, history.a), float4(result.rgb * result.a, result.a), trace_push.history_blend);
            result = float4(blended.a > 1e-4 ? blended.rgb / blended.a : float3(0.0), blended.a);
        }
    }
    return result;
}

struct CompositePush {
    FrameConstants frame;
    uint depth_texture;
    uint reflection_texture;
    uint surface_texture;
    uint traced_texture;
    float max_roughness;
    int blur_taps;
    uint reduced;
};

[[vk::push_constant]] CompositePush composite_push;

struct Output {
    float4 color : SV_Target0;
};

[shader("fragment")]
Output compositeMain(
    [[vk::location(0)]] float2 in_uv,
    float4 fragment : SV_Position) {
    Output result;
    FrameConstants frame = composite_push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    int2 pixel = int2(fragment.xy);
    float depth = fetchTexel(composite_push.depth_texture, pixel).r;
    float4 mirror = fetchTexel(composite_push.reflection_texture, pixel);
    if (depth <= 0.0 || dot(mirror.rgb, float3(1.0)) < 1e-4) discard;
    float4 surface = fetchTexel(composite_push.surface_texture, pixel);
    float4 traced;
    if (composite_push.reduced == 0u) {
        traced = fetchTexel(composite_push.traced_texture, pixel);
    } else {
        float2 traced_size = float2(int2(textureSize(composite_push.traced_texture)));
        float2 at = in_uv * traced_size - 0.5;
        int2 base = int2(floor(at));
        float2 f = at - float2(base);
        float center_depth = linearDepth(depth, frame.depth_terms);
        float4 total = float4(0.0);
        float weight_total = 0.0;
        for (int i = 0; i < 4; i++) {
            int2 offset = int2(i & 1, i >> 1);
            int2 texel = clamp(base + offset, int2(0), int2(traced_size) - 1);
            int2 source = min(int2((float2(texel) + 0.5) / traced_size * frame.resolution), int2(frame.resolution) - 1);
            float tap_depth = linearDepth(fetchTexel(composite_push.depth_texture, source).r, frame.depth_terms);
            float weight = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);
            weight *= 1.0 - smoothstep(0.02, 0.1, abs(tap_depth - center_depth) / center_depth);
            float4 tap = fetchTexel(composite_push.traced_texture, texel);
            total += float4(tap.rgb * tap.a, tap.a) * weight;
            weight_total += weight;
        }
        traced = weight_total > 1e-4 ? float4(total.a > 1e-4 ? total.rgb / total.a : float3(0.0), total.a / weight_total) : float4(0.0);
    }
    if (composite_push.blur_taps > 0 && mirror.a > 0.02 && mirror.a < composite_push.max_roughness) {
        float radius = mirror.a * mirror.a * 0.09 * frame.resolution.y;
        float spin = interleavedGradientNoise(fragment.xy, frame.frame_index) * 6.2831853;
        float center_depth = linearDepth(depth, frame.depth_terms);
        float calm = min(mirror.a * 16.0, 4.0);
        float center_weight = 1.0 / (1.0 + luminance(traced.rgb) * calm);
        float4 total = float4(traced.rgb * traced.a, traced.a) * center_weight;
        float weight_total = center_weight;
        for (int i = 0; i < composite_push.blur_taps; i++) {
            float distance_pixels = radius * sqrt((float(i) + 0.5) / float(composite_push.blur_taps));
            float angle = float(i) * 2.39996323 + spin;
            float2 uv = in_uv + float2(cos(angle), sin(angle)) * distance_pixels * frame.inv_resolution;
            float tap_depth = linearDepth(sampleTextureLod(composite_push.depth_texture, nearest, uv, 0.0).r, frame.depth_terms);
            float weight = 1.0 - smoothstep(0.02, 0.1, abs(tap_depth - center_depth) / center_depth);
            float4 tap = sampleTextureLod(composite_push.traced_texture, frame.sampler_linear_clamp, uv, 0.0);
            weight /= 1.0 + luminance(tap.rgb) * calm;
            total += float4(tap.rgb * tap.a, tap.a) * weight;
            weight_total += weight;
        }
        total /= weight_total;
        traced = float4(total.a > 1e-4 ? total.rgb / total.a : float3(0.0), total.a);
    }

    float3 sky = float3(0.0);
    if (((frame.flags & FRAME_ENVIRONMENT) != 0u || frame.probe_count != 0u) && traced.a < 1.0) {
        float3 position = worldPositionFromDepth(in_uv, depth, frame.inv_view_proj);
        float3 view = normalize(eyePoint(frame, position) - position);
        sky = ambientReflection(frame, position, view, decodeNormal(surface.rg), mirror.a, surface.b);
    }
    result.color = float4(mirror.rgb * lerp(sky, traced.rgb, traced.a), 0.0);
    return result;
}
