#include "common.slang"

struct Output {
    [[vk::location(0)]] float2 uv;
    float4 position : SV_Position;
};

[shader("vertex")]
Output fullscreenMain(uint vertex : SV_VulkanVertexID) {
    Output result;
    result.uv = float2((vertex << 1) & 2, vertex & 2);
    result.position = float4(result.uv * 2.0 - 1.0, 0.0, 1.0);
    return result;
}

#include "fullscreen.CopyPush.slang"

[[vk::push_constant]] CopyPush copy_push;

[shader("fragment")]
float4 copyMain(float4 fragment : SV_Position) : SV_Target {
    return fetchTexel(copy_push.source_texture, int2(fragment.xy));
}
