#include "common.slang"

// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

static const float FFX_GAUSSIAN_K = 3.0;
static const float FFX_RADIANCE_WEIGHT_BIAS = 0.6;
static const float FFX_RADIANCE_WEIGHT_VARIANCE_K = 0.1;
static const float FFX_AVG_RADIANCE_LUMINANCE_WEIGHT = 0.3;
static const float FFX_PREFILTER_VARIANCE_WEIGHT = 4.4;
static const float FFX_REPROJECT_SURFACE_DISCARD_VARIANCE_WEIGHT = 1.5;
static const float FFX_PREFILTER_VARIANCE_BIAS = 0.1;
static const float FFX_PREFILTER_NORMAL_SIGMA = 512.0;
static const float FFX_PREFILTER_DEPTH_SIGMA = 4.0;
static const float FFX_DISOCCLUSION_NORMAL_WEIGHT = 1.4;
static const float FFX_DISOCCLUSION_DEPTH_WEIGHT = 1.0;
static const float FFX_DISOCCLUSION_THRESHOLD = 0.9;
static const float FFX_REPROJECTION_NORMAL_SIMILARITY_THRESHOLD = 0.9999;

float ffxSamplesForRoughness(float roughness) {
    return 1.0 - exp(-roughness * 100.0);
}

static const int FFX_LOCAL_NEIGHBORHOOD_RADIUS = 3;

static const float FFX_MAX_SAMPLES = 64.0;

static const float FFX_GLOSSY_ROUGHNESS = 0.4;

bool ffxIsGlossy(float roughness) {
    return roughness < FFX_GLOSSY_ROUGHNESS;
}

float ffxLuminance(float3 color) {
    return max(dot(color, float3(0.299, 0.587, 0.114)), 0.001);
}

float ffxTemporalVariance(float3 history_radiance, float3 radiance) {
    float history_luminance = ffxLuminance(history_radiance);
    float luminance = ffxLuminance(radiance);
    float difference = abs(history_luminance - luminance) / max(max(history_luminance, luminance), 0.5);
    return difference * difference;
}

float3 ffxClipAabb(float3 aabb_min, float3 aabb_max, float3 previous) {
    float3 center = 0.5 * (aabb_max + aabb_min);
    float3 extent = 0.5 * (aabb_max - aabb_min) + 0.001;
    float3 offset = previous - center;
    float3 unit = abs(offset / extent);
    float max_unit = max(max(unit.x, unit.y), unit.z);
    return max_unit > 1.0 ? center + offset / max_unit : previous;
}

float ffxLocalKernelWeight(float i) {
    float radius = float(FFX_LOCAL_NEIGHBORHOOD_RADIUS) + 1.0;
    return exp(-FFX_GAUSSIAN_K * (i * i) / (radius * radius));
}

float ffxDisocclusionFactor(float3 normal, float3 history_normal, float linear_depth, float history_linear_depth) {
    return exp(-abs(1.0 - max(0.0, dot(normal, history_normal))) * FFX_DISOCCLUSION_NORMAL_WEIGHT) *
        exp(-abs(history_linear_depth - linear_depth) / linear_depth * FFX_DISOCCLUSION_DEPTH_WEIGHT);
}

struct FfxSurface {
    float3 normal;
    float roughness;
    float depth;
};

FfxSurface ffxSurface(float4 texel) {
    FfxSurface surface;
    surface.normal = unpackDirection(packSnormPair(texel.rg));
    surface.roughness = texel.b;
    surface.depth = max(texel.a, 1e-3);
    return surface;
}

struct ReprojectPush {
    FrameConstants frame;
    uint radiance_texture;
    uint surface_texture;
    uint surface_history_texture;
    uint motion_texture;
    uint history_texture;
    uint samples_history_texture;
    uint reach_texture;
};

[[vk::push_constant]] ReprojectPush reproject_push;

float3 radianceHistory(FrameConstants frame, float2 uv) {
    return sampleTextureLod(reproject_push.history_texture, frame.sampler_linear_clamp, uv, 0.0).rgb;
}

FfxSurface surfaceHistory(FrameConstants frame, float2 uv) {
    return ffxSurface(sampleTextureLod(reproject_push.surface_history_texture, frame.sampler_linear_clamp, uv, 0.0));
}

float2 hitReprojection(FrameConstants frame, float2 uv, float surface_depth, float ray_length) {
    float3 through = worldPositionFromDepth(uv, 0.5, frame.inv_view_proj);
    float3 eye = eyePoint(frame, through);
    float3 seeming = eye + normalize(through - eye) * (surface_depth + ray_length);
    float4 clip = mul(frame.prev_view_proj_unjittered, float4(seeming, 1.0));
    return clip.xy / clip.w * 0.5 + 0.5;
}

void localNeighborhood(int2 pixel, int2 last_pixel, out float3 mean, out float3 variance) {
    mean = float3(0.0);
    variance = float3(0.0);
    float accumulated_weight = 0.0;
    for (int j = -FFX_LOCAL_NEIGHBORHOOD_RADIUS; j <= FFX_LOCAL_NEIGHBORHOOD_RADIUS; ++j) {
        for (int i = -FFX_LOCAL_NEIGHBORHOOD_RADIUS; i <= FFX_LOCAL_NEIGHBORHOOD_RADIUS; ++i) {
            float3 radiance = fetchTexel(reproject_push.radiance_texture, clamp(pixel + int2(i, j), int2(0), last_pixel)).rgb;
            float weight = ffxLocalKernelWeight(float(i)) * ffxLocalKernelWeight(float(j));
            accumulated_weight += weight;
            mean += radiance * weight;
            variance += radiance * radiance * weight;
        }
    }
    mean /= accumulated_weight;
    variance = abs(variance / accumulated_weight - mean * mean);
}

void pickReprojection(FrameConstants frame, float2 in_uv, int2 pixel, int2 last_pixel, FfxSurface surface, float ray_length, out float disocclusion_factor, out float2 reprojection_uv, out float3 reprojection) {
    float3 local_mean;
    float3 local_variance;
    localNeighborhood(pixel, last_pixel, local_mean, local_variance);

    float2 motion = fetchTexel(reproject_push.motion_texture, pixel).rg;
    float2 surface_uv = in_uv - motion;
    float2 hit_uv = hitReprojection(frame, in_uv, surface.depth, ray_length);
    FfxSurface surface_before = surfaceHistory(frame, surface_uv);
    FfxSurface hit_before = surfaceHistory(frame, hit_uv);
    float3 surface_history = radianceHistory(frame, surface_uv);
    float3 hit_history = radianceHistory(frame, hit_uv);
    float hit_normal_similarity = dot(hit_before.normal, surface.normal);
    float surface_normal_similarity = dot(surface_before.normal, surface.normal);

    float3 history_normal;
    float history_depth;
    reprojection_uv = surface_uv;
    reprojection = float3(0.0);
    if (hit_normal_similarity > FFX_REPROJECTION_NORMAL_SIMILARITY_THRESHOLD &&
        hit_normal_similarity + 1.0e-3 > surface_normal_similarity &&
        abs(hit_before.roughness - surface.roughness) < abs(surface_before.roughness - surface.roughness) + 1.0e-3)
    {
        history_normal = hit_before.normal;
        history_depth = hit_before.depth;
        reprojection_uv = hit_uv;
        reprojection = hit_history;
    } else {
        float3 unlike = surface_history - local_mean;
        if (dot(unlike, unlike) >= FFX_REPROJECT_SURFACE_DISCARD_VARIANCE_WEIGHT * length(local_variance)) {
            disocclusion_factor = 0.0;
            return;
        }
        history_normal = surface_before.normal;
        history_depth = surface_before.depth;
        reprojection = surface_history;
    }
    disocclusion_factor = ffxDisocclusionFactor(surface.normal, history_normal, surface.depth, history_depth);
    if (disocclusion_factor > FFX_DISOCCLUSION_THRESHOLD) return;

    float2 texel = frame.inv_resolution;
    float2 closest_uv = reprojection_uv;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 uv = closest_uv + float2(x, y) * texel;
            FfxSurface before = surfaceHistory(frame, uv);
            float weight = ffxDisocclusionFactor(surface.normal, before.normal, surface.depth, before.depth);
            if (weight > disocclusion_factor) {
                disocclusion_factor = weight;
                reprojection_uv = uv;
            }
        }
    }
    reprojection = radianceHistory(frame, reprojection_uv);
    if (disocclusion_factor >= FFX_DISOCCLUSION_THRESHOLD) return;

    float2 place = frame.resolution * reprojection_uv - 0.5;
    float2 f = frac(place);
    int2 corner = int2(floor(place));
    float4 w = float4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
    float3 blended = float3(0.0);
    float3 blended_normal = float3(0.0);
    float blended_depth = 0.0;
    float weight_sum = 0.0;
    for (int index = 0; index < 4; index++) {
        int2 tap = clamp(corner + int2(index & 1, index >> 1), int2(0), last_pixel);
        FfxSurface before = ffxSurface(fetchTexel(reproject_push.surface_history_texture, tap));
        float kept = ffxDisocclusionFactor(surface.normal, before.normal, surface.depth, before.depth) > FFX_DISOCCLUSION_THRESHOLD / 2.0 ? w[index] : 0.0;
        blended += fetchTexel(reproject_push.history_texture, tap).rgb * kept;
        blended_normal += before.normal * kept;
        blended_depth += before.depth * kept;
        weight_sum += kept;
    }
    weight_sum = max(weight_sum, 1.0e-3);
    reprojection = blended / weight_sum;
    disocclusion_factor = ffxDisocclusionFactor(surface.normal, blended_normal / weight_sum, surface.depth, blended_depth / weight_sum);
    if (disocclusion_factor < FFX_DISOCCLUSION_THRESHOLD) disocclusion_factor = 0.0;
}

struct Output {
    float4 reprojected : SV_Target0;
    float samples : SV_Target1;
};

[shader("fragment")]
Output reprojectMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) {
    FrameConstants frame = reproject_push.frame;
    int2 pixel = int2(fragment.xy);
    int2 last_pixel = int2(frame.resolution) - 1;
    FfxSurface surface = ffxSurface(fetchTexel(reproject_push.surface_texture, pixel));
    float4 radiance = float4(fetchTexel(reproject_push.radiance_texture, pixel).rgb, fetchTexel(reproject_push.reach_texture, pixel).a);
    Output result;
    result.reprojected = float4(0.0);
    result.samples = 0.0;
    if (!ffxIsGlossy(surface.roughness)) return result;

    float disocclusion_factor;
    float2 reprojection_uv;
    float3 reprojection;
    pickReprojection(frame, in_uv, pixel, last_pixel, surface, radiance.a, disocclusion_factor, reprojection_uv, reprojection);
    result.reprojected = float4(0.0, 0.0, 0.0, 1.0);
    result.samples = 1.0;
    if (any(reprojection_uv <= 0.0) || any(reprojection_uv >= 1.0)) return result;
    if (disocclusion_factor < FFX_DISOCCLUSION_THRESHOLD) return result;
    if (any(isnan(reprojection)) || any(isinf(reprojection))) return result;

    float previous_variance = sampleTextureLod(reproject_push.history_texture, frame.sampler_linear_clamp, reprojection_uv, 0.0).a;
    float samples = sampleTextureLod(reproject_push.samples_history_texture, frame.sampler_linear_clamp, reprojection_uv, 0.0).r * disocclusion_factor;
    float most = max(8.0, FFX_MAX_SAMPLES * ffxSamplesForRoughness(surface.roughness));
    samples = min(most, samples + 1.0);
    float new_variance = ffxTemporalVariance(radiance.rgb, reprojection);
    result.reprojected = float4(reprojection, lerp(new_variance, previous_variance, 1.0 / samples));
    result.samples = samples;
    return result;
}

struct PrefilterPush {
    FrameConstants frame;
    uint radiance_texture;
    uint reprojected_texture;
    uint surface_texture;
    uint average_texture;
};

[[vk::push_constant]] PrefilterPush prefilter_push;

float radianceWeight(float3 center_radiance, float3 neighbor_radiance, float variance) {
    return max(exp(-(FFX_RADIANCE_WEIGHT_BIAS + variance * FFX_RADIANCE_WEIGHT_VARIANCE_K) * length(center_radiance - neighbor_radiance)), 1.0e-2);
}

static const int2 offsets[15] = {
    int2(0, 1), int2(-2, 1), int2(2, -3), int2(-3, 0), int2(1, 2), int2(-1, -2), int2(3, 0), int2(-3, 3),
    int2(0, -3), int2(-1, -1), int2(2, 1), int2(-2, -2), int2(1, 0), int2(0, 2), int2(3, -1) };

[shader("fragment")]
float4 prefilterMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = prefilter_push.frame;
    int2 pixel = int2(fragment.xy);
    int2 last_pixel = int2(frame.resolution) - 1;
    FfxSurface center = ffxSurface(fetchTexel(prefilter_push.surface_texture, pixel));
    float3 center_radiance = fetchTexel(prefilter_push.radiance_texture, pixel).rgb;
    float center_variance = fetchTexel(prefilter_push.reprojected_texture, pixel).a;
    if (!(center_variance > 0.0) || !ffxIsGlossy(center.roughness)) return float4(center_radiance, center_variance);

    float3 average = sampleTextureLod(prefilter_push.average_texture, frame.sampler_linear_clamp, in_uv, 0.0).rgb;
    float accumulated_weight = radianceWeight(average, center_radiance, center_variance);
    float3 accumulated_radiance = center_radiance * accumulated_weight;
    float accumulated_variance = center_variance * accumulated_weight * accumulated_weight;
    float variance_weight = max(FFX_PREFILTER_VARIANCE_BIAS, 1.0 - exp(-(center_variance * FFX_PREFILTER_VARIANCE_WEIGHT)));
    for (int index = 0; index < 15; index++) {
        int2 tap = clamp(pixel + offsets[index], int2(0), last_pixel);
        FfxSurface neighbor = ffxSurface(fetchTexel(prefilter_push.surface_texture, tap));
        if (!ffxIsGlossy(neighbor.roughness)) continue;
        float3 neighbor_radiance = fetchTexel(prefilter_push.radiance_texture, tap).rgb;
        float neighbor_variance = fetchTexel(prefilter_push.reprojected_texture, tap).a;
        float weight = pow(max(dot(center.normal, neighbor.normal), 0.0), FFX_PREFILTER_NORMAL_SIGMA);
        weight *= exp(-abs(center.depth - neighbor.depth) * center.depth * FFX_PREFILTER_DEPTH_SIGMA);
        weight *= radianceWeight(average, neighbor_radiance, center_variance);
        weight *= variance_weight;
        accumulated_weight += weight;
        accumulated_radiance += weight * neighbor_radiance;
        accumulated_variance += weight * weight * neighbor_variance;
    }
    return float4(accumulated_radiance / accumulated_weight, accumulated_variance / (accumulated_weight * accumulated_weight));
}

struct ResolvePush {
    FrameConstants frame;
    uint prefiltered_texture;
    uint reprojected_texture;
    uint samples_texture;
    uint surface_texture;
    uint average_texture;
    float history_clip_weight;
};

[[vk::push_constant]] ResolvePush resolve_push;

[shader("fragment")]
float4 resolveMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = resolve_push.frame;
    int2 pixel = int2(fragment.xy);
    int2 last_pixel = int2(frame.resolution) - 1;
    float4 prefiltered = fetchTexel(resolve_push.prefiltered_texture, pixel);
    float3 new_signal = prefiltered.rgb;
    float new_variance = prefiltered.a;
    float roughness = ffxSurface(fetchTexel(resolve_push.surface_texture, pixel)).roughness;
    if (!ffxIsGlossy(roughness)) return float4(new_signal, new_variance);

    float samples = fetchTexel(resolve_push.samples_texture, pixel).r;
    float3 average = sampleTextureLod(resolve_push.average_texture, frame.sampler_linear_clamp, in_uv, 0.0).rgb;
    float3 old_signal = fetchTexel(resolve_push.reprojected_texture, pixel).rgb;

    float3 mean = float3(0.0);
    float3 variance = float3(0.0);
    float accumulated_weight = 0.0;
    for (int j = -FFX_LOCAL_NEIGHBORHOOD_RADIUS; j <= FFX_LOCAL_NEIGHBORHOOD_RADIUS; ++j) {
        for (int i = -FFX_LOCAL_NEIGHBORHOOD_RADIUS; i <= FFX_LOCAL_NEIGHBORHOOD_RADIUS; ++i) {
            float3 radiance = fetchTexel(resolve_push.prefiltered_texture, clamp(pixel + int2(i, j), int2(0), last_pixel)).rgb;
            float weight = ffxLocalKernelWeight(float(i)) * ffxLocalKernelWeight(float(j));
            accumulated_weight += weight;
            mean += radiance * weight;
            variance += radiance * radiance * weight;
        }
    }
    mean /= accumulated_weight;
    variance = abs(variance / accumulated_weight - mean * mean);

    float3 spread = (sqrt(variance) + length(mean - average)) * resolve_push.history_clip_weight * 1.4;
    mean = lerp(mean, average, 0.2);
    float3 clipped_old_signal = ffxClipAabb(mean - spread, mean + spread, old_signal);
    float weight = 1.0 - 1.0 / max(samples, 1.0);
    new_signal = lerp(new_signal, average, 1.0 / max(samples + 1.0, 1.0));
    new_signal = ffxClipAabb(average - spread, average + spread, new_signal);
    new_signal = lerp(new_signal, clipped_old_signal, weight);
    new_variance = lerp(ffxTemporalVariance(new_signal, clipped_old_signal), new_variance, weight);
    if (any(isinf(new_signal)) || any(isnan(new_signal)) || isinf(new_variance) || isnan(new_variance)) {
        new_signal = float3(0.0);
        new_variance = 0.0;
    }
    return float4(new_signal, new_variance);
}

struct AveragePush {
    FrameConstants frame;
    uint radiance_texture;
    uint reprojected_texture;
    uint samples_texture;
};

[[vk::push_constant]] AveragePush average_push;

[shader("fragment")]
float4 averageMain(float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = average_push.frame;
    int2 corner = int2(fragment.xy) * 8;
    int2 size = int2(frame.resolution);
    float4 sum = float4(0.0);
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            int2 tap = corner + int2(x, y);
            if (any(tap >= size)) continue;
            float3 radiance = fetchTexel(average_push.radiance_texture, tap).rgb;
            if (fetchTexel(average_push.samples_texture, tap).r > 1.0)
                radiance = lerp(radiance, fetchTexel(average_push.reprojected_texture, tap).rgb, 0.3);
            float weight = max(exp(-ffxLuminance(radiance) * FFX_AVG_RADIANCE_LUMINANCE_WEIGHT), 1.0e-2);
            if (any(isinf(radiance)) || any(isnan(radiance))) continue;
            sum += float4(radiance * weight, weight);
        }
    }
    return float4(sum.rgb / max(sum.w, 1.0e-3), 1.0);
}
