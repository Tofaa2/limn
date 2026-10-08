#version 460
#include "common.glsl"
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

layout(location = 0) out vec3 out_position;
layout(location = 1) out vec2 out_uv;
layout(location = 2) flat out mat3 out_turn;
layout(location = 5) flat out uvec3 out_textures;

void main() {
    FrameConstants frame = push.frame;
    uint copy = push.list.data[gl_InstanceIndex];
    Impostor impostor = push.impostors.data[push.instances.data[copy].impostor - 1u];
    Instance instance = frame.instances.data[push.entity_instances + copy];
    float scale = length(instance.transform[0]);
    mat3 turn = mat3(instance.transform[0] / scale, instance.transform[1] / scale, instance.transform[2] / scale);
    vec3 middle = instance.transform * vec4(impostor.center, 1.0);
    vec3 seen_from = normalize(transpose(turn) * (frame.camera_position - middle));
    vec2 tile = min(floor(impostorFold(seen_from) * impostor_frames), vec2(impostor_frames - 1.0));
    vec3 toward = impostorUnfold((tile + 0.5) / impostor_frames);
    vec3 right;
    vec3 up;
    impostorBasis(toward, right, up);

    vec2 corner = vec2(gl_VertexIndex == 1 || gl_VertexIndex == 4 || gl_VertexIndex == 5 ? 1.0 : -1.0, gl_VertexIndex == 2 || gl_VertexIndex == 3 || gl_VertexIndex == 5 ? 1.0 : -1.0);
    vec3 position = middle + turn * (right * corner.x + up * corner.y) * impostor.radius * scale;
    out_position = position;
    out_uv = (tile + vec2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5)) / impostor_frames;
    out_turn = turn;
    out_textures = uvec3(impostor.color_texture, impostor.normal_texture, instance.tint);
    gl_Position = frame.view_proj * vec4(position, 1.0);
}
