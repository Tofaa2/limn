#ifndef WATER_GLSL
#define WATER_GLSL

struct WaterRipple {
    vec2 position;
    float radius;
    float depth;
};

struct WaterData {
    mat4 transform;
    ivec2 size;
    uint state_texture;
    uint sampler_linear;
    float dt;
    float speed;
    float keep;
    uint ripple_count;
    vec3 color;
    float murk;
    float roughness;
    float refraction;
    float swell;
    float swell_length;
    float foam;
    float caustics;
    float detail;
    float water_pad;
    WaterRipple ripples[16];
};

layout(buffer_reference, scalar) readonly buffer WaterRef { WaterData data; };

float waterSwell(WaterRef water, vec2 at, float time) {
    float amplitude = water.data.swell;
    if (amplitude <= 0.0) return 0.0;
    float k = 6.2831853 / max(water.data.swell_length, 1e-3);
    return amplitude * (
        0.5 * sin(dot(at, vec2(0.8, 0.6)) * k + time * 1.3) +
        0.3 * sin(dot(at, vec2(-0.5, 0.86)) * k * 1.7 + time * 1.9) +
        0.2 * sin(dot(at, vec2(0.2, -0.98)) * k * 2.9 + time * 2.7));
}

vec2 waterDetailSlope(float strength, vec2 at, float time, float footprint) {
    if (strength <= 0.0) return vec2(0.0);
    vec2 slope = vec2(0.0);
    float wave_length = 1.1;
    float angle = 0.4;
    for (int i = 0; i < 9; i++) {
        vec2 along = vec2(cos(angle), sin(angle));
        vec2 across = vec2(-along.y, along.x);
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

vec3 waterPoint(WaterRef water, vec2 uv, float time) {
    float height = textureLod(TEX(water.data.state_texture, water.data.sampler_linear), uv, 0.0).r;
    vec3 flat_point = (water.data.transform * vec4(uv.x - 0.5, 0.0, uv.y - 0.5, 1.0)).xyz;
    vec3 up = water.data.transform[1].xyz;
    float up_length = max(length(up), 1e-6);
    return flat_point + up * height + (up / up_length) * waterSwell(water, flat_point.xz, time);
}

float waterHeight(WaterRef water, vec2 uv, float time) {
    float height = textureLod(TEX(water.data.state_texture, water.data.sampler_linear), uv, 0.0).r;
    vec3 flat_point = (water.data.transform * vec4(uv.x - 0.5, 0.0, uv.y - 0.5, 1.0)).xyz;
    return height * length(water.data.transform[1].xyz) + waterSwell(water, flat_point.xz, time);
}

float waterDepthBelow(WaterRef water, vec3 world, vec3 to_sun, out vec2 entry_uv) {
    mat4 to_local = inverse(water.data.transform);
    vec3 local = (to_local * vec4(world, 1.0)).xyz;
    vec3 sun_local = (to_local * vec4(to_sun, 0.0)).xyz;
    float rise = max(sun_local.y, 1e-4);
    entry_uv = local.xz + sun_local.xz * (-local.y / rise) + 0.5;
    return -local.y * length(water.data.transform[1].xyz);
}

float waterCaustic(WaterRef water, vec3 world, vec3 to_sun, float time) {
    if (water.data.caustics <= 0.0 || to_sun.y <= 0.0) return 1.0;
    vec2 uv;
    float depth = waterDepthBelow(water, world, to_sun, uv);
    if (depth <= 0.0 || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 1.0;
    vec2 texel = 1.0 / vec2(water.data.size);
    vec2 cell = vec2(length(water.data.transform[0].xyz), length(water.data.transform[2].xyz)) * texel;
    float here = waterHeight(water, uv, time);
    float along_x = waterHeight(water, uv + vec2(texel.x, 0.0), time) + waterHeight(water, uv - vec2(texel.x, 0.0), time) - 2.0 * here;
    float along_z = waterHeight(water, uv + vec2(0.0, texel.y), time) + waterHeight(water, uv - vec2(0.0, texel.y), time) - 2.0 * here;
    float curvature = along_x / (cell.x * cell.x) + along_z / (cell.y * cell.y);
    float gain = clamp(1.0 - curvature * min(depth, 4.0), 0.2, 5.0);
    return mix(1.0, gain, water.data.caustics * exp(-depth * water.data.murk * 0.5));
}

#endif
