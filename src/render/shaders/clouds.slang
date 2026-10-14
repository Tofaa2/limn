#ifndef CLOUDS_SLANG
#define CLOUDS_SLANG
#include "fluid.slang"

static const int3 CLOUD_NOISE_SIZE = int3(128, 128, 64);
static const int CLOUD_NOISE_TILES = 8;

float cloudRemap(float value, float low, float high) {
    return clamp((value - low) / max(high - low, 1e-5), 0.0, 1.0);
}

float cloudDensity(CloudData clouds, uint s, float3 position, float altitude, bool detailed) {
    float height = (altitude - clouds.bottom) / (clouds.top - clouds.bottom);
    if (height <= 0.0 || height >= 1.0) return 0.0;
    float3 p = (position + clouds.offset) / clouds.period;
    float3 uvw = float3(p.x, p.z, p.y);
    float4 noise = sampleVolumeRepeat(clouds.noise_texture, s, uvw, CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES);
    float billows = noise.g * 0.625 + noise.b * 0.25 + noise.a * 0.125;
    float shape = noise.r;
    float profile = smoothstep(0.0, 0.12, height) * smoothstep(1.0, 0.35, height);
    float weather = sampleVolumeRepeat(clouds.noise_texture, s, float3(uvw.xy * 0.17 + 0.31, 0.37), CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES).r;
    float coverage = clamp(clouds.coverage + (weather - 0.55) * clouds.variation, 0.0, 1.0);
    float threshold = 1.0 - coverage * 0.5;
    if (clouds.anvil > 0.0) {
        float storm = clouds.anvil * smoothstep(0.6, 0.85, weather);
        profile = lerp(profile, smoothstep(0.0, 0.08, height) * (1.0 - smoothstep(0.93, 1.0, height)), storm);
        threshold -= storm * 0.3 * smoothstep(0.65, 0.95, height);
    }
    float density = cloudRemap(shape * profile, threshold, threshold + 0.22);
    density = cloudRemap(density, (1.0 - billows) * 0.35, 1.0);
    if (density <= 0.0) return 0.0;
    if (detailed && clouds.detail > 0.0) {
        float4 fine = sampleVolumeRepeat(clouds.noise_texture, s, uvw * 6.0 + 0.5, CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES);
        float wisps = fine.g * 0.625 + fine.b * 0.25 + fine.a * 0.125;
        float erosion = lerp(wisps, 1.0 - wisps, clamp(height * 4.0, 0.0, 1.0));
        density = cloudRemap(density, erosion * clouds.detail, 1.0);
    }
    return density * clouds.density;
}

float cloudShadow(FrameConstants frame, float3 position) {
    if ((SHADE_FEATURES & FEATURE_CLOUD_SHADOWS) == 0u || (frame.flags & FRAME_CLOUD_SHADOWS) == 0u) return 1.0;
    CloudData clouds = *frame.clouds.data;
    float3 to_sun = frame.sun_direction;
    float altitude = lerp(clouds.bottom, clouds.top, 0.3);
    if (to_sun.y < 0.03 || position.y >= altitude) return 1.0;
    float3 crossing = position + to_sun * ((altitude - position.y) / to_sun.y);
    float sigma = cloudDensity(clouds, frame.sampler_linear_clamp, crossing, altitude, false);
    float optical_depth = sigma * (clouds.top - clouds.bottom) * 0.6 / to_sun.y;
    return lerp(1.0, exp(-optical_depth), clouds.shadow_strength);
}

float cloudAltitude(CloudData clouds, float3 position, float3 camera) {
    float2 across = position.xz - camera.xz;
    return position.y + dot(across, across) / (2.0 * clouds.planet_radius);
}

float2 cloudCrossings(float height, float rise, float bend, float altitude) {
    float c = height - altitude;
    if (bend < 1e-12) {
        float t = abs(rise) > 1e-6 ? -c / rise : -1.0;
        return float2(t, t);
    }
    float discriminant = rise * rise - 4.0 * bend * c;
    if (discriminant < 0.0) return float2(-1.0);
    float q = -0.5 * (rise + (rise >= 0.0 ? 1.0 : -1.0) * sqrt(discriminant));
    float a = q / bend;
    float b = abs(q) > 1e-20 ? c / q : a;
    float low = min(a, b);
    float high = max(a, b);
    if (high < 0.0) return float2(-1.0);
    return float2(low >= 0.0 ? low : high, high);
}

float2 cloudSegment(CloudData clouds, float height, float rise) {
    float bend = (1.0 - rise * rise) / (2.0 * clouds.planet_radius);
    float2 bottom = cloudCrossings(height, rise, bend, clouds.bottom);
    float2 top = cloudCrossings(height, rise, bend, clouds.top);
    if (height < clouds.bottom) return float2(bottom.x, top.x);
    if (height > clouds.top) {
        if (top.x < 0.0) return float2(0.0, -1.0);
        return float2(top.x, bottom.x >= 0.0 ? bottom.x : top.y);
    }
    float end = top.x >= 0.0 ? top.x : 1e30;
    if (bottom.x >= 0.0) end = min(end, bottom.x);
    return float2(0.0, end);
}

float3 cloudsOverSky(CloudData clouds, float3 direction, float3 sun, float3 sunlight, float3 color) {
    float2 segment = cloudSegment(clouds, 2.0, direction.y);
    segment.y = min(segment.y, clouds.max_distance);
    if (segment.y <= segment.x) return color;
    const int cloud_steps = 20;
    float cloud_step = (segment.y - segment.x) / float(cloud_steps);
    float thickness = clouds.top - clouds.bottom;
    float3 scattered = float3(0.0);
    float through = 1.0;
    for (int i = 0; i < cloud_steps; i++) {
        float3 point = direction * (segment.x + (float(i) + 0.5) * cloud_step);
        float altitude = cloudAltitude(clouds, point, float3(0.0));
        float sigma = cloudDensity(clouds, clouds.depth_texture, point, altitude, false);
        if (sigma <= 0.0) continue;
        float above = sigma * (clouds.top - altitude) * 0.5 / max(sun.y, 0.15);
        float3 light = sunlight * (0.8 / PI) / (1.0 + 0.13 * above) + color * clouds.ambient * (0.3 + 0.7 * (altitude - clouds.bottom) / thickness);
        float step_through = exp(-sigma * cloud_step);
        scattered += through * (1.0 - step_through) * light * clouds.albedo;
        through *= step_through;
    }
    float visible = 1.0 - smoothstep(0.6, 1.0, segment.x / clouds.max_distance);
    return lerp(color, color * through + scattered, visible);
}

#endif
