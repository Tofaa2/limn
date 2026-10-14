#include "ray_light.slang"
#include "common.slang"

struct BakePush {
    FrameConstants frame;
    uint64_t tlas;
    float4x4 transform;
    uint vertex_offset;
    uint gathered_texture;
    uint rounds;
    uint rays;
    float reach;
};

[[vk::push_constant]] BakePush bake_push;

struct Varyings {
    float4 clip : SV_Position;
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float3 normal;
};

uint hash(uint value) {
    value = value * 747796405u + 2891336453u;
    uint word = ((value >> ((value >> 28u) + 4u)) ^ value) * 277803737u;
    return (word >> 22u) ^ word;
}

[shader("vertex")]
Varyings bakeVertexMain(uint vertex_index : SV_VulkanVertexID) {
    Vertex vertex = bake_push.frame.vertices.data[bake_push.vertex_offset + vertex_index];
    Varyings result;
    result.position = mul(bake_push.transform, float4(vertex.position, 1.0)).xyz;
    result.normal = mul(normalMatrix((float3x4)bake_push.transform), vertexNormal(vertex));
    result.clip = float4(vertex.uv1 * 2.0 - 1.0, 0.5, 1.0);
    return result;
}

[shader("fragment")]
float4 bakeFragmentMain(Varyings input) : SV_Target {
    FrameConstants frame = bake_push.frame;
    float3 normal = normalize(input.normal);
    uint state = hash(uint(input.clip.x) + hash(uint(input.clip.y) + hash(bake_push.rounds)));
    float3 hint = abs(normal.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 side = normalize(cross(hint, normal));
    float3 other = cross(normal, side);
    Tracer tracer;
    tracer.frame = frame;
    tracer.scene = bake_push.tlas;
    float3 total = float3(0.0);
    uint rays = max(bake_push.rays, 1u);
    for (uint ray = 0u; ray < rays; ray++) {
        state = hash(state);
        float turn = 2.0 * PI * float(state) / 4294967296.0;
        state = hash(state);
        float out_from = sqrt(float(state) / 4294967296.0);
        float3 direction = normalize(side * cos(turn) * out_from + other * sin(turn) * out_from + normal * sqrt(max(1.0 - out_from * out_from, 0.0)));
        LitRay seen = traceLit(tracer, input.position + normal * 0.01, direction, bake_push.reach, 2.0, true, RAY_SOLID);
        float3 radiance = seen.radiance;
        if (seen.met == RAY_MISS) {
            radiance = float3(0.0);
            if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
                radiance = sampleCubeLod(frame.env_specular, frame.sampler_linear_clamp, direction, 2.0).rgb * frame.env_intensity;
        }
        total += min(radiance, float3(64.0));
    }
    float3 gathered = total / float(rays);
    float4 before = fetchTexel(bake_push.gathered_texture, int2(input.clip.xy));
    float weight = before.a > 0.0 ? 1.0 / float(bake_push.rounds + 1u) : 1.0;
    return float4(lerp(before.rgb, gathered, weight), 1.0);
}

struct DilatePush {
    FrameConstants frame;
    uint source_texture;
};

[[vk::push_constant]] DilatePush dilate_push;

[shader("fragment")]
float4 dilateMain(float4 fragment : SV_Position) : SV_Target {
    int2 texel = int2(fragment.xy);
    int2 last = int2(textureSize(dilate_push.source_texture)) - 1;
    float4 own = fetchTexel(dilate_push.source_texture, texel);
    if (own.a > 0.0) return float4(own.rgb, 1.0);
    float3 total = float3(0.0);
    float weight_total = 0.0;
    for (int y = -3; y <= 3; y++) {
        for (int x = -3; x <= 3; x++) {
            float4 tap = fetchTexel(dilate_push.source_texture, clamp(texel + int2(x, y), int2(0), last));
            if (tap.a <= 0.0) continue;
            float weight = 1.0 / float(x * x + y * y);
            total += tap.rgb * weight;
            weight_total += weight;
        }
    }
    return weight_total > 0.0 ? float4(total / weight_total, 1.0) : float4(0.0);
}
