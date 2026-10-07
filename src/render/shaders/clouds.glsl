// Cloud layer: a slab between two altitudes on a curved planet, with density
// from the noise volume made by cloud_noise.frag.
#ifndef CLOUDS_GLSL
#define CLOUDS_GLSL
#include "volume.glsl"

const ivec3 CLOUD_NOISE_SIZE = ivec3(128, 128, 64);
const int CLOUD_NOISE_TILES = 8;

float cloudRemap(float value, float low, float high) {
    return clamp((value - low) / max(high - low, 1e-5), 0.0, 1.0);
}

// Height above the curved ground, relative to the camera to keep float
// precision.
float cloudAltitude(CloudData clouds, vec3 position, vec3 camera) {
    vec2 across = position.xz - camera.xz;
    return position.y + dot(across, across) / (2.0 * clouds.planet_radius);
}

// Extinction per meter. `detailed` adds small-scale erosion.
float cloudDensity(CloudData clouds, uint s, vec3 position, float altitude, bool detailed) {
    float height = (altitude - clouds.bottom) / (clouds.top - clouds.bottom);
    if (height <= 0.0 || height >= 1.0) return 0.0;
    vec3 p = (position + clouds.offset) / clouds.period;
    // Volume slices run along world Y.
    vec3 uvw = vec3(p.x, p.z, p.y);
    vec4 noise = sampleVolumeRepeat(clouds.noise_texture, s, uvw, CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES);
    float billows = noise.g * 0.625 + noise.b * 0.25 + noise.a * 0.125;
    float shape = noise.r;
    float profile = smoothstep(0.0, 0.12, height) * smoothstep(1.0, 0.35, height);
    float weather = sampleVolumeRepeat(clouds.noise_texture, s, vec3(uvw.xy * 0.17 + 0.31, 0.37), CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES).r;
    float coverage = clamp(clouds.coverage + (weather - 0.55) * clouds.variation, 0.0, 1.0);
    // Noise is roughly 0.3..1; coverage lowers the cloud threshold.
    float threshold = 1.0 - coverage * 0.5;
    if (clouds.anvil > 0.0) {
        float storm = clouds.anvil * smoothstep(0.6, 0.85, weather);
        profile = mix(profile, smoothstep(0.0, 0.08, height) * (1.0 - smoothstep(0.93, 1.0, height)), storm);
        threshold -= storm * 0.3 * smoothstep(0.65, 0.95, height);
    }
    float density = cloudRemap(shape * profile, threshold, threshold + 0.22);
    density = cloudRemap(density, (1.0 - billows) * 0.35, 1.0);
    if (density <= 0.0) return 0.0;
    if (detailed && clouds.detail > 0.0) {
        vec4 fine = sampleVolumeRepeat(clouds.noise_texture, s, uvw * 6.0 + 0.5, CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES);
        float wisps = fine.g * 0.625 + fine.b * 0.25 + fine.a * 0.125;
        float erosion = mix(wisps, 1.0 - wisps, clamp(height * 4.0, 0.0, 1.0));
        density = cloudRemap(density, erosion * clouds.detail, 1.0);
    }
    return density * clouds.density;
}

// Nearest and farthest positive ray distances at `altitude`; negative when
// none. `height` = start altitude, `rise` = direction.y, `bend` = (1 - rise^2)
// / (2 * planet radius).
vec2 cloudCrossings(float height, float rise, float bend, float altitude) {
    float c = height - altitude;
    if (bend < 1e-12) {
        float t = abs(rise) > 1e-6 ? -c / rise : -1.0;
        return vec2(t, t);
    }
    float discriminant = rise * rise - 4.0 * bend * c;
    if (discriminant < 0.0) return vec2(-1.0);
    float q = -0.5 * (rise + (rise >= 0.0 ? 1.0 : -1.0) * sqrt(discriminant));
    float a = q / bend;
    float b = abs(q) > 1e-20 ? c / q : a;
    float low = min(a, b);
    float high = max(a, b);
    if (high < 0.0) return vec2(-1.0);
    return vec2(low >= 0.0 ? low : high, high);
}

// Ray span inside the layer in front of the camera: (start, end); end < start
// when empty.
vec2 cloudSegment(CloudData clouds, float height, float rise) {
    float bend = (1.0 - rise * rise) / (2.0 * clouds.planet_radius);
    vec2 bottom = cloudCrossings(height, rise, bend, clouds.bottom);
    vec2 top = cloudCrossings(height, rise, bend, clouds.top);
    if (height < clouds.bottom) return vec2(bottom.x, top.x);
    if (height > clouds.top) {
        if (top.x < 0.0) return vec2(0.0, -1.0);
        return vec2(top.x, bottom.x >= 0.0 ? bottom.x : top.y);
    }
    float end = top.x >= 0.0 ? top.x : 1e30;
    if (bottom.x >= 0.0) end = min(end, bottom.x);
    return vec2(0.0, end);
}

// Sun visibility under the layer, from one density sample.
float cloudShadow(FrameConstants frame, vec3 position) {
    if ((SHADE_FEATURES & FEATURE_CLOUD_SHADOWS) == 0u || (frame.flags & FRAME_CLOUD_SHADOWS) == 0u) return 1.0;
    CloudData clouds = frame.clouds.data;
    vec3 to_sun = frame.sun_direction;
    float altitude = mix(clouds.bottom, clouds.top, 0.3);
    if (to_sun.y < 0.03 || position.y >= altitude) return 1.0;
    vec3 crossing = position + to_sun * ((altitude - position.y) / to_sun.y);
    float sigma = cloudDensity(clouds, frame.sampler_linear_clamp, crossing, altitude, false);
    float optical_depth = sigma * (clouds.top - clouds.bottom) * 0.6 / to_sun.y;
    return mix(1.0, exp(-optical_depth), clouds.shadow_strength);
}

// Composites a coarse cloud layer over sky `color` seen along `direction`.
// `sun` points at the sun, `sunlight` is its radiance at the ground.
// `clouds.depth_texture` holds a linear sampler here.
vec3 cloudsOverSky(CloudData clouds, vec3 direction, vec3 sun, vec3 sunlight, vec3 color) {
    vec2 segment = cloudSegment(clouds, 2.0, direction.y);
    segment.y = min(segment.y, clouds.max_distance);
    if (segment.y <= segment.x) return color;
    const int cloud_steps = 20;
    float cloud_step = (segment.y - segment.x) / float(cloud_steps);
    float thickness = clouds.top - clouds.bottom;
    vec3 scattered = vec3(0.0);
    float through = 1.0;
    for (int i = 0; i < cloud_steps; i++) {
        vec3 point = direction * (segment.x + (float(i) + 0.5) * cloud_step);
        float altitude = cloudAltitude(clouds, point, vec3(0.0));
        float sigma = cloudDensity(clouds, clouds.depth_texture, point, altitude, false);
        if (sigma <= 0.0) continue;
        float above = sigma * (clouds.top - altitude) * 0.5 / max(sun.y, 0.15);
        vec3 light = sunlight * (0.8 / PI) / (1.0 + 0.13 * above) + color * clouds.ambient * (0.3 + 0.7 * (altitude - clouds.bottom) / thickness);
        float step_through = exp(-sigma * cloud_step);
        scattered += through * (1.0 - step_through) * light * clouds.albedo;
        through *= step_through;
    }
    float visible = 1.0 - smoothstep(0.6, 1.0, segment.x / clouds.max_distance);
    return mix(color, color * through + scattered, visible);
}

#endif
