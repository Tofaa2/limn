#include "media.slang"
#include "fluid.slang"
#include "clouds.slang"

struct MarchPush {
    FrameConstants frame;
    CloudRef clouds;
};

[[vk::push_constant]] MarchPush march_push;

[shader("fragment")]
float4 marchMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = march_push.frame;
    CloudData clouds = *march_push.clouds.data;
    uint linear = frame.sampler_linear_clamp;
    uint nearest = frame.sampler_nearest_clamp;
    float3 far_point = worldPositionFromDepth(in_uv, 1e-6, frame.inv_view_proj);
    float3 camera = eyePoint(frame, far_point);
    float3 direction = normalize(far_point - camera);
    float2 segment = cloudSegment(clouds, camera.y, direction.y);
    segment.y = min(segment.y, clouds.max_distance);
    if (segment.y <= segment.x) return float4(0.0, 0.0, 0.0, 1.0);

    float2 reach = abs(float2(ddx(in_uv.x), ddy(in_uv.y)));
    float limit = 0.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float2 uv = in_uv + float2(x, y) * reach;
        float depth = sampleTextureLod(clouds.depth_texture, nearest, uv, 0.0).r;
        float distance_there = depth > 0.0 ? length(worldPositionFromDepth(uv, depth, frame.inv_view_proj) - camera) : 1e30;
        limit = max(limit, distance_there);
    }
    if (limit <= segment.x) return float4(0.0, 0.0, 0.0, 2.0);
    segment.y = min(segment.y, limit);

    float cos_sun = dot(direction, frame.sun_direction);
    float3 sky_up = float3(0.0);
    float3 sky_down = float3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u) {
        sky_up = sampleCubeLod(frame.env_irradiance, linear, float3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity * clouds.ambient;
        sky_down = sampleCubeLod(frame.env_irradiance, linear, float3(0.0, -1.0, 0.0), 0.0).rgb * frame.env_intensity * clouds.ambient;
    }
    float3 to_sun = frame.sun_direction;
    float thickness = clouds.top - clouds.bottom;

    int steps = clouds.steps;
    float step_length = (segment.y - segment.x) / float(steps);
    float jitter = interleavedGradientNoise(fragment.xy, frame.frame_index);
    float3 scattered = float3(0.0);
    float transmittance = 1.0;
    float weighted_distance = 0.0;
    float weight_total = 0.0;
    for (int i = 0; i < steps; i++) {
        float t = segment.x + (float(i) + jitter) * step_length;
        float3 position = camera + direction * t;
        float altitude = cloudAltitude(clouds, position, camera);
        float sigma = cloudDensity(clouds, linear, position, altitude, true);
        if (sigma <= 0.0) continue;

        float optical_depth = 0.0;
        float reach_sun = thickness * 0.04;
        float travelled = 0.0;
        for (int j = 0; j < clouds.light_steps; j++) {
            float3 toward = position + to_sun * (travelled + reach_sun * 0.5);
            optical_depth += cloudDensity(clouds, linear, toward, cloudAltitude(clouds, toward, camera), false) * reach_sun;
            travelled += reach_sun;
            reach_sun *= 1.7;
        }
        float sun = 0.0;
        float reach_scale = 1.0;
        float share = 1.0;
        float forward = 1.0;
        for (int scattering_order = 0; scattering_order < 4; scattering_order++) {
            float phase = lerp(henyeyGreenstein(cos_sun, clouds.anisotropy * forward), henyeyGreenstein(cos_sun, -0.3 * forward), 0.25);
            sun += share * exp(-optical_depth * reach_scale) * phase;
            reach_scale *= 0.35;
            share *= 0.6;
            forward *= 0.5;
        }
        float gathered_here = 1.0 - exp(-(optical_depth + sigma * thickness * 0.06) * 2.0);
        sun *= lerp(1.0, gathered_here, 0.65);
        float height = clamp((altitude - clouds.bottom) / thickness, 0.0, 1.0);
        float3 sunlight = lerp(frame.sun_radiance, float3(luminance(frame.sun_radiance)), 0.6);
        float3 light = sunlight * sun * 3.2 + sky_up * (0.5 + 0.5 * height) * exp(-optical_depth * 0.08) * 1.6 + sky_down * (1.0 - height) * 0.6;
        if (clouds.flash.w > 0.0) {
            float away = distance(position, clouds.flash.xyz) / 700.0;
            light += float3(0.75, 0.82, 1.0) * (clouds.flash.w / (1.0 + away * away * away));
        }

        float step_transmittance = exp(-sigma * step_length);
        float contribution = transmittance * (1.0 - step_transmittance);
        scattered += contribution * light * clouds.albedo;
        weighted_distance += contribution * t;
        weight_total += contribution;
        transmittance *= step_transmittance;
        if (transmittance < 0.01) {
            transmittance = 0.0;
            break;
        }
    }
    float visible = 1.0 - smoothstep(0.6, 1.0, (weight_total > 0.0 ? weighted_distance / weight_total : segment.x) / clouds.max_distance);
    scattered *= visible;
    transmittance = lerp(1.0, transmittance, visible);
    if (clouds.cirrus > 0.0 && transmittance > 0.01) {
        float bend = (1.0 - direction.y * direction.y) / (2.0 * clouds.planet_radius);
        float cirrus_reach = cloudCrossings(camera.y, direction.y, bend, clouds.top + 5000.0).x;
        if (cirrus_reach > 0.0 && cirrus_reach < clouds.max_distance * 1.5 && cirrus_reach < limit) {
            float3 there = camera + direction * cirrus_reach + clouds.offset * 1.6;
            float4 noise = sampleVolumeRepeat(clouds.noise_texture, linear, float3(there.x / (clouds.period * 6.0), there.z / (clouds.period * 1.5), 0.4), CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES);
            float streaks = cloudRemap(noise.r * (0.5 + 0.5 * noise.g), 1.0 - clouds.cirrus * 0.7, 1.0);
            float veil = streaks * 0.55 * (1.0 - smoothstep(0.5, 1.4, cirrus_reach / clouds.max_distance));
            float3 lit = frame.sun_radiance * (0.25 / PI) + sky_up;
            scattered += transmittance * veil * lit * clouds.albedo;
            transmittance *= 1.0 - veil;
        }
    }
    float4 result = float4(scattered, transmittance);

    if (clouds.history_texture != INVALID_ID) {
        float distance_seen = weight_total > 0.0 ? weighted_distance / weight_total : segment.x;
        float4 previous = mul(frame.prev_view_proj_unjittered, float4(camera + direction * distance_seen, 1.0));
        float2 previous_uv = previous.xy / previous.w * 0.5 + 0.5;
        if (previous.w > 0.0 && all(previous_uv > 0.0) && all(previous_uv < 1.0)) {
            float4 history = sampleTextureLod(clouds.history_texture, linear, previous_uv, 0.0);
            if (history.a <= 1.0) result = lerp(history, result, clouds.history_blend);
        }
    }
    return result;
}

struct NoisePush {
    int3 size;
    int tiles_x;
};

[[vk::push_constant]] NoisePush noise_push;

float3 hash3(int3 cell, int period) {
    uint3 v = uint3((cell % period + period) % period);
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return float3(v) * (1.0 / 4294967296.0);
}

float worley(float3 uvw, int period) {
    float3 p = uvw * float(period);
    int3 cell = int3(floor(p));
    float3 f = p - float3(cell);
    float nearest = 1.0;
    for (int z = -1; z <= 1; z++)
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float3 offset = float3(x, y, z) + hash3(cell + int3(x, y, z), period) - f;
        nearest = min(nearest, dot(offset, offset));
    }
    return 1.0 - clamp(sqrt(nearest), 0.0, 1.0);
}

float worleyFbm(float3 uvw, int period) {
    return worley(uvw, period) * 0.625 + worley(uvw, period * 2) * 0.25 + worley(uvw, period * 4) * 0.125;
}

float gradient(float3 uvw, int period) {
    float3 p = uvw * float(period);
    int3 cell = int3(floor(p));
    float3 f = p - float3(cell);
    float3 fade = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float corners[8];
    for (int i = 0; i < 8; i++) {
        int3 offset = int3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        float3 direction = normalize(hash3(cell + offset, period) * 2.0 - 1.0);
        corners[i] = dot(direction, f - float3(offset));
    }
    float x00 = lerp(corners[0], corners[1], fade.x);
    float x10 = lerp(corners[2], corners[3], fade.x);
    float x01 = lerp(corners[4], corners[5], fade.x);
    float x11 = lerp(corners[6], corners[7], fade.x);
    return lerp(lerp(x00, x10, fade.y), lerp(x01, x11, fade.y), fade.z);
}

float perlinFbm(float3 uvw, int period) {
    float total = 0.0;
    float amplitude = 1.0;
    float norm = 0.0;
    for (int octave = 0; octave < 4; octave++) {
        total += gradient(uvw, period) * amplitude;
        norm += amplitude;
        amplitude *= 0.5;
        period *= 2;
    }
    return clamp(total / norm * 1.2 + 0.5, 0.0, 1.0);
}

float remap(float value, float low, float high, float new_low, float new_high) {
    return new_low + (value - low) / (high - low) * (new_high - new_low);
}

[shader("fragment")]
float4 noiseMain(float4 fragment : SV_Position) : SV_Target {
    int3 cell = volumeCell(int2(fragment.xy), noise_push.size, noise_push.tiles_x);
    float3 uvw = (float3(cell) + 0.5) / float3(noise_push.size);
    float perlin = perlinFbm(uvw, 4);
    float billows = worleyFbm(uvw, 4);
    return float4(
        clamp(remap(perlin, 0.0, 1.0, billows, 1.0), 0.0, 1.0),
        billows,
        worleyFbm(uvw, 8),
        worley(uvw, 16));
}

struct CompositePush {
    FrameConstants frame;
    CloudRef clouds;
    uint cloud_texture;
};

[[vk::push_constant]] CompositePush composite_push;

[shader("fragment")]
float4 compositeMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = composite_push.frame;
    CloudData clouds = *composite_push.clouds.data;
    float depth = fetchTexel(clouds.depth_texture, int2(fragment.xy)).r;
    if (depth > 0.0) {
        float3 position = worldPositionFromDepth(in_uv, depth, frame.inv_view_proj);
        float3 direction = normalize(position - eyePoint(frame, position));
        float2 segment = cloudSegment(clouds, frame.camera_position.y, direction.y);
        if (segment.y <= segment.x || length(position - eyePoint(frame, position)) <= segment.x) discard;
    }
    float4 result = sampleTextureLod(composite_push.cloud_texture, frame.sampler_linear_clamp, in_uv, 0.0);
    result.a = min(result.a, 1.0);
    return float4(result.rgb, 1.0 - result.a);
}
