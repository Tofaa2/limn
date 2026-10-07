#version 460
#extension GL_EXT_ray_query : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#include "common.glsl"
#include "rt.glsl"

// Progressive lightmap bake: traces cosine-weighted rays from each texel and
// accumulates indirect light (hits lit by the shadowed sun and the probes).
// Direct sun is excluded. Stores irradiance / pi, as the probes do.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint64_t tlas;
    mat4 transform;
    uint vertex_offset;
    uint gathered_texture;
    uint rounds;
    uint rays;
    float reach;
} push;

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

layout(location = 0) out vec4 out_light;

uint hash(uint value) {
    value = value * 747796405u + 2891336453u;
    uint word = ((value >> ((value >> 28u) + 4u)) ^ value) * 277803737u;
    return (word >> 22u) ^ word;
}

void main() {
    FrameConstants frame = push.frame;
    // Use the surface normal; winding in the lightmap is arbitrary.
    vec3 normal = normalize(in_normal);
    uint state = hash(uint(gl_FragCoord.x) + hash(uint(gl_FragCoord.y) + hash(push.rounds)));
    vec3 hint = abs(normal.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 side = normalize(cross(hint, normal));
    vec3 other = cross(normal, side);
    vec3 total = vec3(0.0);
    uint rays = max(push.rays, 1u);
    for (uint ray = 0u; ray < rays; ray++) {
        state = hash(state);
        float turn = 2.0 * PI * float(state) / 4294967296.0;
        state = hash(state);
        float out_from = sqrt(float(state) / 4294967296.0);
        // Cosine-weighted direction.
        vec3 direction = normalize(side * cos(turn) * out_from + other * sin(turn) * out_from + normal * sqrt(max(1.0 - out_from * out_from, 0.0)));
        vec3 radiance;
        float distance_hit;
        int met = rtTrace(frame, push.tlas, in_position + normal * 0.01, direction, push.reach, 2.0, true, radiance, distance_hit);
        if (met == RT_MISS) {
            radiance = vec3(0.0);
            if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
                radiance = textureLod(TEX_CUBE(frame.env_specular, frame.sampler_linear_clamp), direction, 2.0).rgb * frame.env_intensity;
        }
        total += min(radiance, vec3(64.0));
    }
    vec3 gathered = total / float(rays);
    vec4 before = texelFetch(TEX(push.gathered_texture, frame.sampler_nearest_clamp), ivec2(gl_FragCoord.xy), 0);
    float weight = before.a > 0.0 ? 1.0 / float(push.rounds + 1u) : 1.0;
    out_light = vec4(mix(before.rgb, gathered, weight), 1.0);
}
