#include "common.slang"

#include "exposure.Push.slang"

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
    const int bins = 64;
    const float lowest = -16.0;
    const float stops_per_bin = 24.0 / float(bins);
    float weights[bins];
    float logs[bins];
    for (int b = 0; b < bins; b++) {
        weights[b] = 0.0;
        logs[b] = 0.0;
    }
    int2 size = int2(textureSize(push.source_texture));
    float weight_total = 0.0;
    for (int y = 0; y < size.y; y++) {
        for (int x = 0; x < size.x; x++) {
            float3 color = fetchTexel(push.source_texture, int2(x, y)).rgb;
            float2 centered = (float2(x, y) + 0.5) / float2(size) * 2.0 - 1.0;
            float weight = 1.0 - 0.6 * clamp(dot(centered, centered), 0.0, 1.0);
            float level = log2(max(luminance(color), 1e-5));
            int bin = clamp(int((level - lowest) / stops_per_bin), 0, bins - 1);
            weights[bin] += weight;
            logs[bin] += level * weight;
            weight_total += weight;
        }
    }
    float skip = weight_total * clamp(push.ignore_dark, 0.0, 0.99);
    float keep = weight_total * max(1.0 - clamp(push.ignore_bright, 0.0, 0.99) - clamp(push.ignore_dark, 0.0, 0.99), 0.01);
    float total = 0.0;
    float kept = 0.0;
    for (int b = 0; b < bins && kept < keep; b++) {
        float weight = weights[b];
        if (weight <= 0.0) continue;
        float skipped = min(skip, weight);
        skip -= skipped;
        float taken = min(weight - skipped, keep - kept);
        total += logs[b] / weight * taken;
        kept += taken;
    }
    float average = clamp(exp2(total / max(kept, 1e-5)), push.min_luminance, push.max_luminance);
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
