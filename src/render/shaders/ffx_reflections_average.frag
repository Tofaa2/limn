#version 460
#include "common.glsl"
#include "ffx_reflections.glsl"

// 8x8 luminance-weighted average of the reflections, at 1/8 resolution (end of
// ffx_denoiser_reflections_reproject.h).
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint radiance_texture;
    uint reprojected_texture;
    uint samples_texture;
} push;

layout(location = 0) out vec4 out_average;

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 corner = ivec2(gl_FragCoord.xy) * 8;
    ivec2 size = ivec2(frame.resolution);
    vec4 sum = vec4(0.0);
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            ivec2 tap = corner + ivec2(x, y);
            if (any(greaterThanEqual(tap, size))) continue;
            vec3 radiance = texelFetch(TEX(push.radiance_texture, nearest), tap, 0).rgb;
            if (texelFetch(TEX(push.samples_texture, nearest), tap, 0).r > 1.0)
                radiance = mix(radiance, texelFetch(TEX(push.reprojected_texture, nearest), tap, 0).rgb, 0.3);
            float weight = max(exp(-ffxLuminance(radiance) * FFX_AVG_RADIANCE_LUMINANCE_WEIGHT), 1.0e-2);
            if (any(isinf(radiance)) || any(isnan(radiance))) continue;
            sum += vec4(radiance * weight, weight);
        }
    }
    out_average = vec4(sum.rgb / max(sum.w, 1.0e-3), 1.0);
}
