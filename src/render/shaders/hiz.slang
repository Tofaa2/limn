#include "common.slang"

struct RasterPush {
    uint source_texture;
    uint sampler_index;
    uint first;
    int source_lod;
    float2 texel;
};

[[vk::push_constant]] RasterPush raster_push;

[shader("fragment")]
float rasterMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    if (raster_push.first != 0u) {
        float2 offset = raster_push.texel * 0.25;
        float a = sampleTextureLod(raster_push.source_texture, raster_push.sampler_index, in_uv + float2(-offset.x, -offset.y), 0.0).r;
        float b = sampleTextureLod(raster_push.source_texture, raster_push.sampler_index, in_uv + float2(offset.x, -offset.y), 0.0).r;
        float c = sampleTextureLod(raster_push.source_texture, raster_push.sampler_index, in_uv + float2(-offset.x, offset.y), 0.0).r;
        float d = sampleTextureLod(raster_push.source_texture, raster_push.sampler_index, in_uv + float2(offset.x, offset.y), 0.0).r;
        return min(min(a, b), min(c, d));
    }
    int2 base = int2(fragment.xy) * 2;
    int2 limit = textureSizeLod(raster_push.source_texture, raster_push.source_lod) - 1;
    float a = fetchTexelLod(raster_push.source_texture, min(base, limit), raster_push.source_lod).r;
    float b = fetchTexelLod(raster_push.source_texture, min(base + int2(1, 0), limit), raster_push.source_lod).r;
    float c = fetchTexelLod(raster_push.source_texture, min(base + int2(0, 1), limit), raster_push.source_lod).r;
    float d = fetchTexelLod(raster_push.source_texture, min(base + int2(1, 1), limit), raster_push.source_lod).r;
    return min(min(a, b), min(c, d));
}

#ifdef STORAGE_IMAGES
struct ComputePush {
    uint source_texture;
    uint sampler_index;
    uint first;
    int source_lod;
    uint target;
    uint pad;
    int2 size;
};

[[vk::push_constant]] ComputePush compute_push;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    int2 pixel = int2(id.xy);
    if (any(pixel >= compute_push.size)) return;
    float a;
    float b;
    float c;
    float d;
    if (compute_push.first != 0u) {
        float2 texel = 1.0 / float2(compute_push.size);
        float2 uv = (float2(pixel) + 0.5) * texel;
        float2 offset = texel * 0.25;
        a = sampleTextureLod(compute_push.source_texture, compute_push.sampler_index, uv + float2(-offset.x, -offset.y), 0.0).r;
        b = sampleTextureLod(compute_push.source_texture, compute_push.sampler_index, uv + float2(offset.x, -offset.y), 0.0).r;
        c = sampleTextureLod(compute_push.source_texture, compute_push.sampler_index, uv + float2(-offset.x, offset.y), 0.0).r;
        d = sampleTextureLod(compute_push.source_texture, compute_push.sampler_index, uv + float2(offset.x, offset.y), 0.0).r;
    } else {
        int2 base = pixel * 2;
        int2 limit = textureSizeLod(compute_push.source_texture, compute_push.source_lod) - 1;
        a = fetchTexelLod(compute_push.source_texture, min(base, limit), compute_push.source_lod).r;
        b = fetchTexelLod(compute_push.source_texture, min(base + int2(1, 0), limit), compute_push.source_lod).r;
        c = fetchTexelLod(compute_push.source_texture, min(base + int2(0, 1), limit), compute_push.source_lod).r;
        d = fetchTexelLod(compute_push.source_texture, min(base + int2(1, 1), limit), compute_push.source_lod).r;
    }
    storage_2d[compute_push.target][pixel] = float4(min(min(a, b), min(c, d)));
}
#endif
