#version 460
#include "common.glsl"
#include "shading.glsl"
#include "particles.glsl"

// Particles drawn as mesh instances, one per particle slot.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    EmitterRef emitter;
    Particles particles;
    // First vertex of the mesh.
    uint vertex_offset;
    // Tumble rate in radians per second.
    float spin;
} push;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out vec4 out_clip;
layout(location = 3) out vec4 out_previous_clip;

uint hashSlot(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return value;
}

// Rotates `v` about unit `axis`.
vec3 turn(vec3 v, vec3 axis, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

void main() {
    FrameConstants frame = push.frame;
    EmitterData emitter = push.emitter.data;
    uint slot = uint(gl_InstanceIndex);
    Particle particle = push.particles.data[slot];
    if (particle.age >= particle.lifetime) {
        // Dead: degenerate.
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        out_color = vec4(0.0);
        out_uv = vec2(0.0);
        out_clip = vec4(0.0, 0.0, 0.0, 1.0);
        out_previous_clip = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    Vertex vertex = frame.vertices.data[push.vertex_offset + gl_VertexIndex];
    float t = particle.age / particle.lifetime;
    float size = mix(emitter.size.x, emitter.size.y, t);
    if ((emitter.keys & 2u) != 0u)
        size = t < emitter.mid ? mix(emitter.size.x, emitter.size_mid, t / emitter.mid) : mix(emitter.size_mid, emitter.size.y, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.y >= 2u) {
        float at = t * float(emitter.curve_counts.y - 1u);
        uint key = min(uint(at), emitter.curve_counts.y - 2u);
        size = mix(emitter.curve_sizes[key], emitter.curve_sizes[key + 1u], at - float(key));
    }

    uint h = hashSlot(slot + 1u);
    vec3 axis = normalize(vec3(h & 1023u, (h >> 10) & 1023u, (h >> 20) & 1023u) / 511.5 - 1.0 + vec3(1e-3, 0.0, 0.0));
    float pace = 0.5 + float(hashSlot(h) & 1023u) / 1023.0;
    float phase = float(hashSlot(h + 7u) & 1023u) / 1023.0 * 6.2831853;
    float angle = phase + push.spin * pace * particle.age;
    float previous_angle = phase + push.spin * pace * max(particle.age - frame.delta_time, 0.0);

    vec3 world = particle.position + turn(vertex.position, axis, angle) * size;
    vec3 normal = turn(vertexNormal(vertex), axis, angle);

    vec4 color = mix(emitter.color_start, emitter.color_end, t);
    if ((emitter.keys & 1u) != 0u)
        color = t < emitter.mid ? mix(emitter.color_start, emitter.color_mid, t / emitter.mid) : mix(emitter.color_mid, emitter.color_end, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.x >= 2u) {
        float at = t * float(emitter.curve_counts.x - 1u);
        uint key = min(uint(at), emitter.curve_counts.x - 2u);
        color = mix(emitter.curve_colors[key], emitter.curve_colors[key + 1u], at - float(key));
    }
    color *= unpackUnorm4x8(vertex.color);
    if ((emitter.flags & EMITTER_LIT) != 0u) {
        vec3 light = vec3(0.0);
        if ((frame.flags & FRAME_GI) != 0u) {
            light += giAmbient(frame, particle.position) * frame.gi_intensity;
        } else if ((frame.flags & FRAME_ENVIRONMENT) != 0u) {
            light += textureLod(TEX_CUBE(frame.env_irradiance, frame.sampler_linear_clamp), normal, 0.0).rgb * frame.env_intensity;
        }
        float view_depth = -(frame.view * vec4(particle.position, 1.0)).z;
        float shadow = sunShadow(frame, particle.position, frame.sun_direction, 1.0, view_depth, 0.5);
        light += frame.sun_radiance * shadow * max(dot(normal, frame.sun_direction), 0.0) / PI;
        color.rgb *= light;
    }
    out_color = color;
    out_uv = vertex.uv;
    gl_Position = frame.view_proj * vec4(world, 1.0);
    out_clip = frame.view_proj_unjittered * vec4(world, 1.0);
    vec3 previous = particle.position - particle.velocity * frame.delta_time + turn(vertex.position, axis, previous_angle) * size;
    out_previous_clip = frame.prev_view_proj_unjittered * vec4(previous, 1.0);
}
