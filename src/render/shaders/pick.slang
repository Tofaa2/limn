#include "common.slang"

struct PickResult {
    uint instance;
    uint triangle;
    float depth;
    uint pad;
    float3 position;
    uint pad1;
};

struct Push {
    FrameConstants frame;
    PickResult* result;
    uint visibility_texture;
    uint depth_texture;
    int2 pixel;
};

[[vk::push_constant]] Push push;

[shader("compute")]
[numthreads(1, 1, 1)]
void computeMain() {
    FrameConstants frame = push.frame;
    uint id = textures_2d_uint[NonUniformResourceIndex(push.visibility_texture)].Load(int3(push.pixel, 0)).r;
    float depth = fetchTexel(push.depth_texture, push.pixel).r;
    float2 uv = (float2(push.pixel) + 0.5) * frame.inv_resolution;
    push.result.instance = id == INVALID_ID ? INVALID_ID : frame.meshlet_refs.data[id >> 7].instance;
    push.result.triangle = id;
    push.result.depth = depth;
    push.result.position = worldPositionFromDepth(uv, max(depth, 1e-7), frame.inv_view_proj);
}
