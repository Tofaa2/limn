#version 460
#include "common.glsl"
#include "gi.glsl"

// Blends probe rays into the irradiance atlas, or the visibility atlas with
// VISIBILITY. One fragment per texel; output alpha is the blend weight.
layout(buffer_reference, scalar) readonly buffer Rays { vec4 data[]; };

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    Rays rays;
    vec4 rotation[3];
    uint rays_per_probe;
    float hysteresis;
    float max_distance;
    uint probe_stride;
    uint probe_phase;
    // Blend rate of the fast irradiance atlas.
    float fast_hysteresis;
    // Cells the grid moved this frame.
    ivec3 shift;
    // Grid updated: 0 main, 1 coarse.
    uint grid_index;
} push;

layout(location = 0) out vec4 out_value;
#ifndef VISIBILITY
layout(location = 1) out vec4 out_fast;
#endif

#ifdef VISIBILITY
const int texels = GI_VISIBILITY_TEXELS;
#else
const int texels = GI_IRRADIANCE_TEXELS;
#endif

vec3 sphericalFibonacci(float i, float n) {
    const float golden = 1.618033988749895;
    float phi = 2.0 * PI * fract(i * (golden - 1.0));
    float cos_theta = 1.0 - (2.0 * i + 1.0) / n;
    float sin_theta = sqrt(clamp(1.0 - cos_theta * cos_theta, 0.0, 1.0));
    return vec3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
}

// Border texels copy interior ones for bilinear wrap across octahedral edges.
ivec2 interiorTexel(ivec2 t) {
    int last = texels - 1;
    bool border_x = t.x == 0 || t.x == last;
    bool border_y = t.y == 0 || t.y == last;
    if (border_x && border_y) return ivec2(t.x == 0 ? last - 1 : 1, t.y == 0 ? last - 1 : 1);
    if (border_x) return ivec2(t.x == 0 ? 1 : last - 1, last - t.y);
    if (border_y) return ivec2(last - t.x, t.y == 0 ? 1 : last - 1);
    return t;
}

void main() {
    FrameConstants frame = push.frame;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    ivec2 tile = pixel / texels;
    GiGrid probe_grid = giGrid(frame, push.grid_index);
    ivec3 counts = probe_grid.counts;
    int probe = tile.x % counts.x + tile.y * counts.x + (tile.x / counts.x) * counts.x * counts.y;
    if (uint(probe) % push.probe_stride != push.probe_phase) discard;
    // Probes that scrolled in this frame start over.
    ivec3 grid = giGridCoord(probe_grid, ivec3(tile.x % counts.x, tile.y, tile.x / counts.x));
    bool fresh = false;
    for (int axis = 0; axis < 3; axis++) {
        int moved = push.shift[axis];
        if (moved > 0 && grid[axis] >= counts[axis] - moved) fresh = true;
        if (moved < 0 && grid[axis] < -moved) fresh = true;
    }
    ivec2 local = interiorTexel(pixel - tile * texels);
    vec3 direction = decodeNormal((vec2(local) - 0.5) / float(texels - 2));
    mat3 rotation = mat3(push.rotation[0].xyz, push.rotation[1].xyz, push.rotation[2].xyz);

    vec3 total = vec3(0.0);
    float weight_total = 0.0;
    uint first = uint(probe) * push.rays_per_probe;
    for (uint i = 0u; i < push.rays_per_probe; i++) {
        vec4 ray = push.rays.data[first + i];
        vec3 ray_direction = rotation * sphericalFibonacci(float(i), float(push.rays_per_probe));
        float weight = max(dot(direction, ray_direction), 0.0);
#ifdef VISIBILITY
        // Sharp lobe for the Chebyshev test.
        weight = pow(weight, 50.0);
        float distance = min(abs(ray.a), push.max_distance);
        total.rg += vec2(distance, distance * distance) * weight;
#else
        total += ray.rgb * weight;
#endif
        weight_total += weight;
    }
    out_value = vec4(total / max(weight_total, 1e-5), fresh ? 1.0 : 1.0 - push.hysteresis);
#ifndef VISIBILITY
    out_fast = vec4(out_value.rgb, fresh ? 1.0 : 1.0 - push.fast_hysteresis);
#endif
}
