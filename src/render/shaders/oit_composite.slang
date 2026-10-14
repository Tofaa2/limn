#include "common.slang"

struct Push {
    FrameConstants frame;
    uint accumulation_texture;
    uint reveal_texture;
};

[[vk::push_constant]] Push push;

[shader("fragment")]
float4 fragmentMain(float4 fragment : SV_Position) : SV_Target {
    int2 pixel = int2(fragment.xy);
    float reveal = fetchTexel(push.reveal_texture, pixel).r;
    if (reveal >= 1.0) discard;
    float4 accumulation = fetchTexel(push.accumulation_texture, pixel);
    return float4(accumulation.rgb / max(accumulation.a, 1e-5), 1.0 - reveal);
}
