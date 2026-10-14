#include "common.slang"
#include "clouds.slang"
#include "brdf.slang"

float3 cubeDirection(uint face, float2 uv) {
    float2 p = uv * 2.0 - 1.0;
    float3 direction;
    switch (face) {
    case 0u: direction = float3(1.0, -p.y, -p.x); break;
    case 1u: direction = float3(-1.0, -p.y, p.x); break;
    case 2u: direction = float3(p.x, 1.0, p.y); break;
    case 3u: direction = float3(p.x, -1.0, -p.y); break;
    case 4u: direction = float3(p.x, -p.y, 1.0); break;
    default: direction = float3(-p.x, -p.y, -1.0); break;
    }
    return normalize(direction);
}

float2 equirectUv(float3 direction) {
    return float2(atan2(direction.z, direction.x) / (2.0 * PI) + 0.5, acos(clamp(direction.y, -1.0, 1.0)) / PI);
}

struct CubePush {
    uint source_texture;
    uint sampler_index;
    uint face;
    float max_radiance;
    uint from_cube;
    float3 to_sun;
    float3 sunlight;
    CloudData clouds;
};

[[vk::push_constant]] CubePush cube_push;

[shader("fragment")]
float4 cubeMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    float3 direction = cubeDirection(cube_push.face, in_uv);
    float3 color = cube_push.from_cube != 0u
        ? sampleCube(cube_push.source_texture, cube_push.sampler_index, direction).rgb
        : sampleTextureLod(cube_push.source_texture, cube_push.sampler_index, equirectUv(direction), 0.0).rgb;
    color = min(color, float3(cube_push.max_radiance));
    if (cube_push.clouds.density > 0.0 && direction.y > 0.0)
        color = cloudsOverSky(cube_push.clouds, direction, normalize(cube_push.to_sun), cube_push.sunlight, color);
    return float4(color, 1.0);
}

struct IrradiancePush {
    uint source_texture;
    uint sampler_index;
    uint face;
    float source_size;
};

[[vk::push_constant]] IrradiancePush irradiance_push;

[shader("fragment")]
float4 irradianceMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    float3 n = cubeDirection(irradiance_push.face, in_uv);
    TangentBasis basis = tangentBasis(n);
    const uint sample_count = 512u;
    float3 total = float3(0.0);
    for (uint i = 0u; i < sample_count; i++) {
        float2 xi = hammersley(i, sample_count);
        float phi = 2.0 * PI * xi.x;
        float cos_theta = sqrt(1.0 - xi.y);
        float sin_theta = sqrt(xi.y);
        float3 l = basis.toWorld(float3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta));
        float pdf = cos_theta / PI;
        float sample_solid_angle = 1.0 / (float(sample_count) * pdf + 1e-4);
        float texel_solid_angle = 4.0 * PI / (6.0 * irradiance_push.source_size * irradiance_push.source_size);
        float mip = max(0.5 * log2(sample_solid_angle / texel_solid_angle) + 1.0, 0.0);
        total += sampleCubeLod(irradiance_push.source_texture, irradiance_push.sampler_index, l, mip).rgb;
    }
    return float4(total / float(sample_count), 1.0);
}

struct PrefilterPush {
    uint source_texture;
    uint sampler_index;
    uint face;
    float source_size;
    float roughness;
};

[[vk::push_constant]] PrefilterPush prefilter_push;

[shader("fragment")]
float4 prefilterMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    float3 n = cubeDirection(prefilter_push.face, in_uv);
    if (prefilter_push.roughness <= 0.0) return float4(sampleCubeLod(prefilter_push.source_texture, prefilter_push.sampler_index, n, 0.0).rgb, 1.0);
    TangentBasis basis = tangentBasis(n);
    float alpha = prefilter_push.roughness * prefilter_push.roughness;
    const uint sample_count = 256u;
    float3 total = float3(0.0);
    float weight_total = 0.0;
    for (uint i = 0u; i < sample_count; i++) {
        float3 h = basis.toWorld(importanceSampleGgx(hammersley(i, sample_count), alpha));
        float3 l = reflect(-n, h);
        float n_dot_l = dot(n, l);
        if (n_dot_l <= 0.0) continue;
        float n_dot_h = max(dot(n, h), 0.0);
        float pdf = distributionGgx(n_dot_h, alpha) * 0.25;
        float sample_solid_angle = 1.0 / (float(sample_count) * pdf + 1e-4);
        float texel_solid_angle = 4.0 * PI / (6.0 * prefilter_push.source_size * prefilter_push.source_size);
        float mip = max(0.5 * log2(sample_solid_angle / texel_solid_angle) + 1.0, 0.0);
        total += sampleCubeLod(prefilter_push.source_texture, prefilter_push.sampler_index, l, mip).rgb * n_dot_l;
        weight_total += n_dot_l;
    }
    return float4(total / max(weight_total, 1e-4), 1.0);
}

struct SkyPush {
    float3 to_sun;
    uint face;
    float3 ground_color;
    float turbidity;
    float intensity;
    float max_radiance;
    float sun_disc;
    float stars;
    float3 to_moon;
    float moon;
    float ozone;
    CloudData clouds;
};

[[vk::push_constant]] SkyPush sky_push;

static const float PLANET_RADIUS = 6360e3;
static const float ATMOSPHERE_RADIUS = 6420e3;
static const float RAYLEIGH_HEIGHT = 8000.0;
static const float MIE_HEIGHT = 1200.0;
static const float3 RAYLEIGH = float3(5.8e-6, 13.5e-6, 33.1e-6);
static const float MIE = 4e-6;
static const float3 OZONE = float3(0.650e-6, 1.881e-6, 0.085e-6);

float ozoneDensity(float height) {
    return max(1.0 - abs(height - 25e3) / 15e3, 0.0);
}
static const float SUN_STRENGTH = 8.0;

float sphereExit(float3 origin, float3 direction, float radius) {
    float b = dot(origin, direction);
    float c = dot(origin, origin) - radius * radius;
    float discriminant = b * b - c;
    if (discriminant < 0.0) return -1.0;
    return -b + sqrt(discriminant);
}

bool hitsPlanet(float3 origin, float3 direction) {
    float b = dot(origin, direction);
    float c = dot(origin, origin) - PLANET_RADIUS * PLANET_RADIUS;
    float discriminant = b * b - c;
    return discriminant > 0.0 && -b - sqrt(discriminant) > 0.0;
}

[shader("fragment")]
float4 skyMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    float3 direction = cubeDirection(sky_push.face, in_uv);
    float3 sun = normalize(sky_push.to_sun);
    float mie_strength = MIE * sky_push.turbidity;
    float3 origin = float3(0.0, PLANET_RADIUS + 200.0, 0.0);

    float3 ray = normalize(float3(direction.x, max(direction.y, 0.0), direction.z));
    float distance_out = sphereExit(origin, ray, ATMOSPHERE_RADIUS);
    const int steps = 24;
    const int light_steps = 6;
    float depth_rayleigh = 0.0;
    float depth_mie = 0.0;
    float depth_ozone = 0.0;
    float3 ozone = OZONE * sky_push.ozone;
    float3 sum_rayleigh = float3(0.0);
    float3 sum_mie = float3(0.0);
    float3 sum_multiple = float3(0.0);
    float3 overhead_glow = float3(0.0);
    {
        const int column_steps = 12;
        float column_step = (ATMOSPHERE_RADIUS - PLANET_RADIUS) / float(column_steps);
        float up_mu = sun.y;
        float up_phase = 3.0 / (16.0 * PI) * (1.0 + up_mu * up_mu);
        for (int i = 0; i < column_steps; i++) {
            float column_height = (float(i) + 0.5) * column_step;
            float3 column_point = float3(0.0, PLANET_RADIUS + column_height, 0.0);
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
            float3 arriving = exp(-(RAYLEIGH * lit_rayleigh + mie_strength * 1.1 * lit_mie + ozone * lit_ozone));
            overhead_glow += arriving * (RAYLEIGH * exp(-column_height / RAYLEIGH_HEIGHT) * up_phase + mie_strength * exp(-column_height / MIE_HEIGHT) / (4.0 * PI)) * column_step;
        }
        overhead_glow *= 4.0 * PI;
    }
    for (int i = 0; i < steps; i++) {
        float start = distance_out * (float(i) / float(steps)) * (float(i) / float(steps));
        float end = distance_out * (float(i + 1) / float(steps)) * (float(i + 1) / float(steps));
        float step_length = end - start;
        float3 point = origin + ray * (0.5 * (start + end));
        float height = length(point) - PLANET_RADIUS;
        float density_rayleigh = exp(-height / RAYLEIGH_HEIGHT) * step_length;
        float density_mie = exp(-height / MIE_HEIGHT) * step_length;
        depth_rayleigh += density_rayleigh;
        depth_mie += density_mie;
        depth_ozone += ozoneDensity(height) * step_length;
        if (hitsPlanet(point, sun)) {
            float3 scatter_at = RAYLEIGH * exp(-height / RAYLEIGH_HEIGHT) + mie_strength * exp(-height / MIE_HEIGHT);
            float3 view_only = exp(-(RAYLEIGH * depth_rayleigh + mie_strength * 1.1 * depth_mie + ozone * depth_ozone));
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
        float3 attenuation = exp(-(RAYLEIGH * (depth_rayleigh + light_rayleigh) + mie_strength * 1.1 * (depth_mie + light_mie) + ozone * (depth_ozone + light_ozone)));
        sum_rayleigh += attenuation * density_rayleigh;
        sum_mie += attenuation * density_mie;
        float3 scatter_here = RAYLEIGH * exp(-height / RAYLEIGH_HEIGHT) + mie_strength * exp(-height / MIE_HEIGHT);
        float3 again = 1.0 - exp(-scatter_here * RAYLEIGH_HEIGHT);
        sum_multiple += attenuation * scatter_here * step_length * again / (1.0 - again);
    }
    float mu = dot(ray, sun);
    float phase_rayleigh = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    const float g = 0.76;
    float phase_mie = 3.0 / (8.0 * PI) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    float3 color = SUN_STRENGTH * (sum_rayleigh * RAYLEIGH * phase_rayleigh + sum_mie * mie_strength * phase_mie + sum_multiple / (4.0 * PI));

    float3 view_transmittance = exp(-(RAYLEIGH * depth_rayleigh + mie_strength * 1.1 * depth_mie + ozone * depth_ozone));

    float3 transmittance = view_transmittance;
    float disc = smoothstep(0.99985, 0.99995, dot(direction, sun)) * sky_push.sun_disc;
    color += transmittance * SUN_STRENGTH * 40.0 * disc * float(direction.y > 0.0);

    if (sky_push.stars > 0.0 && direction.y > 0.0) {
        float3 grid = direction * 90.0;
        float3 cell = floor(grid);
        float3 seed = frac(sin(float3(dot(cell, float3(127.1, 311.7, 74.7)), dot(cell, float3(269.5, 183.3, 246.1)), dot(cell, float3(113.5, 271.9, 124.6)))) * 43758.5453);
        float present = step(0.93, seed.x);
        float spot = smoothstep(0.35, 0.0, length(grid - cell - 0.25 - 0.5 * seed));
        float3 tint = lerp(float3(1.0, 0.82, 0.65), float3(0.7, 0.82, 1.0), seed.y);
        color += tint * (present * spot * (0.3 + seed.z * seed.z * 3.0) * sky_push.stars * 0.02 * smoothstep(0.05, -0.2, sun.y)) * transmittance;
    }
    if (sky_push.clouds.density > 0.0 && direction.y > 0.0 && !hitsPlanet(origin, sun)) {
        CloudData clouds = sky_push.clouds;
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
        float3 sunlight = SUN_STRENGTH * exp(-(RAYLEIGH * sun_rayleigh + mie_strength * 1.1 * sun_mie + ozone * sun_ozone));
        color = cloudsOverSky(clouds, direction, sun, sunlight, color);
    }
    if (sky_push.moon > 0.0 && direction.y > 0.0) {
        float moon_disc = smoothstep(0.9990, 0.9994, dot(direction, normalize(sky_push.to_moon)));
        color += transmittance * float3(0.92, 0.95, 1.0) * (moon_disc * sky_push.moon * 0.6);
    }
    if (direction.y < 0.0) {
        float3 ground = sky_push.ground_color * (color + SUN_STRENGTH * 0.25 * max(sun.y, 0.0) * transmittance);
        color = lerp(color, ground, smoothstep(0.0, 0.04, -direction.y));
    }
    return float4(min(color * sky_push.intensity, float3(sky_push.max_radiance)), 1.0);
}

struct ProbeFacePush {
    uint source_texture;
    uint sampler_index;
    uint face;
    float max_radiance;
    float3 right;
    float3 up;
    float3 forward;
};

[[vk::push_constant]] ProbeFacePush probe_face_push;

[shader("fragment")]
float4 probeFaceMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    float3 direction = cubeDirection(probe_face_push.face, in_uv);
    float2 across = float2(dot(direction, probe_face_push.right), dot(direction, probe_face_push.up)) / max(dot(direction, probe_face_push.forward), 1e-4);
    float2 uv = clamp(float2(across.x * 0.5 + 0.5, 0.5 - across.y * 0.5), float2(0.0), float2(1.0));
    float3 color = sampleTextureLod(probe_face_push.source_texture, probe_face_push.sampler_index, uv, 0.0).rgb;
    return float4(min(max(color, float3(0.0)), float3(probe_face_push.max_radiance)), 1.0);
}

[shader("fragment")]
float4 brdfLutMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    float n_dot_v = max(in_uv.x, 1e-3);
    float alpha = in_uv.y * in_uv.y;
    float3 v = float3(sqrt(1.0 - n_dot_v * n_dot_v), 0.0, n_dot_v);
    const uint sample_count = 512u;
    float2 total = float2(0.0);
    for (uint i = 0u; i < sample_count; i++) {
        float3 h = importanceSampleGgx(hammersley(i, sample_count), max(alpha, 1e-4));
        float3 l = reflect(-v, h);
        float n_dot_l = clamp(l.z, 0.0, 1.0);
        float n_dot_h = clamp(h.z, 0.0, 1.0);
        float v_dot_h = clamp(dot(v, h), 0.0, 1.0);
        if (n_dot_l <= 0.0) continue;
        float visibility = visibilitySmithGgx(n_dot_l, n_dot_v, max(alpha, 1e-4)) * 4.0 * v_dot_h * n_dot_l / max(n_dot_h, 1e-5);
        float fresnel = pow(1.0 - v_dot_h, 5.0);
        total += float2((1.0 - fresnel) * visibility, fresnel * visibility);
    }
    return float4(total / float(sample_count), 0.0, 1.0);
}
