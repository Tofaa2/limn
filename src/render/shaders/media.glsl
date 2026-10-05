// What participating media (fog, smoke) need to be lit by the sun and by lamps: the
// phase function, and whether the sun reaches a point past the scene's
// geometry and the clouds.
#ifndef MEDIA_GLSL
#define MEDIA_GLSL
#include "clouds.glsl"
#include "fluid.glsl"

float henyeyGreenstein(float cos_theta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5));
}

float cascadeVisibility(FrameConstants frame, vec3 position) {
    if ((frame.flags & FRAME_SHADOWS) == 0u) return 1.0;
    float view_depth = -(frame.view * vec4(position, 1.0)).z;
    uint cascade = 0u;
    for (uint i = 0u; i < 3u; i++) {
        if (view_depth > frame.cascade_splits[i]) cascade = i + 1u;
    }
    if (view_depth > frame.cascade_splits[3]) return 1.0;
    vec4 clip = frame.cascade_view_proj[cascade] * vec4(position, 1.0);
    if (clip.z >= 1.0) return 1.0;
    return texture(
        sampler2DArrayShadow(textures_2d_array[nonuniformEXT(frame.shadow_map)], samplers_shadow[nonuniformEXT(frame.shadow_sampler)]),
        vec4(clip.xy * 0.5 + 0.5, float(cascade), clip.z));
}

float sunVisibility(FrameConstants frame, vec3 position) {
    return cascadeVisibility(frame, position) * cloudShadow(frame, position) * fluidShadow(frame, position);
}

// Whether a local light reaches a point in the air past the scene's
// geometry: one tap of its shadow map (1 for lights without one).
float lampVisibility(FrameConstants frame, Light light, vec3 position, vec3 to_light) {
    uint first = light.flags >> 8;
    if (first == 0u) return 1.0;
    uint tile_index = first - 1u;
    if ((light.flags & LIGHT_SPOT) == 0u) {
        vec3 d = -to_light;
        vec3 a = abs(d);
        if (a.x >= a.y && a.x >= a.z) tile_index += d.x > 0.0 ? 0u : 1u;
        else if (a.y >= a.z) tile_index += d.y > 0.0 ? 2u : 3u;
        else tile_index += d.z > 0.0 ? 4u : 5u;
    }
    ShadowTile tile = frame.shadow_tiles.data[tile_index];
    vec4 clip = tile.view_proj * vec4(position, 1.0);
    if (clip.w <= 0.0) return 1.0;
    vec3 ndc = clip.xyz / clip.w;
    vec2 tile_uv = ndc.xy * 0.5 + 0.5;
    if (any(lessThan(tile_uv, vec2(0.0))) || any(greaterThan(tile_uv, vec2(1.0)))) return 1.0;
    return texture(
        sampler2DShadow(textures_2d[nonuniformEXT(frame.local_shadow_map)], samplers_shadow[nonuniformEXT(frame.local_shadow_sampler)]),
        vec3(tile_uv * tile.rect.xy + tile.rect.zw, ndc.z));
}

#endif
