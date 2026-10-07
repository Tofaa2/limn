#version 460
#include "common.glsl"
#include "shading.glsl"
#include "impostor.glsl"

struct StaticCull {
    vec4 sphere;
    uint first_ref;
    uint ref_count;
    uint impostor;
    uint pad;
};
layout(buffer_reference, scalar) readonly buffer StaticCulls { StaticCull data[]; };
layout(buffer_reference, scalar) readonly buffer ImpostorList { uint data[]; };

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    Impostors impostors;
    StaticCulls instances;
    ImpostorList list;
    uint entity_instances;
} push;

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec2 in_uv;
layout(location = 2) flat in mat3 in_turn;
layout(location = 5) flat in uvec3 in_textures;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec4 out_motion;

void main() {
    FrameConstants frame = push.frame;
    vec4 color = textureLod(TEX(in_textures.x, frame.sampler_linear_clamp), in_uv, 0.0);
    if (color.a < 0.5) discard;
    vec3 normal = normalize(in_turn * (textureLod(TEX(in_textures.y, frame.sampler_linear_clamp), in_uv, 0.0).xyz * 2.0 - 1.0));

    Surface surface;
    surface.position = in_position;
    surface.normal = normal;
    surface.view = normalize(frame.camera_position - in_position);
    surface.diffuse_color = color.rgb * unpackUnorm4x8(in_textures.z).rgb;
    surface.f0 = vec3(0.04);
    surface.roughness = 0.9;
    surface.ao = 1.0;
    surface.bounce = vec3(0.0);
    surface.view_depth = -(frame.view * vec4(in_position, 1.0)).z;
    surface.clearcoat = 0.0;
    surface.clearcoat_roughness = 0.0;
    surface.coat_normal = normal;
    surface.sheen_color = vec3(0.0);
    surface.sheen_roughness = 0.5;
    surface.subsurface = 0.0;
    surface.anisotropy = 0.0;
    surface.grain = vec3(1.0, 0.0, 0.0);
    float noise = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index);
    out_color = vec4(shadeSurface(frame, surface, gl_FragCoord.xy, noise, vec4(0.0)), 1.0);
    out_motion = vec4(0.0, 0.0, 0.0, 1.0);
}
