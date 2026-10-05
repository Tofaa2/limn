#version 460
#include "common.glsl"
#include "liquid.glsl"

// The nearest surface of a liquid's particles, each drawn as a sphere,
// into a depth buffer of its own; what is behind the scene is left out.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    LiquidRef liquid;
    LiquidParticles particles;
    uint depth_texture;
    float swell;
} push;

layout(location = 0) in vec2 in_corner;
layout(location = 1) in vec4 in_sphere;

void main() {
    float off_center = dot(in_corner, in_corner);
    if (off_center > 1.0) discard;
    vec3 surface = in_sphere.xyz + vec3(in_corner, sqrt(1.0 - off_center)) * in_sphere.w;
    vec4 clip = push.frame.proj * vec4(surface, 1.0);
    float depth = clip.z / clip.w;
    // Reverse depth: larger is nearer.
    float scene = texelFetch(TEX(push.depth_texture, push.frame.sampler_nearest_clamp), ivec2(gl_FragCoord.xy), 0).r;
    if (depth < scene) discard;
    gl_FragDepth = depth;
}
