#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint distance_texture;
} push;

layout(location = 0) out vec4 out_motion;

void main() {
    FrameConstants frame = push.frame;
    float here = texelFetch(TEX(push.distance_texture, frame.sampler_nearest_clamp), ivec2(gl_FragCoord.xy), 0).r;
    if (here <= 0.0) discard;
    float depth = frame.near / here;
    gl_FragDepth = depth;
    vec3 position = worldPositionFromDepth(gl_FragCoord.xy * frame.inv_resolution, depth, frame.inv_view_proj);
    vec4 clip = frame.view_proj_unjittered * vec4(position, 1.0);
    vec4 previous = frame.prev_view_proj_unjittered * vec4(position, 1.0);
    out_motion = vec4((clip.xy / clip.w - previous.xy / previous.w) * 0.5, 0.0, 1.0);
}
