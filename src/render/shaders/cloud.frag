#version 460
#include "common.glsl"
#include "clouds.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    CloudRef clouds;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_clouds;

float henyeyGreenstein(float cos_theta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5));
}

void main() {
    FrameConstants frame = push.frame;
    CloudData clouds = push.clouds.data;
    uint linear = frame.sampler_linear_clamp;
    uint nearest = frame.sampler_nearest_clamp;
    vec3 camera = frame.camera_position;
    vec3 direction = normalize(worldPositionFromDepth(in_uv, 1e-6, frame.inv_view_proj) - camera);
    vec2 segment = cloudSegment(clouds, camera.y, direction.y);
    segment.y = min(segment.y, clouds.max_distance);
    out_clouds = vec4(0.0, 0.0, 0.0, 1.0);
    if (segment.y <= segment.x) return;

    vec2 reach = abs(vec2(dFdx(in_uv.x), dFdy(in_uv.y)));
    float limit = 0.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        vec2 uv = in_uv + vec2(x, y) * reach;
        float depth = textureLod(TEX(clouds.depth_texture, nearest), uv, 0.0).r;
        float distance_there = depth > 0.0 ? length(worldPositionFromDepth(uv, depth, frame.inv_view_proj) - camera) : 1e30;
        limit = max(limit, distance_there);
    }
    if (limit <= segment.x) {
        out_clouds = vec4(0.0, 0.0, 0.0, 2.0);
        return;
    }
    segment.y = min(segment.y, limit);

    float cos_sun = dot(direction, frame.sun_direction);
    vec3 sky_up = vec3(0.0);
    vec3 sky_down = vec3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u) {
        sky_up = textureLod(TEX_CUBE(frame.env_irradiance, linear), vec3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity * clouds.ambient;
        sky_down = textureLod(TEX_CUBE(frame.env_irradiance, linear), vec3(0.0, -1.0, 0.0), 0.0).rgb * frame.env_intensity * clouds.ambient;
    }
    vec3 to_sun = frame.sun_direction;
    float thickness = clouds.top - clouds.bottom;

    int steps = clouds.steps;
    float step_length = (segment.y - segment.x) / float(steps);
    float jitter = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index);
    vec3 scattered = vec3(0.0);
    float transmittance = 1.0;
    float weighted_distance = 0.0;
    float weight_total = 0.0;
    for (int i = 0; i < steps; i++) {
        float t = segment.x + (float(i) + jitter) * step_length;
        vec3 position = camera + direction * t;
        float altitude = cloudAltitude(clouds, position, camera);
        float sigma = cloudDensity(clouds, linear, position, altitude, true);
        if (sigma <= 0.0) continue;

        float optical_depth = 0.0;
        float reach_sun = thickness * 0.04;
        float travelled = 0.0;
        for (int j = 0; j < clouds.light_steps; j++) {
            vec3 toward = position + to_sun * (travelled + reach_sun * 0.5);
            optical_depth += cloudDensity(clouds, linear, toward, cloudAltitude(clouds, toward, camera), false) * reach_sun;
            travelled += reach_sun;
            reach_sun *= 1.7;
        }
        float sun = 0.0;
        float reach = 1.0;
        float share = 1.0;
        float forward = 1.0;
        for (int order = 0; order < 4; order++) {
            float phase = mix(henyeyGreenstein(cos_sun, clouds.anisotropy * forward), henyeyGreenstein(cos_sun, -0.3 * forward), 0.25);
            sun += share * exp(-optical_depth * reach) * phase;
            reach *= 0.35;
            share *= 0.6;
            forward *= 0.5;
        }
        float gathered_here = 1.0 - exp(-(optical_depth + sigma * thickness * 0.06) * 2.0);
        sun *= mix(1.0, gathered_here, 0.65);
        float height = clamp((altitude - clouds.bottom) / thickness, 0.0, 1.0);
        vec3 sunlight = mix(frame.sun_radiance, vec3(luminance(frame.sun_radiance)), 0.6);
        vec3 light = sunlight * sun * 3.2 + sky_up * (0.5 + 0.5 * height) * exp(-optical_depth * 0.08) * 1.6 + sky_down * (1.0 - height) * 0.6;
        if (clouds.flash.w > 0.0) {
            float away = distance(position, clouds.flash.xyz) / 700.0;
            light += vec3(0.75, 0.82, 1.0) * (clouds.flash.w / (1.0 + away * away * away));
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
    transmittance = mix(1.0, transmittance, visible);
    if (clouds.cirrus > 0.0 && transmittance > 0.01) {
        float bend = (1.0 - direction.y * direction.y) / (2.0 * clouds.planet_radius);
        float reach = cloudCrossings(camera.y, direction.y, bend, clouds.top + 5000.0).x;
        if (reach > 0.0 && reach < clouds.max_distance * 1.5 && reach < limit) {
            vec3 there = camera + direction * reach + clouds.offset * 1.6;
            vec4 noise = sampleVolumeRepeat(clouds.noise_texture, linear, vec3(there.x / (clouds.period * 6.0), there.z / (clouds.period * 1.5), 0.4), CLOUD_NOISE_SIZE, CLOUD_NOISE_TILES);
            float streaks = cloudRemap(noise.r * (0.5 + 0.5 * noise.g), 1.0 - clouds.cirrus * 0.7, 1.0);
            float veil = streaks * 0.55 * (1.0 - smoothstep(0.5, 1.4, reach / clouds.max_distance));
            vec3 lit = frame.sun_radiance * (0.25 / PI) + sky_up;
            scattered += transmittance * veil * lit * clouds.albedo;
            transmittance *= 1.0 - veil;
        }
    }
    out_clouds = vec4(scattered, transmittance);

    if (clouds.history_texture != INVALID_ID) {
        float distance_seen = weight_total > 0.0 ? weighted_distance / weight_total : segment.x;
        vec4 previous = frame.prev_view_proj_unjittered * vec4(camera + direction * distance_seen, 1.0);
        vec2 previous_uv = previous.xy / previous.w * 0.5 + 0.5;
        if (previous.w > 0.0 && all(greaterThan(previous_uv, vec2(0.0))) && all(lessThan(previous_uv, vec2(1.0)))) {
            vec4 history = textureLod(TEX(clouds.history_texture, linear), previous_uv, 0.0);
            if (history.a <= 1.0) out_clouds = mix(history, out_clouds, clouds.history_blend);
        }
    }
}
