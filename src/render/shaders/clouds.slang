#ifndef CLOUDS_SLANG
#define CLOUDS_SLANG
#include "fluid.slang"

static const int3 CLOUD_NOISE_SIZE = int3(128, 128, 64);
static const int CLOUD_NOISE_TILES = 8;

float cloudRemap(float value, float low, float high) {
    return clamp((value - low) / max(high - low, 1e-5), 0.0, 1.0);
}

/// Share of the layer's height a cloud fills at `height`: flat sheets at
/// kind 0, heaped cumulus at 0.5, towers through the whole layer at 1.
float cloudProfile(float height, float kind) {
    float sheet = smoothstep(0.0, 0.05, height) * smoothstep(0.3, 0.1, height);
    float heap = smoothstep(0.0, 0.12, height) * smoothstep(1.0, 0.35, height);
    float tower = smoothstep(0.0, 0.08, height) * (1.0 - smoothstep(0.93, 1.0, height));
    return kind < 0.5 ? lerp(sheet, heap, kind * 2.0) : lerp(heap, tower, kind * 2.0 - 1.0);
}

float cloudDensity(CloudData clouds, uint s, float3 position, float altitude, bool detailed) {
    float height = (altitude - clouds.bottom) / (clouds.top - clouds.bottom);
    if (height <= 0.0 || height >= 1.0) return 0.0;
    float3 moved = position + clouds.offset;
    float4 weather = sampleTextureLod(clouds.weather_texture, clouds.repeat_sampler, moved.xz / clouds.weather_size, 0.0);
    float coverage = clamp(clouds.coverage + (weather.r - 0.5) * clouds.variation, 0.0, 1.0);
    float storm = clouds.anvil * smoothstep(0.6, 0.85, weather.r);
    float kind = max(clamp(clouds.kind + weather.g - 0.5, 0.0, 1.0), storm);
    float profile = cloudProfile(height, kind);
    if (profile <= 0.0) return 0.0;
    float2 swirl = (sampleTextureLod(clouds.pattern_texture, clouds.repeat_sampler, moved.xz / (clouds.period * 1.7) + float2(height * 0.23, height * 0.11), 0.0).ba * 2.0 - 1.0) * clouds.curl;
    float3 p = moved / clouds.period;
    float3 uvw = float3(p.x + swirl.x * 0.05, p.z + swirl.y * 0.05, p.y);
    float4 noise = sampleVolumeRepeat(clouds.noise_texture, s, uvw, CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES);
    float billows = noise.g * 0.625 + noise.b * 0.25 + noise.a * 0.125;
    float threshold = 1.0 - coverage * 0.5 - storm * 0.3 * smoothstep(0.65, 0.95, height);
    float density = cloudRemap(noise.r * profile, threshold, threshold + 0.22);
    density = cloudRemap(density, (1.0 - billows) * 0.35, 1.0);
    if (density <= 0.0) return 0.0;
    if (detailed && clouds.detail > 0.0) {
        float3 fine_uvw = uvw * 6.0 + 0.5 + float3(swirl, 0.0) * lerp(0.12, 0.03, height);
        float4 fine = sampleVolumeRepeat(clouds.noise_texture, s, fine_uvw, CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES);
        float wisps = fine.g * 0.625 + fine.b * 0.25 + fine.a * 0.125;
        float erosion = lerp(wisps, 1.0 - wisps, clamp(height * 4.0, 0.0, 1.0));
        density = cloudRemap(density, erosion * clouds.detail, 1.0);
    }
    return density * clouds.density;
}

/// The air between the eye and a point `distance` away along `direction`:
/// the light it scatters toward the eye, and how much of the point shows
/// through. It is the air of the sky behind, thinning with height, with the
/// haze of a sky of the default turbidity.
void cloudAir(FrameConstants frame, float3 sky, float3 camera, float3 direction, float distance, float planet_radius, out float3 through, out float3 air) {
    const float3 rayleigh = float3(5.8e-6, 13.5e-6, 33.1e-6);
    const float mie = 1e-5;
    float mu = dot(direction, frame.sun_direction);
    float phase_rayleigh = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    const float g = 0.76;
    float phase_mie = 3.0 / (8.0 * PI) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    const int steps = 6;
    float step_length = distance / float(steps);
    float level = 1.0 - direction.y * direction.y;
    float3 optical = float3(0.0);
    air = float3(0.0);
    for (int i = 0; i < steps; i++) {
        float s = (float(i) + 0.5) * step_length;
        float altitude = max(camera.y + direction.y * s + s * s * level / (2.0 * planet_radius), 0.0);
        float3 by_air = rayleigh * exp(-altitude / 8000.0);
        float by_haze = mie * exp(-altitude / 1200.0);
        float3 extinction = by_air + 1.1 * by_haze;
        float3 scattered = frame.sun_radiance * (by_air * phase_rayleigh + by_haze * phase_mie) + sky * (by_air + by_haze);
        air += exp(-optical) * scattered * (1.0 - exp(-extinction * step_length)) / max(extinction, float3(1e-12));
        optical += extinction * step_length;
    }
    through = exp(-optical);
}

float cloudShadow(FrameConstants frame, float3 position) {
    if ((SHADE_FEATURES & FEATURE_CLOUD_SHADOWS) == 0u || frame.clouds.shadows == 0u) return 1.0;
    CloudData clouds = *frame.clouds.layer.data;
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
