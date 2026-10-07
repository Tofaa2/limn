#version 460
#include "common.glsl"

// Picks a shading rate per tile: 2x2 where last frame's tile was nearly one
// color on one smooth surface, else 1x1.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    // Last frame's final color and this frame's depth.
    uint history_texture;
    uint depth_texture;
    // Tile size in pixels.
    uint tile;
    // Relative luminance variation allowed for coarse shading.
    float contrast;
} push;

layout(location = 0) out uint out_rate;

// `rhi.shadingRate` values for 1x1 and 2x2.
const uint rate_fine = 0u;
const uint rate_coarse = 5u;

void main() {
    FrameConstants frame = push.frame;
    vec2 origin = floor(gl_FragCoord.xy) * float(push.tile);
    float darkest = 1.0e30;
    float brightest = 0.0;
    float nearest = 0.0;
    float farthest = 1.0e30;
    const int taps = 4;
    for (int y = 0; y < taps; y++) {
        for (int x = 0; x < taps; x++) {
            vec2 uv = (origin + (vec2(x, y) + 0.5) * float(push.tile) / float(taps)) * frame.inv_resolution;
            uv = min(uv, vec2(1.0) - 0.5 * frame.inv_resolution);
            float brightness = luminance(textureLod(TEX(push.history_texture, frame.sampler_linear_clamp), uv, 0.0).rgb);
            darkest = min(darkest, brightness);
            brightest = max(brightest, brightness);
            float depth = textureLod(TEX(push.depth_texture, frame.sampler_nearest_clamp), uv, 0.0).r;
            nearest = max(nearest, depth);
            farthest = min(farthest, depth);
        }
    }
    // Reverse-Z: relative depth spread equals relative distance spread.
    bool one_surface = nearest - farthest <= 0.02 * nearest;
    bool flat_color = brightest - darkest <= push.contrast * (brightest + 0.02);
    out_rate = one_surface && flat_color ? rate_coarse : rate_fine;
}
