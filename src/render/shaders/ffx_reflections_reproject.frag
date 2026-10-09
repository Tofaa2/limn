#version 460
#include "common.glsl"
#include "ffx_reflections.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint radiance_texture;
    uint surface_texture;
    uint surface_history_texture;
    uint motion_texture;
    uint history_texture;
    uint samples_history_texture;
    uint reach_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_reprojected;
layout(location = 1) out float out_samples;

vec3 radianceHistory(FrameConstants frame, vec2 uv) {
    return textureLod(TEX(push.history_texture, frame.sampler_linear_clamp), uv, 0.0).rgb;
}

FfxSurface surfaceHistory(FrameConstants frame, vec2 uv) {
    return ffxSurface(textureLod(TEX(push.surface_history_texture, frame.sampler_linear_clamp), uv, 0.0));
}

vec2 hitReprojection(FrameConstants frame, vec2 uv, float surface_depth, float ray_length) {
    vec3 toward = normalize(worldPositionFromDepth(uv, 0.5, frame.inv_view_proj) - frame.camera_position);
    vec3 seeming = frame.camera_position + toward * (surface_depth + ray_length);
    vec4 clip = frame.prev_view_proj_unjittered * vec4(seeming, 1.0);
    return clip.xy / clip.w * 0.5 + 0.5;
}

void localNeighborhood(FrameConstants frame, ivec2 pixel, ivec2 last_pixel, out vec3 mean, out vec3 variance) {
    mean = vec3(0.0);
    variance = vec3(0.0);
    float accumulated_weight = 0.0;
    for (int j = -FFX_LOCAL_NEIGHBORHOOD_RADIUS; j <= FFX_LOCAL_NEIGHBORHOOD_RADIUS; ++j) {
        for (int i = -FFX_LOCAL_NEIGHBORHOOD_RADIUS; i <= FFX_LOCAL_NEIGHBORHOOD_RADIUS; ++i) {
            vec3 radiance = texelFetch(TEX(push.radiance_texture, frame.sampler_nearest_clamp), clamp(pixel + ivec2(i, j), ivec2(0), last_pixel), 0).rgb;
            float weight = ffxLocalKernelWeight(float(i)) * ffxLocalKernelWeight(float(j));
            accumulated_weight += weight;
            mean += radiance * weight;
            variance += radiance * radiance * weight;
        }
    }
    mean /= accumulated_weight;
    variance = abs(variance / accumulated_weight - mean * mean);
}

void pickReprojection(FrameConstants frame, ivec2 pixel, ivec2 last_pixel, FfxSurface surface, float ray_length, out float disocclusion_factor, out vec2 reprojection_uv, out vec3 reprojection) {
    vec3 local_mean;
    vec3 local_variance;
    localNeighborhood(frame, pixel, last_pixel, local_mean, local_variance);

    vec2 motion = texelFetch(TEX(push.motion_texture, frame.sampler_nearest_clamp), pixel, 0).rg;
    vec2 surface_uv = in_uv - motion;
    vec2 hit_uv = hitReprojection(frame, in_uv, surface.depth, ray_length);
    FfxSurface surface_before = surfaceHistory(frame, surface_uv);
    FfxSurface hit_before = surfaceHistory(frame, hit_uv);
    vec3 surface_history = radianceHistory(frame, surface_uv);
    vec3 hit_history = radianceHistory(frame, hit_uv);
    float hit_normal_similarity = dot(hit_before.normal, surface.normal);
    float surface_normal_similarity = dot(surface_before.normal, surface.normal);

    vec3 history_normal;
    float history_depth;
    reprojection_uv = surface_uv;
    reprojection = vec3(0.0);
    if (hit_normal_similarity > FFX_REPROJECTION_NORMAL_SIMILARITY_THRESHOLD &&
        hit_normal_similarity + 1.0e-3 > surface_normal_similarity &&
        abs(hit_before.roughness - surface.roughness) < abs(surface_before.roughness - surface.roughness) + 1.0e-3)
    {
        history_normal = hit_before.normal;
        history_depth = hit_before.depth;
        reprojection_uv = hit_uv;
        reprojection = hit_history;
    } else {
        vec3 unlike = surface_history - local_mean;
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

    vec2 texel = frame.inv_resolution;
    vec2 closest_uv = reprojection_uv;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 uv = closest_uv + vec2(x, y) * texel;
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

    vec2 place = frame.resolution * reprojection_uv - 0.5;
    vec2 f = fract(place);
    ivec2 corner = ivec2(floor(place));
    vec4 w = vec4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
    vec3 blended = vec3(0.0);
    vec3 blended_normal = vec3(0.0);
    float blended_depth = 0.0;
    float weight_sum = 0.0;
    for (int index = 0; index < 4; index++) {
        ivec2 tap = clamp(corner + ivec2(index & 1, index >> 1), ivec2(0), last_pixel);
        FfxSurface before = ffxSurface(texelFetch(TEX(push.surface_history_texture, frame.sampler_nearest_clamp), tap, 0));
        float kept = ffxDisocclusionFactor(surface.normal, before.normal, surface.depth, before.depth) > FFX_DISOCCLUSION_THRESHOLD / 2.0 ? w[index] : 0.0;
        blended += texelFetch(TEX(push.history_texture, frame.sampler_nearest_clamp), tap, 0).rgb * kept;
        blended_normal += before.normal * kept;
        blended_depth += before.depth * kept;
        weight_sum += kept;
    }
    weight_sum = max(weight_sum, 1.0e-3);
    reprojection = blended / weight_sum;
    disocclusion_factor = ffxDisocclusionFactor(surface.normal, blended_normal / weight_sum, surface.depth, blended_depth / weight_sum);
    if (disocclusion_factor < FFX_DISOCCLUSION_THRESHOLD) disocclusion_factor = 0.0;
}

void main() {
    FrameConstants frame = push.frame;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    ivec2 last_pixel = ivec2(frame.resolution) - 1;
    FfxSurface surface = ffxSurface(texelFetch(TEX(push.surface_texture, frame.sampler_nearest_clamp), pixel, 0));
    vec4 radiance = vec4(texelFetch(TEX(push.radiance_texture, frame.sampler_nearest_clamp), pixel, 0).rgb, texelFetch(TEX(push.reach_texture, frame.sampler_nearest_clamp), pixel, 0).a);
    out_reprojected = vec4(0.0);
    out_samples = 0.0;
    if (!ffxIsGlossy(surface.roughness)) return;

    float disocclusion_factor;
    vec2 reprojection_uv;
    vec3 reprojection;
    pickReprojection(frame, pixel, last_pixel, surface, radiance.a, disocclusion_factor, reprojection_uv, reprojection);
    out_reprojected = vec4(0.0, 0.0, 0.0, 1.0);
    out_samples = 1.0;
    if (any(lessThanEqual(reprojection_uv, vec2(0.0))) || any(greaterThanEqual(reprojection_uv, vec2(1.0)))) return;
    if (disocclusion_factor < FFX_DISOCCLUSION_THRESHOLD) return;
    if (any(isnan(reprojection)) || any(isinf(reprojection))) return;

    float previous_variance = textureLod(TEX(push.history_texture, frame.sampler_linear_clamp), reprojection_uv, 0.0).a;
    float samples = textureLod(TEX(push.samples_history_texture, frame.sampler_linear_clamp), reprojection_uv, 0.0).r * disocclusion_factor;
    float most = max(8.0, FFX_MAX_SAMPLES * ffxSamplesForRoughness(surface.roughness));
    samples = min(most, samples + 1.0);
    float new_variance = ffxTemporalVariance(radiance.rgb, reprojection);
    out_reprojected = vec4(reprojection, mix(new_variance, previous_variance, 1.0 / samples));
    out_samples = samples;
}
