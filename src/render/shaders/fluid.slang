#ifndef FLUID_SLANG
#define FLUID_SLANG
#include "common.slang"

float2 volumeTileUv(float2 texel, int slice, int3 size, int tiles_x) {
    texel = clamp(texel, float2(0.5), float2(size.xy) - 0.5);
    float2 tile = float2(slice % tiles_x, slice / tiles_x);
    int tiles_y = (size.z + tiles_x - 1) / tiles_x;
    return (tile * float2(size.xy) + texel) / (float2(tiles_x, tiles_y) * float2(size.xy));
}

float4 sampleVolume(uint texture_index, uint sampler_index, float3 uvw, int3 size, int tiles_x) {
    float2 texel = uvw.xy * float2(size.xy);
    float z = clamp(uvw.z * float(size.z) - 0.5, 0.0, float(size.z - 1));
    int below = int(floor(z));
    int above = min(below + 1, size.z - 1);
    float4 a = sampleTextureLod(texture_index, sampler_index, volumeTileUv(texel, below, size, tiles_x), 0.0);
    if (above == below) return a;
    float4 b = sampleTextureLod(texture_index, sampler_index, volumeTileUv(texel, above, size, tiles_x), 0.0);
    return lerp(a, b, z - float(below));
}

float4 sampleVolumeRepeat(uint texture_index, uint sampler_index, float3 uvw, int3 size, int tiles_x) {
    uvw = frac(uvw);
    float2 texel = uvw.xy * float2(size.xy);
    float z = uvw.z * float(size.z) - 0.5;
    float below = floor(z);
    int slice_a = (int(below) + size.z) % size.z;
    int slice_b = (slice_a + 1) % size.z;
    float4 a = sampleTextureLod(texture_index, sampler_index, volumeTileUv(texel, slice_a, size, tiles_x), 0.0);
    float4 b = sampleTextureLod(texture_index, sampler_index, volumeTileUv(texel, slice_b, size, tiles_x), 0.0);
    return lerp(a, b, z - below);
}

int3 volumeCell(int2 pixel, int3 size, int tiles_x) {
    int2 tile = pixel / size.xy;
    return int3(pixel - tile * size.xy, tile.y * tiles_x + tile.x);
}

int3 fluidCell(FluidRef fluid, int2 pixel) {
    return volumeCell(pixel, fluid.data.size, fluid.data.tiles_x);
}

float3 fireGlow(float temperature) {
    float t = max(temperature, 0.0);
    float3 color = float3(smoothstep(0.02, 0.45, t), smoothstep(0.25, 1.1, t) * 0.75, smoothstep(0.7, 1.9, t) * 0.55);
    return color * (0.25 + t) * (0.25 + t);
}

/// How much light reaches `position` from `direction` through the smoke of the
/// frame's fluids.
float fluidShadowToward(FrameConstants frame, float3 position, float3 direction, float reach) {
    if ((SHADE_FEATURES & FEATURE_FLUID_SHADOWS) == 0u || (frame.flags & FRAME_FLUID_SHADOWS) == 0u) return 1.0;
    float through = 1.0;
    uint count = frame.fluids.count;
    for (uint i = 0u; i < count; i++) {
        FluidRef fluid = frame.fluids.fluids[i];
        float4x4 world_to_box = fluid.data.world_to_box;
        float3 origin = mul(world_to_box, float4(position, 1.0)).xyz;
        float3 along = mul(world_to_box, float4(direction, 0.0)).xyz;
        float3 inverse = 1.0 / select(abs(along) < 1e-8, float3(1e-8), along);
        float3 a = (float3(0.0) - origin) * inverse;
        float3 b = (float3(1.0) - origin) * inverse;
        float3 low = min(a, b);
        float3 high = max(a, b);
        float t0 = max(max(low.x, max(low.y, low.z)), 0.0);
        float t1 = min(min(high.x, min(high.y, high.z)), reach);
        if (t1 <= t0) continue;
        const int steps = 8;
        float step_length = (t1 - t0) / float(steps);
        float smoke = 0.0;
        for (int s = 0; s < steps; s++) {
            float3 uvw = origin + along * (t0 + (float(s) + 0.5) * step_length);
            smoke += sampleVolume(fluid.data.scalars_texture, fluid.data.sampler_linear, uvw, fluid.data.size, fluid.data.tiles_x).x;
        }
        through *= exp(-smoke * step_length * fluid.data.absorption * fluid.data.shadow);
    }
    return through;
}

float fluidShadow(FrameConstants frame, float3 position) {
    return fluidShadowToward(frame, position, frame.sun_direction, 1e30);
}

/// How much light passes the frame's fluids along a ray, and in `added` what
/// their smoke and fire add to it.
float fluidAlong(FrameConstants frame, float3 position, float3 direction, float reach, float3 ambient, out float3 added) {
    added = float3(0.0);
    float through = 1.0;
    uint count = frame.fluids.count;
    for (uint i = 0u; i < count; i++) {
        FluidRef fluid = frame.fluids.fluids[i];
        float4x4 world_to_box = fluid.data.world_to_box;
        float3 origin = mul(world_to_box, float4(position, 1.0)).xyz;
        float3 along = mul(world_to_box, float4(direction, 0.0)).xyz;
        float3 inverse = 1.0 / select(abs(along) < 1e-8, float3(1e-8), along);
        float3 a = (float3(0.0) - origin) * inverse;
        float3 b = (float3(1.0) - origin) * inverse;
        float3 low = min(a, b);
        float3 high = max(a, b);
        float t0 = max(max(low.x, max(low.y, low.z)), 0.0);
        float t1 = min(min(high.x, min(high.y, high.z)), reach);
        if (t1 <= t0) continue;
        const int steps = 10;
        float step_length = (t1 - t0) / float(steps);
        for (int s = 0; s < steps; s++) {
            float3 uvw = origin + along * (t0 + (float(s) + 0.5) * step_length);
            float4 value = sampleVolume(fluid.data.scalars_texture, fluid.data.sampler_linear, uvw, fluid.data.size, fluid.data.tiles_x);
            float step_through = exp(-value.x * fluid.data.absorption * step_length);
            added += through * (fluid.data.smoke_color * ambient * (1.0 - step_through) + fluid.data.fire_color * fluid.data.fire_intensity * fireGlow(value.y) * step_length);
            through *= step_through;
        }
    }
    return through;
}

#endif
