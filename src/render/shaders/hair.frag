#version 460
#include "common.glsl"
#include "shading.glsl"
#include "hair.glsl"

layout(push_constant, scalar) uniform Push {
    HAIR_PUSH
} push;

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_tangent;
layout(location = 2) in vec2 in_along;
layout(location = 3) in vec4 in_clip;
layout(location = 4) in vec4 in_previous_clip;
layout(location = 5) flat in float in_shade;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec4 out_motion;

void main() {
    FrameConstants frame = push.frame;
    vec3 tangent = normalize(in_tangent);
    vec3 view = normalize(frame.camera_position - in_position);
    vec3 facing = view - tangent * dot(view, tangent);
    float facing_length = length(facing);
    vec3 normal = facing_length > 1e-4 ? facing / facing_length : view;
    vec3 color = mix(push.root_color, push.tip_color, in_along.x) * in_shade;

    Surface surface;
    surface.position = in_position;
    surface.normal = normal;
    surface.view = view;
    surface.diffuse_color = color;
    surface.f0 = vec3(0.046);
    surface.roughness = clamp(push.roughness, 0.045, 1.0);
    surface.ao = 1.0;
    surface.bounce = vec3(0.0);
    surface.view_depth = -(frame.view * vec4(in_position, 1.0)).z;
    surface.clearcoat = 0.0;
    surface.clearcoat_roughness = 0.0;
    surface.coat_normal = normal;
    surface.sheen_color = vec3(0.0);
    surface.sheen_roughness = 0.5;
    surface.subsurface = 0.0;
    surface.anisotropy = 0.9;
    surface.grain = tangent;

    float noise = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index);
    vec3 lit = shadeSurface(frame, surface, gl_FragCoord.xy, noise, vec4(0.0));
    float coverage = in_along.y;
    out_color = vec4(lit * coverage, coverage);
    out_motion = vec4((in_clip.xy / in_clip.w - in_previous_clip.xy / in_previous_clip.w) * 0.5, 0.0, coverage);
}
