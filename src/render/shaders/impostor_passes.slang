#include "impostor.slang"
#include "common.slang"
#include "shading.slang"

#include "impostor_passes.DrawPush.slang"

[[vk::push_constant]] DrawPush draw_push;

/// The turn is passed as its three columns.
struct DrawVaryings {
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float2 uv;
    [[vk::location(2)]] nointerpolation float3 turn_x;
    [[vk::location(3)]] nointerpolation float3 turn_y;
    [[vk::location(4)]] nointerpolation float3 turn_z;
    [[vk::location(5)]] nointerpolation uint3 textures;
    float4 screen : SV_Position;
};

[shader("vertex")]
DrawVaryings drawMain(uint vertex : SV_VulkanVertexID, uint copy_index : SV_VulkanInstanceID) {
    FrameConstants frame = draw_push.frame;
    uint copy = draw_push.list[copy_index];
    Impostor impostor = draw_push.impostors[draw_push.instances[copy].impostor - 1u];
    Instance instance = frame.instances.data[draw_push.entity_instances + copy];
    float scale = length(matrixColumn(instance.transform, 0));
    float3 turn_x = matrixColumn(instance.transform, 0) / scale;
    float3 turn_y = matrixColumn(instance.transform, 1) / scale;
    float3 turn_z = matrixColumn(instance.transform, 2) / scale;
    float3 middle = mul(instance.transform, float4(impostor.center, 1.0));
    float3 away = eyePoint(frame, middle) - middle;
    float3 seen_from = normalize(float3(dot(turn_x, away), dot(turn_y, away), dot(turn_z, away)));
    float2 tile = min(floor(impostorFold(seen_from) * impostor_frames), float2(impostor_frames - 1.0));
    float3 toward = impostorUnfold((tile + 0.5) / impostor_frames);
    float3 right;
    float3 up;
    impostorBasis(toward, right, up);

    float2 corner = float2(vertex == 1u || vertex == 4u || vertex == 5u ? 1.0 : -1.0, vertex == 2u || vertex == 3u || vertex == 5u ? 1.0 : -1.0);
    float3 local = right * corner.x + up * corner.y;
    float3 position = middle + (turn_x * local.x + turn_y * local.y + turn_z * local.z) * impostor.radius * scale;
    DrawVaryings result;
    result.position = position;
    result.uv = (tile + float2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5)) / impostor_frames;
    result.turn_x = turn_x;
    result.turn_y = turn_y;
    result.turn_z = turn_z;
    result.textures = uint3(impostor.color_texture, impostor.normal_texture, instance.tint);
    result.screen = mul(frame.view_proj, float4(position, 1.0));
    return result;
}

#include "impostor_passes.ShadePush.slang"

[[vk::push_constant]] ShadePush shade_push;

struct Output {
    float4 color : SV_Target0;
    float4 motion : SV_Target1;
};

[shader("fragment")]
Output shadeMain(
    [[vk::location(0)]] float3 in_position,
    [[vk::location(1)]] float2 in_uv,
    [[vk::location(2)]] nointerpolation float3 in_turn_x,
    [[vk::location(3)]] nointerpolation float3 in_turn_y,
    [[vk::location(4)]] nointerpolation float3 in_turn_z,
    [[vk::location(5)]] nointerpolation uint3 in_textures,
    float4 fragment : SV_Position) {
    Output result;
    FrameConstants frame = shade_push.frame;
    float4 color = sampleTextureLod(in_textures.x, frame.sampler_linear_clamp, in_uv, 0.0);
    if (color.a < 0.5) discard;
    float3 normal = normalize(mul(sampleTextureLod(in_textures.y, frame.sampler_linear_clamp, in_uv, 0.0).xyz * 2.0 - 1.0, float3x3(in_turn_x, in_turn_y, in_turn_z)));

    Surface surface;
    surface.position = in_position;
    surface.normal = normal;
    surface.view = normalize(eyePoint(frame, in_position) - in_position);
    surface.diffuse_color = color.rgb * unpackUnorm(in_textures.z).rgb;
    surface.f0 = float3(0.04);
    surface.roughness = 0.9;
    surface.ao = 1.0;
    surface.bounce = float3(0.0);
    surface.view_depth = -(mul(frame.view, float4(in_position, 1.0))).z;
    surface.clearcoat = 0.0;
    surface.clearcoat_roughness = 0.0;
    surface.coat_normal = normal;
    surface.sheen_color = float3(0.0);
    surface.sheen_roughness = 0.5;
    surface.subsurface = 0.0;
    surface.anisotropy = 0.0;
    surface.grain = float3(1.0, 0.0, 0.0);
    float noise = interleavedGradientNoise(fragment.xy, frame.frame_index);
    result.color = float4(shadeSurface(frame, surface, fragment.xy, noise, float4(0.0)), 1.0);
    result.motion = float4(0.0, 0.0, 0.0, 1.0);
    return result;
}

#include "impostor_passes.BakePush.slang"

[[vk::push_constant]] BakePush bake_push;

struct BakeVaryings {
    [[vk::location(0)]] float3 normal;
    [[vk::location(1)]] float2 uv;
    [[vk::location(2)]] float4 vertex_color;
    float4 position : SV_Position;
};

[shader("vertex")]
BakeVaryings bakeVertexMain(uint vertex_index : SV_VulkanVertexID) {
    Vertex vertex = bake_push.frame.vertices.data[bake_push.vertex_offset + vertex_index];
    float3 position = mul(bake_push.node, float4(vertex.position, 1.0)).xyz;
    float3 from_middle = (position - bake_push.center) / bake_push.radius;
    BakeVaryings result;
    result.normal = mul(normalMatrix((float3x4)bake_push.node), vertexNormal(vertex));
    result.uv = vertex.uv;
    result.vertex_color = unpackUnorm(vertex.color);
    result.position = float4(dot(from_middle, bake_push.right), -dot(from_middle, bake_push.up), 0.5 + 0.5 * dot(from_middle, bake_push.toward), 1.0);
    return result;
}

struct Baked {
    float4 color : SV_Target0;
    float4 normal : SV_Target1;
};

[shader("fragment")]
Baked bakeFragmentMain(BakeVaryings input, bool front : SV_IsFrontFace) {
    Material material = bake_push.frame.materials.data[bake_push.material];
    float4 color = material.base_color * input.vertex_color;
    if (material.base_color_texture != INVALID_ID)
        color *= sampleTexture(material.base_color_texture, material.sampler_index, materialUv(material, input.uv));
    if ((material.flags & MATERIAL_ALPHA_TEST) != 0u && color.a < material.alpha_cutoff) discard;
    float3 normal = normalize(input.normal);
    if (!front) normal = -normal;
    Baked result;
    result.color = float4(color.rgb, 1.0);
    result.normal = float4(normal * 0.5 + 0.5, 1.0);
    return result;
}
