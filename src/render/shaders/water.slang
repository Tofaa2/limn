#ifndef WATER_SLANG
#define WATER_SLANG
#include "common.slang"

struct WaterRipple {
    float2 position;
    float radius;
    float depth;
};

struct WaterData {
    float4x4 transform;
    int2 size;
    uint state_texture;
    uint sampler_linear;
    float dt;
    float speed;
    float keep;
    uint ripple_count;
    float3 color;
    float murk;
    float roughness;
    float refraction;
    float swell;
    float swell_length;
    float foam;
    float caustics;
    float detail;
    uint mask;
    WaterRipple ripples[16];
    float* ocean;
    float ocean_period;
    float ocean_pad;
};

typedef WaterData* WaterRef;

/// Height of the ocean tile at world `at`, filtered between its cells.
float oceanHeight(WaterRef water, float2 at) {
    float2 cell = at / water.ocean_period * 128.0 - 0.5;
    int2 base = int2(floor(cell));
    float2 t = cell - floor(cell);
    float a = water.ocean[(base.y & 127) * 128 + (base.x & 127)];
    float b = water.ocean[(base.y & 127) * 128 + ((base.x + 1) & 127)];
    float c = water.ocean[((base.y + 1) & 127) * 128 + (base.x & 127)];
    float d = water.ocean[((base.y + 1) & 127) * 128 + ((base.x + 1) & 127)];
    return lerp(lerp(a, b, t.x), lerp(c, d, t.x), t.y);
}

float waterSwell(WaterRef water, float2 at, float time) {
    if (water.ocean != nullptr) return oceanHeight(water, at);
    float amplitude = water.swell;
    if (amplitude <= 0.0) return 0.0;
    float k = 6.2831853 / max(water.swell_length, 1e-3);
    return amplitude * (
        0.5 * sin(dot(at, float2(0.8, 0.6)) * k + time * 1.3) +
        0.3 * sin(dot(at, float2(-0.5, 0.86)) * k * 1.7 + time * 1.9) +
        0.2 * sin(dot(at, float2(0.2, -0.98)) * k * 2.9 + time * 2.7));
}

float2 waterDetailSlope(float strength, float2 at, float time, float footprint) {
    if (strength <= 0.0) return float2(0.0);
    float2 slope = float2(0.0);
    float wave_length = 1.1;
    float angle = 0.4;
    for (int i = 0; i < 9; i++) {
        float2 along = float2(cos(angle), sin(angle));
        float2 across = float2(-along.y, along.x);
        float k = 6.2831853 / wave_length;
        float wander = sin(dot(at, across) * k * 0.23 + float(i) * 2.1 + time * 0.31) * 1.3 +
            sin(dot(at, along) * k * 0.11 + float(i) * 0.7) * 1.9;
        float phase = dot(at, along) * k + time * sqrt(9.81 * k) + wander + float(i) * 1.7;
        float seen = clamp(wave_length / max(footprint, 1.0e-5) * 0.25 - 0.5, 0.0, 1.0);
        slope += along * (cos(phase) * strength * 0.05 * seen);
        wave_length *= 0.71;
        angle += 2.39996 + float(i) * 0.37;
    }
    return slope;
}

float3 waterPoint(WaterRef water, float2 uv, float time) {
    float height = sampleTextureLod(water.state_texture, water.sampler_linear, uv, 0.0).r;
    float3 flat_point = mul(water.transform, float4(uv.x - 0.5, 0.0, uv.y - 0.5, 1.0)).xyz;
    float3 up = matrixColumn(water.transform, 1);
    float up_length = max(length(up), 1e-6);
    return flat_point + up * height + (up / up_length) * waterSwell(water, flat_point.xz, time);
}

float waterHeight(WaterRef water, float2 uv, float time) {
    float height = sampleTextureLod(water.state_texture, water.sampler_linear, uv, 0.0).r;
    float3 flat_point = mul(water.transform, float4(uv.x - 0.5, 0.0, uv.y - 0.5, 1.0)).xyz;
    return height * length(matrixColumn(water.transform, 1)) + waterSwell(water, flat_point.xz, time);
}

float waterDepthBelow(WaterRef water, float3 world, float3 to_sun, out float2 entry_uv) {
    float4x4 to_local = matrixInverse(water.transform);
    float3 local = mul(to_local, float4(world, 1.0)).xyz;
    float3 sun_local = mul(to_local, float4(to_sun, 0.0)).xyz;
    float rise = max(sun_local.y, 1e-4);
    entry_uv = local.xz + sun_local.xz * (-local.y / rise) + 0.5;
    return -local.y * length(matrixColumn(water.transform, 1));
}

float waterCaustic(WaterRef water, float3 world, float3 to_sun, float time) {
    if (water.caustics <= 0.0 || to_sun.y <= 0.0) return 1.0;
    float2 uv;
    float depth = waterDepthBelow(water, world, to_sun, uv);
    if (depth <= 0.0 || any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    float2 texel = 1.0 / float2(water.size);
    float2 cell = float2(length(matrixColumn(water.transform, 0)), length(matrixColumn(water.transform, 2))) * texel;
    float here = waterHeight(water, uv, time);
    float along_x = waterHeight(water, uv + float2(texel.x, 0.0), time) + waterHeight(water, uv - float2(texel.x, 0.0), time) - 2.0 * here;
    float along_z = waterHeight(water, uv + float2(0.0, texel.y), time) + waterHeight(water, uv - float2(0.0, texel.y), time) - 2.0 * here;
    float curvature = along_x / (cell.x * cell.x) + along_z / (cell.y * cell.y);
    float gain = clamp(1.0 - curvature * min(depth, 4.0), 0.2, 5.0);
    return lerp(1.0, gain, water.caustics * exp(-depth * water.murk * 0.5));
}

#endif
