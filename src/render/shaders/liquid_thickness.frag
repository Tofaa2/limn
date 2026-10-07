#version 460
#include "common.glsl"
#include "liquid.glsl"

// Liquid thickness per pixel: each particle adds its sphere's chord length.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    LiquidRef liquid;
    LiquidParticles particles;
    uint depth_texture;
    float swell;
} push;

layout(location = 0) in vec2 in_corner;
layout(location = 1) in vec4 in_sphere;

layout(location = 0) out float out_thickness;

void main() {
    float off_center = dot(in_corner, in_corner);
    if (off_center > 1.0) discard;
    vec4 clip = push.frame.proj * vec4(in_sphere.xyz, 1.0);
    float scene = texelFetch(TEX(push.depth_texture, push.frame.sampler_nearest_clamp), ivec2(gl_FragCoord.xy), 0).r;
    if (clip.z / clip.w < scene) discard;
    // Scaled down because spheres overlap.
    out_thickness = 2.0 * in_sphere.w * sqrt(1.0 - off_center) * 0.24;
}
