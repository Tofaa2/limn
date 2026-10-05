#version 460
#include "common.glsl"
#include "particles.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    EmitterRef emitter;
    Particles particles;
    uint vertex_offset;
    float spin;
} push;

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_clip;
layout(location = 3) in vec4 in_previous_clip;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec4 out_motion;

void main() {
    FrameConstants frame = push.frame;
    EmitterData emitter = push.emitter.data;
    vec4 color = in_color;
    if (emitter.image != INVALID_ID) color *= texture(TEX(emitter.image, frame.sampler_linear_repeat), in_uv);
    if (color.a <= 0.0) discard;
    out_color = vec4(color.rgb * color.a, (emitter.flags & EMITTER_ADDITIVE) != 0u ? 0.0 : color.a);
    out_motion = vec4((in_clip.xy / in_clip.w - in_previous_clip.xy / in_previous_clip.w) * 0.5, 0.0, color.a);
}
