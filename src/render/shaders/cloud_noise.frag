#version 460
#include "common.glsl"
#include "volume.glsl"

// Fills the cloud noise volume: tiling Perlin-Worley in r, three scales of
// tiling Worley in gba (Schneider, "The Real-time Volumetric Cloudscapes of
// Horizon Zero Dawn").
layout(push_constant, scalar) uniform Push {
    ivec3 size;
    int tiles_x;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_noise;

vec3 hash3(ivec3 cell, int period) {
    uvec3 v = uvec3((cell % period + period) % period);
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return vec3(v) * (1.0 / 4294967296.0);
}

// 1 at a feature point, falling to 0 a cell away.
float worley(vec3 uvw, int period) {
    vec3 p = uvw * float(period);
    ivec3 cell = ivec3(floor(p));
    vec3 f = p - vec3(cell);
    float nearest = 1.0;
    for (int z = -1; z <= 1; z++)
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        vec3 offset = vec3(x, y, z) + hash3(cell + ivec3(x, y, z), period) - f;
        nearest = min(nearest, dot(offset, offset));
    }
    return 1.0 - clamp(sqrt(nearest), 0.0, 1.0);
}

float worleyFbm(vec3 uvw, int period) {
    return worley(uvw, period) * 0.625 + worley(uvw, period * 2) * 0.25 + worley(uvw, period * 4) * 0.125;
}

float gradient(vec3 uvw, int period) {
    vec3 p = uvw * float(period);
    ivec3 cell = ivec3(floor(p));
    vec3 f = p - vec3(cell);
    vec3 fade = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float corners[8];
    for (int i = 0; i < 8; i++) {
        ivec3 offset = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        vec3 direction = normalize(hash3(cell + offset, period) * 2.0 - 1.0);
        corners[i] = dot(direction, f - vec3(offset));
    }
    float x00 = mix(corners[0], corners[1], fade.x);
    float x10 = mix(corners[2], corners[3], fade.x);
    float x01 = mix(corners[4], corners[5], fade.x);
    float x11 = mix(corners[6], corners[7], fade.x);
    return mix(mix(x00, x10, fade.y), mix(x01, x11, fade.y), fade.z);
}

float perlinFbm(vec3 uvw, int period) {
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

void main() {
    ivec3 cell = volumeCell(ivec2(gl_FragCoord.xy), push.size, push.tiles_x);
    vec3 uvw = (vec3(cell) + 0.5) / vec3(push.size);
    float perlin = perlinFbm(uvw, 4);
    float billows = worleyFbm(uvw, 4);
    out_noise = vec4(
        clamp(remap(perlin, 0.0, 1.0, billows, 1.0), 0.0, 1.0),
        billows,
        worleyFbm(uvw, 8),
        worley(uvw, 16));
}
