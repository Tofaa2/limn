#version 460
#include "common.glsl"
#include "ffx_reflections.glsl"

// Temporal resolve: blends the prefiltered reflection with history clipped to
// the local neighbourhood (ffx_denoiser_reflections_resolve_temporal.h).
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    // Prefiltered reflections (rgb) and variance (a).
    uint prefiltered_texture;
    uint reprojected_texture;
    uint samples_texture;
    uint surface_texture;
    uint average_texture;
    // Scale of the history clip box.
    float history_clip_weight;
} push;

layout(location = 0) in vec2 in_uv;
// Denoised reflection (rgb) and variance (a); also next frame's history.
layout(location = 0) out vec4 out_resolved;

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    ivec2 last_pixel = ivec2(frame.resolution) - 1;
    vec4 prefiltered = texelFetch(TEX(push.prefiltered_texture, nearest), pixel, 0);
    vec3 new_signal = prefiltered.rgb;
    float new_variance = prefiltered.a;
    float roughness = ffxSurface(texelFetch(TEX(push.surface_texture, nearest), pixel, 0)).roughness;
    out_resolved = vec4(new_signal, new_variance);
    if (!ffxIsGlossy(roughness)) return;

    float samples = texelFetch(TEX(push.samples_texture, nearest), pixel, 0).r;
    vec3 average = textureLod(TEX(push.average_texture, frame.sampler_linear_clamp), in_uv, 0.0).rgb;
    vec3 old_signal = texelFetch(TEX(push.reprojected_texture, nearest), pixel, 0).rgb;

    vec3 mean = vec3(0.0);
    vec3 variance = vec3(0.0);
    float accumulated_weight = 0.0;
    for (int j = -FFX_LOCAL_NEIGHBORHOOD_RADIUS; j <= FFX_LOCAL_NEIGHBORHOOD_RADIUS; ++j) {
        for (int i = -FFX_LOCAL_NEIGHBORHOOD_RADIUS; i <= FFX_LOCAL_NEIGHBORHOOD_RADIUS; ++i) {
            vec3 radiance = texelFetch(TEX(push.prefiltered_texture, nearest), clamp(pixel + ivec2(i, j), ivec2(0), last_pixel), 0).rgb;
            float weight = ffxLocalKernelWeight(float(i)) * ffxLocalKernelWeight(float(j));
            accumulated_weight += weight;
            mean += radiance * weight;
            variance += radiance * radiance * weight;
        }
    }
    mean /= accumulated_weight;
    variance = abs(variance / accumulated_weight - mean * mean);

    vec3 spread = (sqrt(variance) + length(mean - average)) * push.history_clip_weight * 1.4;
    mean = mix(mean, average, 0.2);
    vec3 clipped_old_signal = ffxClipAabb(mean - spread, mean + spread, old_signal);
    float weight = 1.0 - 1.0 / max(samples, 1.0);
    // Bias toward the 8x8 average while few samples are accumulated.
    new_signal = mix(new_signal, average, 1.0 / max(samples + 1.0, 1.0));
    new_signal = ffxClipAabb(average - spread, average + spread, new_signal);
    new_signal = mix(new_signal, clipped_old_signal, weight);
    new_variance = mix(ffxTemporalVariance(new_signal, clipped_old_signal), new_variance, weight);
    if (any(isinf(new_signal)) || any(isnan(new_signal)) || isinf(new_variance) || isnan(new_variance)) {
        new_signal = vec3(0.0);
        new_variance = 0.0;
    }
    out_resolved = vec4(new_signal, new_variance);
}
