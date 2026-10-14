#include "common.slang"

struct Push {
    FrameConstants frame;
    uint source_texture;
    uint automatic;
    float compensation;
    float min_luminance;
    float max_luminance;
    float speed;
    uint reset;
    uint depth_texture;
    float focus_speed;
};

[[vk::push_constant]] Push push;

[shader("compute")]
[numthreads(1, 1, 1)]
void computeMain() {
    FrameConstants frame = push.frame;
    ExposureData* state = frame.exposure.data;
    float seen = 0.0;
    for (int i = 0; i < 5; i++) {
        float2 offset = float2(i == 1 ? 0.03 : (i == 2 ? -0.03 : 0.0), i == 3 ? 0.03 : (i == 4 ? -0.03 : 0.0));
        seen += min(linearDepth(sampleTextureLod(push.depth_texture, frame.sampler_nearest_clamp, float2(0.5) + offset, 0.0).r, frame.depth_terms), 1000.0);
    }
    seen /= 5.0;
    float focus = state.focus;
    if (push.reset != 0u || !(focus > 0.0)) focus = seen;
    state.focus = focus + (seen - focus) * (1.0 - exp(-frame.delta_time * push.focus_speed));
    if (push.automatic == 0u) {
        state.exposure = push.compensation;
        return;
    }
    int2 size = int2(textureSize(push.source_texture));
    float total = 0.0;
    float weight_total = 0.0;
    for (int y = 0; y < size.y; y++) {
        for (int x = 0; x < size.x; x++) {
            float3 color = fetchTexel(push.source_texture, int2(x, y)).rgb;
            float2 centered = (float2(x, y) + 0.5) / float2(size) * 2.0 - 1.0;
            float weight = 1.0 - 0.6 * clamp(dot(centered, centered), 0.0, 1.0);
            total += log2(max(luminance(color), 1e-5)) * weight;
            weight_total += weight;
        }
    }
    float average = clamp(exp2(total / max(weight_total, 1e-5)), push.min_luminance, push.max_luminance);
    float previous = state.average_luminance;
    if (push.reset != 0u || !(previous > 0.0)) previous = average;
    float rate = average > previous ? push.speed * 1.6 : push.speed;
    const float dead_band = 0.04;
    float stops = log2(average) - log2(previous);
    stops = sign(stops) * max(abs(stops) - dead_band, 0.0);
    float adapted = exp2(log2(previous) + stops * (1.0 - exp(-frame.delta_time * rate)));
    state.average_luminance = adapted;
    state.exposure = push.compensation * 0.18 / adapted;
}
