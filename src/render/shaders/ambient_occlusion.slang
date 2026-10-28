#include "common.slang"

#include "ambient_occlusion.DepthPush.slang"

[[vk::push_constant]] DepthPush depth_push;

static const float sky_depth = 60000.0;

[shader("fragment")]
float depthMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    if (depth_push.first != 0u) {
        float depth = sampleTextureLod(depth_push.source_texture, depth_push.sampler_index, in_uv, 0.0).r;
        return min(linearDepth(depth, depth_push.terms), sky_depth);
    }
    int2 base = int2(fragment.xy) * 2;
    int2 limit = textureSizeLod(depth_push.source_texture, depth_push.source_lod) - 1;
    float a = fetchTexelLod(depth_push.source_texture, min(base, limit), depth_push.source_lod).r;
    float b = fetchTexelLod(depth_push.source_texture, min(base + int2(1, 0), limit), depth_push.source_lod).r;
    float c = fetchTexelLod(depth_push.source_texture, min(base + int2(0, 1), limit), depth_push.source_lod).r;
    float d = fetchTexelLod(depth_push.source_texture, min(base + int2(1, 1), limit), depth_push.source_lod).r;
    float farthest = max(max(a, b), max(c, d));
    float4 depths = float4(a, b, c, d);
    float4 weights = clamp(1.0 - (farthest - depths) / (farthest * 0.1 + 1e-4), 0.0, 1.0);
    return dot(depths, weights) / dot(weights, float4(1.0));
}

#include "ambient_occlusion.GtaoPush.slang"

[[vk::push_constant]] GtaoPush gtao_push;

struct GtaoOutput {
    float2 ao : SV_Target0;
    float4 bounce : SV_Target1;
};

static const float sky_threshold = 50000.0;

float3 viewPosition(FrameConstants frame, float2 uv, float mip) {
    float z = sampleTextureLod(gtao_push.depth_texture, frame.sampler_nearest_clamp, uv, mip).r;
    float2 ndc = uv * 2.0 - 1.0;
    if (frame.parallel != 0.0) {
        ndc -= float2(frame.proj[0][3], frame.proj[1][3]);
        return float3(ndc.x / frame.proj[0][0], ndc.y / frame.proj[1][1], -z);
    }
    ndc += float2(frame.proj[0][2], frame.proj[1][2]);
    return float3(ndc.x / frame.proj[0][0], ndc.y / frame.proj[1][1], -1.0) * z;
}

[shader("fragment")]
GtaoOutput gtaoMain([[vk::location(0)]] float2 in_uv, float4 pixel : SV_Position) {
    FrameConstants frame = gtao_push.frame;
    GtaoOutput result;
    float3 position = viewPosition(frame, in_uv, 0.0);
    if (-position.z > sky_threshold) {
        result.ao = float2(1.0, -position.z);
        result.bounce = float4(0.0);
        return result;
    }
    float2 depth_size = textureSize(gtao_push.depth_texture);
    float2 texel = 1.0 / depth_size;
    float3 left = viewPosition(frame, in_uv - float2(texel.x, 0.0), 0.0);
    float3 right = viewPosition(frame, in_uv + float2(texel.x, 0.0), 0.0);
    float3 up = viewPosition(frame, in_uv - float2(0.0, texel.y), 0.0);
    float3 down = viewPosition(frame, in_uv + float2(0.0, texel.y), 0.0);
    float3 dx = abs(left.z - position.z) < abs(right.z - position.z) ? position - left : right - position;
    float3 dy = abs(up.z - position.z) < abs(down.z - position.z) ? position - up : down - position;
    float3 normal = normalize(cross(dx, dy));
    bool parallel = frame.parallel != 0.0;
    float3 toward = parallel ? float3(0.0, 0.0, 1.0) : -position;
    if (dot(normal, toward) < 0.0) normal = -normal;
    float3 view = normalize(toward);

    float projected = gtao_push.radius * 0.5 * abs(frame.proj[1][1]) / (parallel ? 1.0 : -position.z);
    float2 radius_uv = float2(projected * frame.resolution.y / frame.resolution.x, projected);
    radius_uv = min(radius_uv, float2(0.15));
    float pixel_radius = radius_uv.y * depth_size.y;
    if (pixel_radius < 1.5) {
        result.ao = float2(1.0, -position.z);
        result.bounce = float4(0.0);
        return result;
    }

    float noise_direction = interleavedGradientNoise(pixel.xy, frame.frame_index);
    float noise_offset = frac(noise_direction * 7.31 + 0.37);
    float falloff_end = gtao_push.radius * gtao_push.radius;
    float visibility = 0.0;
    float3 bounce = float3(0.0);
    bool gather = gtao_push.color_texture != INVALID_ID;
    float ceiling = gather ? (luminance(sampleTextureLod(gtao_push.color_texture, frame.sampler_linear_clamp, in_uv, 0.0).rgb) + 0.05) * 6.0 : 0.0;

    for (int slice = 0; slice < gtao_push.slice_count; slice++) {
        float phi = (float(slice) + noise_direction) * PI / float(gtao_push.slice_count);
        float2 omega = float2(cos(phi), sin(phi));
        float3 direction = float3(omega.x, -omega.y, 0.0);
        float3 ortho_direction = direction - dot(direction, view) * view;
        float3 axis = normalize(cross(direction, view));
        float3 projected_normal = normal - axis * dot(normal, axis);
        float projected_length = length(projected_normal);
        float sign_n = sign(dot(ortho_direction, projected_normal));
        float cos_n = clamp(dot(projected_normal, view) / max(projected_length, 1e-5), 0.0, 1.0);
        float n = sign_n * acos(cos_n);

        float horizon_cos[2] = { -1.0, -1.0 };
        for (int side = 0; side < 2; side++) {
            float direction_sign = side == 0 ? 1.0 : -1.0;
            for (int tap_index = 0; tap_index < gtao_push.step_count; tap_index++) {
                float t = (float(tap_index) + noise_offset) / float(gtao_push.step_count);
                float reach = t * t + 0.5 / pixel_radius;
                float2 sample_uv = in_uv + direction_sign * omega * radius_uv * reach;
                float mip = clamp(log2(reach * pixel_radius) - 2.5, 0.0, 4.0);
                float3 delta = viewPosition(frame, sample_uv, floor(mip)) - position;
                float distance_squared = dot(delta, delta);
                float cos_horizon = dot(delta, view) * rsqrt(max(distance_squared, 1e-8));
                float falloff = clamp(distance_squared / falloff_end * 2.0 - 1.0, 0.0, 1.0);
                float candidate = lerp(cos_horizon, -1.0, falloff);
                if (candidate > horizon_cos[side]) {
                    if (gather) {
                        float facing = max(dot(normal, delta) * rsqrt(max(distance_squared, 1e-8)), 0.0);
                        float slice_width = candidate - max(horizon_cos[side], -0.2);
                        if (slice_width > 0.0) {
                            float3 seen = sampleTextureLod(gtao_push.color_texture, frame.sampler_linear_clamp, sample_uv, 0.0).rgb;
                            bounce += seen * min(1.0, ceiling / max(luminance(seen), 1e-6)) * (facing * slice_width);
                        }
                    }
                    horizon_cos[side] = candidate;
                }
            }
        }
        float h0 = n + clamp(-acos(horizon_cos[1]) - n, -PI * 0.5, PI * 0.5);
        float h1 = n + clamp(acos(horizon_cos[0]) - n, -PI * 0.5, PI * 0.5);
        float arc0 = (cos_n + 2.0 * h0 * sin(n) - cos(2.0 * h0 - n)) * 0.25;
        float arc1 = (cos_n + 2.0 * h1 * sin(n) - cos(2.0 * h1 - n)) * 0.25;
        visibility += projected_length * (arc0 + arc1);
    }
    visibility /= float(gtao_push.slice_count);
    result.ao = float2(pow(clamp(visibility, 0.0, 1.0), gtao_push.intensity), -position.z);
    result.bounce = float4(min(bounce / float(gtao_push.slice_count * 2), float3(64.0)), 1.0);
    return result;
}

#include "ambient_occlusion.DenoisePush.slang"

[[vk::push_constant]] DenoisePush denoise_push;

struct DenoiseOutput {
    float ao : SV_Target0;
#ifdef BOUNCE
    float4 bounce : SV_Target1;
#endif
};

[shader("fragment")]
DenoiseOutput denoiseMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) {
    FrameConstants frame = denoise_push.frame;
    float raw_depth = fetchTexel(denoise_push.depth_texture, int2(fragment.xy)).r;
    float center = linearDepth(raw_depth, frame.depth_terms);
    float lowest = 1e9;
    float highest = 0.0;
    float total = 0.0;
#ifdef BOUNCE
    float3 bounce_lowest = float3(1e9);
    float3 bounce_highest = float3(0.0);
    float3 bounce_total = float3(0.0);
#endif
    int2 ao_size = int2(textureSize(denoise_push.ao_texture));
    float2 position = in_uv * float2(ao_size) - 0.5;
    int2 base = int2(floor(position));
    float2 f = position - float2(base);
    float weight_total = 0.0;
    for (int y = -1; y <= 2; y++) {
        for (int x = -1; x <= 2; x++) {
            int2 tap = clamp(base + int2(x, y), int2(0), ao_size - 1);
            float2 ao_depth = fetchTexel(denoise_push.ao_texture, tap).rg;
            float depth = ao_depth.g;
            float2 offset = float2(x, y) - f;
            float spatial = exp(-dot(offset, offset) * 0.45);
            float range = max(0.0, 1.0 - abs(depth - center) / (center * 0.04));
            float weight = spatial * range + 1e-5;
            total += ao_depth.r * weight;
            if (range > 0.0) {
                lowest = min(lowest, ao_depth.r);
                highest = max(highest, ao_depth.r);
            }
#ifdef BOUNCE
            float3 light = fetchTexel(denoise_push.bounce_texture, tap).rgb;
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
    bool reproject = denoise_push.history_texture != INVALID_ID;
#ifdef BOUNCE
    float3 bounce = bounce_total / weight_total;
    reproject = reproject || denoise_push.bounce_history_texture != INVALID_ID;
#endif
    if (reproject && raw_depth > 0.0) {
        float3 world = worldPositionFromDepth(in_uv, raw_depth, frame.inv_view_proj);
        float4 previous = mul(frame.prev_view_proj_unjittered, float4(world, 1.0));
        float2 previous_uv = previous.xy / previous.w * 0.5 + 0.5;
        if (previous.w > 0.0 && all(previous_uv >= 0.0) && all(previous_uv <= 1.0)) {
            if (denoise_push.history_texture != INVALID_ID) {
                float history = sampleTextureLod(denoise_push.history_texture, frame.sampler_linear_clamp, previous_uv, 0.0).r;
                history = clamp(history, min(lowest, ao), max(highest, ao));
                ao = lerp(history, ao, denoise_push.history_blend);
            }
#ifdef BOUNCE
            if (denoise_push.bounce_history_texture != INVALID_ID) {
                float3 history = sampleTextureLod(denoise_push.bounce_history_texture, frame.sampler_linear_clamp, previous_uv, 0.0).rgb;
                history = clamp(history, min(bounce_lowest, bounce), max(bounce_highest, bounce));
                bounce = lerp(history, bounce, denoise_push.history_blend);
            }
#endif
        }
    }
    DenoiseOutput result;
    result.ao = ao;
#ifdef BOUNCE
    result.bounce = float4(bounce, 1.0);
#endif
    return result;
}
