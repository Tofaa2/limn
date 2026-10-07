#version 460
#include "common.glsl"
#include "shading.glsl"
#include "particles.glsl"

// Particle trails: one camera-facing quad per segment between recorded points.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    EmitterRef emitter;
    Particles particles;
    uint depth_texture;
    uint push_pad;
    ParticleOrder order;
    TrailPoints trail;
} push;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out float out_view_depth;
layout(location = 3) out vec4 out_clip;
layout(location = 4) out vec4 out_previous_clip;

// Ribbon point `k`: 0 is the particle, then recorded positions newest first.
vec3 ribbonPoint(EmitterData emitter, uint slot, vec3 head, uint k) {
    if (k == 0u) return head;
    uint count = emitter.trail_count;
    uint index = (emitter.trail_head + count - (k - 1u)) % count;
    vec3 point = push.trail.data[slot * count + index].xyz;
    if (k == count && count > 1u) {
        // The oldest point slides toward the next so the tail shortens
        // smoothly.
        uint newer = (emitter.trail_head + count - (k - 2u)) % count;
        point = mix(point, push.trail.data[slot * count + newer].xyz, emitter.trail_fraction);
    }
    return point;
}

void main() {
    FrameConstants frame = push.frame;
    EmitterData emitter = push.emitter.data;
    uint count = max(emitter.trail_count, 1u);
    uint slot = uint(gl_VertexIndex) / (6u * count);
    uint segment = (uint(gl_VertexIndex) / 6u) % count;
    Particle particle = push.particles.data[slot];
    if (particle.age >= particle.lifetime) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        out_color = vec4(0.0);
        out_uv = vec2(0.0);
        out_view_depth = 0.0;
        out_clip = vec4(0.0, 0.0, 0.0, 1.0);
        out_previous_clip = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    // x: side of the ribbon, y: end of the segment.
    const vec2 corners[6] = vec2[](vec2(-1, 0), vec2(1, 0), vec2(1, 1), vec2(-1, 0), vec2(1, 1), vec2(-1, 1));
    vec2 corner = corners[gl_VertexIndex % 6];
    uint k = segment + uint(corner.y);
    float along = float(k) / float(count);

    vec3 center = ribbonPoint(emitter, slot, particle.position, k);
    vec3 ahead = ribbonPoint(emitter, slot, particle.position, k > 0u ? k - 1u : 0u);
    vec3 behind = ribbonPoint(emitter, slot, particle.position, min(k + 1u, count));
    vec3 direction = ahead - behind;
    if (dot(direction, direction) < 1e-10) direction = particle.velocity;
    vec3 toward = normalize(center - frame.camera_position);
    vec3 across = cross(direction, toward);
    float across_length = length(across);
    across = across_length > 1e-6 ? across / across_length : frame.inv_view[0].xyz;

    float t = particle.age / particle.lifetime;
    float size = mix(emitter.size.x, emitter.size.y, t);
    if ((emitter.keys & 2u) != 0u)
        size = t < emitter.mid ? mix(emitter.size.x, emitter.size_mid, t / emitter.mid) : mix(emitter.size_mid, emitter.size.y, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.y >= 2u) {
        float at = t * float(emitter.curve_counts.y - 1u);
        uint key = min(uint(at), emitter.curve_counts.y - 2u);
        size = mix(emitter.curve_sizes[key], emitter.curve_sizes[key + 1u], at - float(key));
    }
    float taper = 1.0 - along;
    vec3 world = center + across * corner.x * size * 0.5 * taper;

    vec4 color = mix(emitter.color_start, emitter.color_end, t);
    if ((emitter.keys & 1u) != 0u)
        color = t < emitter.mid ? mix(emitter.color_start, emitter.color_mid, t / emitter.mid) : mix(emitter.color_mid, emitter.color_end, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.x >= 2u) {
        float at = t * float(emitter.curve_counts.x - 1u);
        uint key = min(uint(at), emitter.curve_counts.x - 2u);
        color = mix(emitter.curve_colors[key], emitter.curve_colors[key + 1u], at - float(key));
    }
    color.a *= taper;
    float view_depth = -(frame.view * vec4(particle.position, 1.0)).z;
    if ((emitter.flags & EMITTER_LIT) != 0u) {
        vec3 light = vec3(0.0);
        if ((frame.flags & FRAME_GI) != 0u) {
            light += giAmbient(frame, particle.position) * frame.gi_intensity;
        } else if ((frame.flags & FRAME_ENVIRONMENT) != 0u) {
            light += textureLod(TEX_CUBE(frame.env_irradiance, frame.sampler_linear_clamp), vec3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
        }
        float shadow = sunShadow(frame, particle.position, frame.sun_direction, 1.0, view_depth, 0.5);
        light += frame.sun_radiance * shadow * (0.5 / PI);
        color.rgb *= light;
    }
    out_color = color;
    out_uv = vec2(corner.x * 0.5 + 0.5, emitter.image != INVALID_ID ? along : 0.5);
    out_view_depth = -(frame.view * vec4(world, 1.0)).z;
    gl_Position = frame.view_proj * vec4(world, 1.0);
    out_clip = frame.view_proj_unjittered * vec4(world, 1.0);
    out_previous_clip = frame.prev_view_proj_unjittered * vec4(world - (k == 0u ? particle.velocity * frame.delta_time : vec3(0.0)), 1.0);
}
