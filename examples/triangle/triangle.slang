struct Push {
    float time;
    float aspect;
};

[[vk::push_constant]] Push push;

static const float2 positions[3] = { float2(0.0, -0.6), float2(0.52, 0.3), float2(-0.52, 0.3) };
static const float3 colors[3] = { float3(1.0, 0.25, 0.2), float3(0.2, 1.0, 0.35), float3(0.25, 0.4, 1.0) };

struct Varyings {
    [[vk::location(0)]] float3 color;
    float4 position : SV_Position;
};

[shader("vertex")]
Varyings vertexMain(uint vertex : SV_VulkanVertexID) {
    float c = cos(push.time);
    float s = sin(push.time);
    float2 p = positions[vertex];
    p = float2(p.x * c - p.y * s, p.x * s + p.y * c);
    Varyings result;
    result.position = float4(p.x / push.aspect, p.y, 0.0, 1.0);
    result.color = colors[vertex];
    return result;
}

[shader("fragment")]
float4 fragmentMain([[vk::location(0)]] float3 color) : SV_Target {
    return float4(color, 1.0);
}
