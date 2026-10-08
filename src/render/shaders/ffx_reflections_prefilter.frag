#version 460
#include "common.glsl"
#include "ffx_reflections.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint radiance_texture;
    uint reprojected_texture;
    uint surface_texture;
    uint average_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_prefiltered;

float radianceWeight(vec3 center_radiance, vec3 neighbor_radiance, float variance) {
    return max(exp(-(FFX_RADIANCE_WEIGHT_BIAS + variance * FFX_RADIANCE_WEIGHT_VARIANCE_K) * length(center_radiance - neighbor_radiance)), 1.0e-2);
}

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    ivec2 last_pixel = ivec2(frame.resolution) - 1;
    FfxSurface center = ffxSurface(texelFetch(TEX(push.surface_texture, nearest), pixel, 0));
    vec3 center_radiance = texelFetch(TEX(push.radiance_texture, nearest), pixel, 0).rgb;
    float center_variance = texelFetch(TEX(push.reprojected_texture, nearest), pixel, 0).a;
    out_prefiltered = vec4(center_radiance, center_variance);
    if (!(center_variance > 0.0) || !ffxIsGlossy(center.roughness)) return;

    vec3 average = textureLod(TEX(push.average_texture, frame.sampler_linear_clamp), in_uv, 0.0).rgb;
    float accumulated_weight = radianceWeight(average, center_radiance, center_variance);
    vec3 accumulated_radiance = center_radiance * accumulated_weight;
    float accumulated_variance = center_variance * accumulated_weight * accumulated_weight;
    const ivec2 offsets[15] = ivec2[](
        ivec2(0, 1), ivec2(-2, 1), ivec2(2, -3), ivec2(-3, 0), ivec2(1, 2), ivec2(-1, -2), ivec2(3, 0), ivec2(-3, 3),
        ivec2(0, -3), ivec2(-1, -1), ivec2(2, 1), ivec2(-2, -2), ivec2(1, 0), ivec2(0, 2), ivec2(3, -1));
    float variance_weight = max(FFX_PREFILTER_VARIANCE_BIAS, 1.0 - exp(-(center_variance * FFX_PREFILTER_VARIANCE_WEIGHT)));
    for (int index = 0; index < 15; index++) {
        ivec2 tap = clamp(pixel + offsets[index], ivec2(0), last_pixel);
        FfxSurface neighbor = ffxSurface(texelFetch(TEX(push.surface_texture, nearest), tap, 0));
        if (!ffxIsGlossy(neighbor.roughness)) continue;
        vec3 neighbor_radiance = texelFetch(TEX(push.radiance_texture, nearest), tap, 0).rgb;
        float neighbor_variance = texelFetch(TEX(push.reprojected_texture, nearest), tap, 0).a;
        float weight = pow(max(dot(center.normal, neighbor.normal), 0.0), FFX_PREFILTER_NORMAL_SIGMA);
        weight *= exp(-abs(center.depth - neighbor.depth) * center.depth * FFX_PREFILTER_DEPTH_SIGMA);
        weight *= radianceWeight(average, neighbor_radiance, center_variance);
        weight *= variance_weight;
        accumulated_weight += weight;
        accumulated_radiance += weight * neighbor_radiance;
        accumulated_variance += weight * weight * neighbor_variance;
    }
    out_prefiltered = vec4(accumulated_radiance / accumulated_weight, accumulated_variance / (accumulated_weight * accumulated_weight));
}
