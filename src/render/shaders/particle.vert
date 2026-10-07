#version 460
#include "common.glsl"
#include "shading.glsl"
#include "particles.glsl"

// Camera-facing particle quads, six vertices each, pulled from the particle
// buffer.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    EmitterRef emitter;
    Particles particles;
    uint depth_texture;
    uint push_pad;
    ParticleOrder order;
} push;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out float out_view_depth;
// Clip position now and last frame.
layout(location = 3) out vec4 out_clip;
layout(location = 4) out vec4 out_previous_clip;

void main() {
    FrameConstants frame = push.frame;
    EmitterData emitter = push.emitter.data;
    uint slot = uint(gl_VertexIndex) / 6u;
    bool listed = true;
    if ((emitter.flags & EMITTER_SORTED) != 0u) {
        slot = push.order.data[slot].index;
        listed = slot != 0xffffffffu;
        if (!listed) slot = 0u;
    }
    Particle particle = push.particles.data[slot];
    if (!listed || particle.age >= particle.lifetime) {
        // Dead: degenerate quad.
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        out_color = vec4(0.0);
        out_uv = vec2(0.0);
        out_view_depth = 0.0;
        out_clip = vec4(0.0, 0.0, 0.0, 1.0);
        out_previous_clip = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    const vec2 corners[6] = vec2[](vec2(-1, -1), vec2(1, -1), vec2(1, 1), vec2(-1, -1), vec2(1, 1), vec2(-1, 1));
    vec2 corner = corners[gl_VertexIndex % 6];
    float t = particle.age / particle.lifetime;
    float size = mix(emitter.size.x, emitter.size.y, t);
    if ((emitter.keys & 2u) != 0u)
        size = t < emitter.mid ? mix(emitter.size.x, emitter.size_mid, t / emitter.mid) : mix(emitter.size_mid, emitter.size.y, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.y >= 2u) {
        float at = t * float(emitter.curve_counts.y - 1u);
        uint key = min(uint(at), emitter.curve_counts.y - 2u);
        size = mix(emitter.curve_sizes[key], emitter.curve_sizes[key + 1u], at - float(key));
    }
    vec3 right = frame.inv_view[0].xyz;
    vec3 up = frame.inv_view[1].xyz;
    vec2 half_size = vec2(size * 0.5);
    if (emitter.stretch > 0.0) {
        vec3 toward = normalize(particle.position - frame.camera_position);
        vec3 along = particle.velocity - toward * dot(particle.velocity, toward);
        float speed = length(along);
        if (speed > 1e-4) {
            up = along / speed;
            right = normalize(cross(up, toward));
            half_size.y += emitter.stretch * speed * 0.5;
        }
    }
    vec3 world = particle.position + right * corner.x * half_size.x + up * corner.y * half_size.y;

    vec4 color = mix(emitter.color_start, emitter.color_end, t);
    if ((emitter.keys & 1u) != 0u)
        color = t < emitter.mid ? mix(emitter.color_start, emitter.color_mid, t / emitter.mid) : mix(emitter.color_mid, emitter.color_end, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.x >= 2u) {
        float at = t * float(emitter.curve_counts.x - 1u);
        uint key = min(uint(at), emitter.curve_counts.x - 2u);
        color = mix(emitter.curve_colors[key], emitter.curve_colors[key + 1u], at - float(key));
    }
    color.a *= smoothstep(0.0, 0.08, t);
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
    out_uv = corner * 0.5 + 0.5;
    if (emitter.image != INVALID_ID) {
        uint frames = max(emitter.sheet.x * emitter.sheet.y, 1u);
        uint shown = min(uint(t * float(frames)), frames - 1u);
        vec2 cell = vec2(shown % max(emitter.sheet.x, 1u), shown / max(emitter.sheet.x, 1u));
        out_uv = (cell + out_uv) / vec2(max(emitter.sheet, uvec2(1u)));
    }
    out_view_depth = -(frame.view * vec4(world, 1.0)).z;
    gl_Position = frame.view_proj * vec4(world, 1.0);
    out_clip = frame.view_proj_unjittered * vec4(world, 1.0);
    out_previous_clip = frame.prev_view_proj_unjittered * vec4(world - particle.velocity * frame.delta_time, 1.0);
}
