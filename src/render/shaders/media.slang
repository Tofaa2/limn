#ifndef MEDIA_SLANG
#define MEDIA_SLANG
#include "clouds.slang"

float henyeyGreenstein(float cos_theta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5));
}

float cascadeVisibility(FrameConstants frame, float3 position) {
    if ((frame.flags & FRAME_SHADOWS) == 0u) return 1.0;
    float view_depth = -mul(frame.view, float4(position, 1.0)).z;
    uint cascade = 0u;
    for (uint i = 0u; i < 3u; i++) {
        if (view_depth > frame.cascade_splits[i]) cascade = i + 1u;
    }
    if (view_depth > frame.cascade_splits[3]) return 1.0;
    float4 clip = mul(frame.cascade_view_proj[cascade], float4(position, 1.0));
    if (clip.z >= 1.0) return 1.0;
    return textures_2d_array[NonUniformResourceIndex(frame.shadow_map)].SampleCmpLevelZero(
        samplers_shadow[NonUniformResourceIndex(frame.shadow_sampler)], float3(clip.xy * 0.5 + 0.5, float(cascade)), clip.z);
}

float sunVisibility(FrameConstants frame, float3 position) {
    return cascadeVisibility(frame, position) * cloudShadow(frame, position) * fluidShadow(frame, position);
}

float lampVisibility(FrameConstants frame, Light light, float3 position, float3 to_light) {
    uint first = light.flags >> 8;
    if (first == 0u) return 1.0;
    uint tile_index = first - 1u;
    if ((light.flags & LIGHT_SPOT) == 0u) {
        float3 d = -to_light;
        float3 a = abs(d);
        if (a.x >= a.y && a.x >= a.z) tile_index += d.x > 0.0 ? 0u : 1u;
        else if (a.y >= a.z) tile_index += d.y > 0.0 ? 2u : 3u;
        else tile_index += d.z > 0.0 ? 4u : 5u;
    }
    ShadowTile tile = frame.shadow_tiles.data[tile_index];
    float4 clip = mul(tile.view_proj, float4(position, 1.0));
    if (clip.w <= 0.0) return 1.0;
    float3 ndc = clip.xyz / clip.w;
    float2 tile_uv = ndc.xy * 0.5 + 0.5;
    if (any(tile_uv < 0.0) || any(tile_uv > 1.0)) return 1.0;
    return textures_2d[NonUniformResourceIndex(frame.local_shadow_map)].SampleCmpLevelZero(
        samplers_shadow[NonUniformResourceIndex(frame.local_shadow_sampler)], tile_uv * tile.rect.xy + tile.rect.zw, ndc.z);
}

#endif
