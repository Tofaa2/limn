#version 460
#include "common.glsl"
#include "particles.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    EmitterRef emitter;
    Particles particles;
    uint depth_texture;
    uint push_pad;
    ParticleOrder order;
} push;

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in float in_view_depth;
layout(location = 3) in vec4 in_clip;
layout(location = 4) in vec4 in_previous_clip;

layout(location = 0) out vec4 out_color;
// Screen motion, weighted by coverage.
layout(location = 1) out vec4 out_motion;

void main() {
    FrameConstants frame = push.frame;
    EmitterData emitter = push.emitter.data;
    vec4 color = in_color;
    if (emitter.image != INVALID_ID) {
        color *= texture(TEX(emitter.image, frame.sampler_linear_clamp), in_uv);
    } else {
        vec2 centered = in_uv * 2.0 - 1.0;
        float falloff = clamp(1.0 - dot(centered, centered), 0.0, 1.0);
        color.a *= falloff * falloff;
    }
    // Manual depth test, with soft fade near surfaces.
    float scene = linearDepth(texelFetch(TEX(push.depth_texture, frame.sampler_nearest_clamp), ivec2(gl_FragCoord.xy), 0).r, frame.near);
    float fade = emitter.softness > 0.0 ? clamp((scene - in_view_depth) / emitter.softness, 0.0, 1.0) : float(scene > in_view_depth);
    color.a *= fade;
    if (color.a <= 0.0) discard;
    // Premultiplied; additive particles write zero alpha.
    out_color = vec4(color.rgb * color.a, (emitter.flags & EMITTER_ADDITIVE) != 0u ? 0.0 : color.a);
    out_motion = vec4((in_clip.xy / in_clip.w - in_previous_clip.xy / in_previous_clip.w) * 0.5, 0.0, color.a);
}
