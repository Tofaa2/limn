#include "common.slang"

struct Push {
    FrameConstants frame;
    uint history_texture;
    uint depth_texture;
    uint tile;
    float contrast;
};

[[vk::push_constant]] Push push;

static const uint rate_fine = 0u;
static const uint rate_coarse = 5u;

[shader("fragment")]
uint fragmentMain(float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = push.frame;
    float2 origin = floor(fragment.xy) * float(push.tile);
    float darkest = 1.0e30;
    float brightest = 0.0;
    float nearest = 0.0;
    float farthest = 1.0e30;
    const int taps = 4;
    for (int y = 0; y < taps; y++) {
        for (int x = 0; x < taps; x++) {
            float2 uv = (origin + (float2(x, y) + 0.5) * float(push.tile) / float(taps)) * frame.inv_resolution;
            uv = min(uv, float2(1.0) - 0.5 * frame.inv_resolution);
            float brightness = luminance(sampleTextureLod(push.history_texture, frame.sampler_linear_clamp, uv, 0.0).rgb);
            darkest = min(darkest, brightness);
            brightest = max(brightest, brightness);
            float depth = sampleTextureLod(push.depth_texture, frame.sampler_nearest_clamp, uv, 0.0).r;
            nearest = max(nearest, depth);
            farthest = min(farthest, depth);
        }
    }
    bool one_surface = nearest - farthest <= 0.02 * nearest;
    bool flat_color = brightest - darkest <= push.contrast * (brightest + 0.02);
    return one_surface && flat_color ? rate_coarse : rate_fine;
}
