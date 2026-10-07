#version 460
#include "common.glsl"

// Blends reduced-resolution depth of field over the sharp image by blur radius.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint color_texture;
    uint blurred_texture;
    uint depth_texture;
    float focus_distance;
    float strength;
    float max_radius;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    FrameConstants frame = push.frame;
    float focus_distance = push.focus_distance;
    if (focus_distance < 0.0) focus_distance = max(frame.exposure.focus, frame.near);
    float view_depth = linearDepth(textureLod(TEX(push.depth_texture, frame.sampler_nearest_clamp), in_uv, 0.0).r, frame.near);
    float radius = min(push.strength * abs(view_depth - focus_distance) / max(view_depth, 1e-3), push.max_radius);
    vec3 sharp = texelFetch(TEX(push.color_texture, frame.sampler_nearest_clamp), ivec2(gl_FragCoord.xy), 0).rgb;
    vec4 blurred = textureLod(TEX(push.blurred_texture, frame.sampler_linear_clamp), in_uv, 0.0);
    float spilled = blurred.a * push.max_radius;
    float amount = smoothstep(0.5, 2.5, max(radius, spilled));
    out_color = vec4(mix(sharp, blurred.rgb, amount), 1.0);
}
