#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint steady_texture;
    uint albedo_texture;
    uint lamp_texture;
    uint diffuse_texture;
    uint specular_texture;
    uint depth_texture;
} push;

layout(location = 0) out vec4 out_color;

/// View depth beyond which a pixel shows no surface; see nrd_pack.slang.
const float sky_depth = -5e5;

/// Puts a path traced picture together from the light that needs no
/// filtering and what NRD made of the bounced light and the reflections.
/// NRD leaves pixels that show no surface as they were, so those take
/// nothing from it.
void main() {
    uint nearest = push.frame.sampler_nearest_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    vec3 steady = texelFetch(TEX(push.steady_texture, nearest), pixel, 0).rgb;
    out_color = vec4(steady, 1.0);
    if (texelFetch(TEX(push.depth_texture, nearest), pixel, 0).r < sky_depth) return;
    vec3 albedo = texelFetch(TEX(push.albedo_texture, nearest), pixel, 0).rgb;
    vec3 tint = dot(albedo, vec3(1.0)) > 0.0 ? max(albedo, vec3(0.03)) : vec3(1.0);
    vec3 lamp = texelFetch(TEX(push.lamp_texture, nearest), pixel, 0).rgb;
    vec3 diffuse = texelFetch(TEX(push.diffuse_texture, nearest), pixel, 0).rgb;
    vec3 specular = texelFetch(TEX(push.specular_texture, nearest), pixel, 0).rgb;
    out_color = vec4(steady + (diffuse + lamp) * tint + specular, 1.0);
}
