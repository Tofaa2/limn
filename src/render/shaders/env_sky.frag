#version 460
#include "common.glsl"
#include "environment.glsl"
#include "clouds.glsl"

layout(push_constant, scalar) uniform Push {
    vec3 to_sun;
    uint face;
    vec3 ground_color;
    float turbidity;
    float intensity;
    float max_radiance;
    float sun_disc;
    float stars;
    vec3 to_moon;
    float moon;
    float ozone;
    CloudData clouds;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

const float PLANET_RADIUS = 6360e3;
const float ATMOSPHERE_RADIUS = 6420e3;
const float RAYLEIGH_HEIGHT = 8000.0;
const float MIE_HEIGHT = 1200.0;
const vec3 RAYLEIGH = vec3(5.8e-6, 13.5e-6, 33.1e-6);
const float MIE = 4e-6;
const vec3 OZONE = vec3(0.650e-6, 1.881e-6, 0.085e-6);

float ozoneDensity(float height) {
    return max(1.0 - abs(height - 25e3) / 15e3, 0.0);
}
const float SUN_STRENGTH = 8.0;

float sphereExit(vec3 origin, vec3 direction, float radius) {
    float b = dot(origin, direction);
    float c = dot(origin, origin) - radius * radius;
    float discriminant = b * b - c;
    if (discriminant < 0.0) return -1.0;
    return -b + sqrt(discriminant);
}

bool hitsPlanet(vec3 origin, vec3 direction) {
    float b = dot(origin, direction);
    float c = dot(origin, origin) - PLANET_RADIUS * PLANET_RADIUS;
    float discriminant = b * b - c;
    return discriminant > 0.0 && -b - sqrt(discriminant) > 0.0;
}

void main() {
    vec3 direction = cubeDirection(push.face, in_uv);
    vec3 sun = normalize(push.to_sun);
    float mie_strength = MIE * push.turbidity;
    vec3 origin = vec3(0.0, PLANET_RADIUS + 200.0, 0.0);

    vec3 ray = normalize(vec3(direction.x, max(direction.y, 0.0), direction.z));
    float distance_out = sphereExit(origin, ray, ATMOSPHERE_RADIUS);
    const int steps = 24;
    const int light_steps = 6;
    float depth_rayleigh = 0.0;
    float depth_mie = 0.0;
    float depth_ozone = 0.0;
    vec3 ozone = OZONE * push.ozone;
    vec3 sum_rayleigh = vec3(0.0);
    vec3 sum_mie = vec3(0.0);
    vec3 sum_multiple = vec3(0.0);
    vec3 overhead_glow = vec3(0.0);
    {
        const int column_steps = 12;
        float column_step = (ATMOSPHERE_RADIUS - PLANET_RADIUS) / float(column_steps);
        float up_mu = sun.y;
        float up_phase = 3.0 / (16.0 * PI) * (1.0 + up_mu * up_mu);
        for (int i = 0; i < column_steps; i++) {
            float column_height = (float(i) + 0.5) * column_step;
            vec3 column_point = vec3(0.0, PLANET_RADIUS + column_height, 0.0);
            if (hitsPlanet(column_point, sun)) continue;
            float lit_step = sphereExit(column_point, sun, ATMOSPHERE_RADIUS) / float(light_steps);
            float lit_rayleigh = 0.0;
            float lit_mie = 0.0;
            float lit_ozone = 0.0;
            for (int j = 0; j < light_steps; j++) {
                float lit_height = max(length(column_point + sun * (lit_step * (float(j) + 0.5))) - PLANET_RADIUS, 0.0);
                lit_rayleigh += exp(-lit_height / RAYLEIGH_HEIGHT) * lit_step;
                lit_mie += exp(-lit_height / MIE_HEIGHT) * lit_step;
                lit_ozone += ozoneDensity(lit_height) * lit_step;
            }
            vec3 arriving = exp(-(RAYLEIGH * lit_rayleigh + mie_strength * 1.1 * lit_mie + ozone * lit_ozone));
            overhead_glow += arriving * (RAYLEIGH * exp(-column_height / RAYLEIGH_HEIGHT) * up_phase + mie_strength * exp(-column_height / MIE_HEIGHT) / (4.0 * PI)) * column_step;
        }
        overhead_glow *= 4.0 * PI;
    }
    for (int i = 0; i < steps; i++) {
        float start = distance_out * (float(i) / float(steps)) * (float(i) / float(steps));
        float end = distance_out * (float(i + 1) / float(steps)) * (float(i + 1) / float(steps));
        float step_length = end - start;
        vec3 point = origin + ray * (0.5 * (start + end));
        float height = length(point) - PLANET_RADIUS;
        float density_rayleigh = exp(-height / RAYLEIGH_HEIGHT) * step_length;
        float density_mie = exp(-height / MIE_HEIGHT) * step_length;
        depth_rayleigh += density_rayleigh;
        depth_mie += density_mie;
        depth_ozone += ozoneDensity(height) * step_length;
        if (hitsPlanet(point, sun)) {
            vec3 scatter_at = RAYLEIGH * exp(-height / RAYLEIGH_HEIGHT) + mie_strength * exp(-height / MIE_HEIGHT);
            vec3 view_only = exp(-(RAYLEIGH * depth_rayleigh + mie_strength * 1.1 * depth_mie + ozone * depth_ozone));
            sum_multiple += view_only * scatter_at * step_length * overhead_glow;
            continue;
        }
        float light_step = sphereExit(point, sun, ATMOSPHERE_RADIUS) / float(light_steps);
        float light_rayleigh = 0.0;
        float light_mie = 0.0;
        float light_ozone = 0.0;
        for (int j = 0; j < light_steps; j++) {
            float light_height = length(point + sun * (light_step * (float(j) + 0.5))) - PLANET_RADIUS;
            light_rayleigh += exp(-light_height / RAYLEIGH_HEIGHT) * light_step;
            light_mie += exp(-light_height / MIE_HEIGHT) * light_step;
            light_ozone += ozoneDensity(light_height) * light_step;
        }
        vec3 attenuation = exp(-(RAYLEIGH * (depth_rayleigh + light_rayleigh) + mie_strength * 1.1 * (depth_mie + light_mie) + ozone * (depth_ozone + light_ozone)));
        sum_rayleigh += attenuation * density_rayleigh;
        sum_mie += attenuation * density_mie;
        vec3 scatter_here = RAYLEIGH * exp(-height / RAYLEIGH_HEIGHT) + mie_strength * exp(-height / MIE_HEIGHT);
        vec3 again = 1.0 - exp(-scatter_here * RAYLEIGH_HEIGHT);
        sum_multiple += attenuation * scatter_here * step_length * again / (1.0 - again);
    }
    float mu = dot(ray, sun);
    float phase_rayleigh = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    const float g = 0.76;
    float phase_mie = 3.0 / (8.0 * PI) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    vec3 color = SUN_STRENGTH * (sum_rayleigh * RAYLEIGH * phase_rayleigh + sum_mie * mie_strength * phase_mie + sum_multiple / (4.0 * PI));

    vec3 view_transmittance = exp(-(RAYLEIGH * depth_rayleigh + mie_strength * 1.1 * depth_mie + ozone * depth_ozone));

    vec3 transmittance = view_transmittance;
    float disc = smoothstep(0.99985, 0.99995, dot(direction, sun)) * push.sun_disc;
    color += transmittance * SUN_STRENGTH * 40.0 * disc * float(direction.y > 0.0);

    if (push.stars > 0.0 && direction.y > 0.0) {
        vec3 grid = direction * 90.0;
        vec3 cell = floor(grid);
        vec3 seed = fract(sin(vec3(dot(cell, vec3(127.1, 311.7, 74.7)), dot(cell, vec3(269.5, 183.3, 246.1)), dot(cell, vec3(113.5, 271.9, 124.6)))) * 43758.5453);
        float present = step(0.93, seed.x);
        float spot = smoothstep(0.35, 0.0, length(grid - cell - 0.25 - 0.5 * seed));
        vec3 tint = mix(vec3(1.0, 0.82, 0.65), vec3(0.7, 0.82, 1.0), seed.y);
        color += tint * (present * spot * (0.3 + seed.z * seed.z * 3.0) * push.stars * 0.02 * smoothstep(0.05, -0.2, sun.y)) * transmittance;
    }
    if (push.clouds.density > 0.0 && direction.y > 0.0 && !hitsPlanet(origin, sun)) {
        CloudData clouds = push.clouds;
        float sun_step = sphereExit(origin, sun, ATMOSPHERE_RADIUS) / 6.0;
        float sun_rayleigh = 0.0;
        float sun_mie = 0.0;
        float sun_ozone = 0.0;
        for (int j = 0; j < 6; j++) {
            float sun_height = length(origin + sun * (sun_step * (float(j) + 0.5))) - PLANET_RADIUS;
            sun_rayleigh += exp(-sun_height / RAYLEIGH_HEIGHT) * sun_step;
            sun_mie += exp(-sun_height / MIE_HEIGHT) * sun_step;
            sun_ozone += ozoneDensity(sun_height) * sun_step;
        }
        vec3 sunlight = SUN_STRENGTH * exp(-(RAYLEIGH * sun_rayleigh + mie_strength * 1.1 * sun_mie + ozone * sun_ozone));
        color = cloudsOverSky(clouds, direction, sun, sunlight, color);
    }
    if (push.moon > 0.0 && direction.y > 0.0) {
        float moon_disc = smoothstep(0.9990, 0.9994, dot(direction, normalize(push.to_moon)));
        color += transmittance * vec3(0.92, 0.95, 1.0) * (moon_disc * push.moon * 0.6);
    }
    if (direction.y < 0.0) {
        vec3 ground = push.ground_color * (color + SUN_STRENGTH * 0.25 * max(sun.y, 0.0) * transmittance);
        color = mix(color, ground, smoothstep(0.0, 0.04, -direction.y));
    }
    out_color = vec4(min(color * push.intensity, vec3(push.max_radiance)), 1.0);
}
