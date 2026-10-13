#ifndef CANVAS_SLANG
#define CANVAS_SLANG
#include "common.slang"

struct DrawVertex {
    float3 position;
    float2 offset;
    float2 uv;
    uint color;
    uint texture_mode;
};

/// A screen-space parallelogram of one color (`Quad` in draw_list.zig).
struct DrawQuad {
    float2 origin;
    float2 axis_x;
    float2 axis_y;
    float4 uv;
    float2 extra;
    uint color;
    uint texture_mode;
};

struct Push {
    DrawVertex* vertices;
    uint* indices;
    float4x4 transform;
    float3 camera_right;
    uint encode_srgb;
    float3 camera_up;
    float sdf_spread;
    float2 viewport;
    uint sampler_linear;
    uint sampler_nearest;
    uint depth_texture;
    float hdr_paper_white;
    float2 origin;
    uint sharp_text;
    float time;
    DrawQuad* quads;
    uint unfold;
};

[[vk::push_constant]] Push push;

struct Varyings {
    float4 position : SV_Position;
    [[vk::location(0)]] float2 uv;
    [[vk::location(1)]] float4 color;
    [[vk::location(2)]] nointerpolation uint texture_mode;
    [[vk::location(3)]] nointerpolation float2 extra;
};

static const uint MODE_LINE_3D = 5u;

float4 clipNear(float4 p, float4 q) {
    const float epsilon = 1e-4;
    if (p.w >= epsilon) return p;
    return lerp(p, q, (epsilon - p.w) / max(q.w - p.w, 1e-9));
}

float4 unpackColor(uint value) {
    return float4(float(value & 0xffu), float((value >> 8) & 0xffu), float((value >> 16) & 0xffu), float(value >> 24)) / 255.0;
}

[shader("vertex")]
Varyings vertexMain(uint vertex_index : SV_VulkanVertexID) {
    DrawVertex vertex;
    if (push.unfold != 0u) {
        static const float2 corners[6] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0) };
        DrawQuad quad = push.quads[vertex_index / 6u];
        float2 corner = corners[vertex_index % 6u];
        vertex.position = float3(quad.origin + quad.axis_x * corner.x + quad.axis_y * corner.y, 0.0);
        vertex.offset = quad.extra;
        vertex.uv = lerp(quad.uv.xy, quad.uv.zw, corner);
        vertex.color = quad.color;
        vertex.texture_mode = quad.texture_mode;
    } else {
        vertex = push.vertices[push.indices[vertex_index]];
    }
    uint mode = vertex.texture_mode >> 24;
    float4 color = unpackColor(vertex.color);
    Varyings result;
    result.color = float4(srgbToLinear(color.rgb), color.a);
    result.texture_mode = vertex.texture_mode;
    result.uv = vertex.uv;
    result.extra = vertex.offset;

    if (mode == MODE_LINE_3D) {
        float3 other = float3(vertex.offset, vertex.uv.x);
        float4 here = mul(push.transform, float4(vertex.position, 1.0));
        float4 there = mul(push.transform, float4(other, 1.0));
        if (here.w < 1e-4 && there.w < 1e-4) {
            result.position = float4(0.0, 0.0, 2.0, 1.0);
            return result;
        }
        float4 clipped_here = clipNear(here, there);
        float4 clipped_there = clipNear(there, here);
        float2 direction = (clipped_there.xy / clipped_there.w - clipped_here.xy / clipped_here.w) * push.viewport;
        float len = length(direction);
        direction = len > 1e-6 ? direction / len : float2(1.0, 0.0);
        float2 normal = float2(-direction.y, direction.x) * vertex.uv.y;
        clipped_here.xy += normal * 2.0 / push.viewport * clipped_here.w;
        result.position = clipped_here;
        result.uv = float2(0.0);
        return result;
    }

    float3 position = vertex.position + push.camera_right * vertex.offset.x + push.camera_up * vertex.offset.y;
    result.position = mul(push.transform, float4(position, 1.0));
    return result;
}

/// What the built-in shader draws at this pixel, in linear color, before it
/// is encoded for the target.
float4 canvasColor(Varyings input) {
    if (push.depth_texture != INVALID_ID) {
        float2 uv = (input.position.xy - push.origin) / push.viewport;
        float scene = textures_2d[NonUniformResourceIndex(push.depth_texture)].SampleLevel(samplers[NonUniformResourceIndex(push.sampler_nearest)], uv, 0.0).r;
        if (input.position.z < scene) discard;
    }
    uint mode = input.texture_mode >> 24;
    uint texture_index = input.texture_mode & 0x00ffffffu;
    float4 color = input.color;
    switch (mode) {
    case 1u:
        color *= textures_2d[NonUniformResourceIndex(texture_index)].Sample(samplers[NonUniformResourceIndex(push.sampler_linear)], input.uv);
        break;
    case 6u:
        color *= textures_2d[NonUniformResourceIndex(texture_index)].Sample(samplers[NonUniformResourceIndex(push.sampler_nearest)], input.uv);
        break;
    case 2u: {
        float4 field = textures_2d[NonUniformResourceIndex(texture_index)].Sample(samplers[NonUniformResourceIndex(push.sampler_linear)], input.uv);
        float distance = (push.sharp_text != 0u ? max(min(field.r, field.g), min(max(field.r, field.g), field.b)) : field.a) - 0.5;
        uint atlas_width;
        uint atlas_height;
        textures_2d[NonUniformResourceIndex(texture_index)].GetDimensions(atlas_width, atlas_height);
        float2 texels_per_pixel = fwidth(input.uv) * float2(atlas_width, atlas_height);
        float pixels_per_unit = 2.0 * push.sdf_spread / max(0.5 * (texels_per_pixel.x + texels_per_pixel.y), 1e-6);
        color.a *= clamp(distance * max(pixels_per_unit, 1.0) + 0.5, 0.0, 1.0);
        break;
    }
    case 3u: {
        float radius = length(input.uv);
        color.a *= clamp((1.0 - radius) / max(fwidth(radius), 1e-6) + 0.5, 0.0, 1.0);
        break;
    }
    case 4u: {
        float2 edge = (1.0 - abs(input.uv)) / max(fwidth(input.uv), float2(1e-6));
        color.a *= clamp(min(edge.x, edge.y), 0.0, 1.0);
        break;
    }
    case 7u: {
        float radius = float(texture_index & 0xfffu) * 0.25;
        float stroke = float((texture_index >> 12) & 0xfffu) * 0.25;
        float2 q = abs(input.uv) - input.extra + radius;
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        if (stroke > 0.0) distance = max(distance, -(distance + stroke));
        color.a *= clamp(0.5 - distance / max(fwidth(distance), 1e-6), 0.0, 1.0);
        break;
    }
    default:
        break;
    }
    return color;
}

/// A linear color as the target stores it. Every fragment shader for draw
/// lists returns its color through this.
float4 canvasEncode(float4 color) {
    if (color.a <= 0.0) discard;
    if (push.encode_srgb == 1u) color.rgb = linearToSrgb(color.rgb);
    if (push.encode_srgb == 2u) color.rgb = hdr10Encode(color.rgb * push.hdr_paper_white);
    return color;
}

#endif
