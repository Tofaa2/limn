#include "common.slang"

#include "edge_antialiasing.Push.slang"

[[vk::push_constant]] Push push;

/// Contrast, as a share of the brightest neighbour and in absolute terms,
/// under which a pixel is left as it is.
static const float least_contrast = 0.125;
static const float least_range = 0.0312;
/// How far a pixel that stands out from all its neighbours is blended into them.
static const float speck_blend = 0.75;
/// Texels stepped at a time while following an edge to its ends.
static const float strides[8] = { 1.0, 1.5, 2.0, 2.0, 2.0, 2.0, 4.0, 8.0 };

float brightness(float3 color) {
    return sqrt(dot(max(color, float3(0.0)), float3(0.299, 0.587, 0.114)));
}

float brightnessAt(float2 uv) {
    return brightness(sampleTextureLod(push.source_texture, push.frame.sampler_linear_clamp, uv, 0.0).rgb);
}

/// Smooths the stair steps of edges in a finished picture (FXAA): finds the
/// edge a pixel sits on, follows it to both ends and shifts the pixel's
/// sample across the edge by how far along the step it is.
[shader("fragment")]
float4 fragmentMain(float4 fragment : SV_Position) : SV_Target {
    uint linear = push.frame.sampler_linear_clamp;
    float2 texel = 1.0 / textureSize(push.source_texture);
    float2 uv = fragment.xy * texel;
    float4 here = sampleTextureLod(push.source_texture, linear, uv, 0.0);
    float middle = brightness(here.rgb);
    float north = brightnessAt(uv + float2(0.0, -texel.y));
    float south = brightnessAt(uv + float2(0.0, texel.y));
    float west = brightnessAt(uv + float2(-texel.x, 0.0));
    float east = brightnessAt(uv + float2(texel.x, 0.0));
    float brightest = max(middle, max(max(north, south), max(west, east)));
    float darkest = min(middle, min(min(north, south), min(west, east)));
    float range = brightest - darkest;
    if (range < max(least_range, brightest * least_contrast)) return here;

    float north_west = brightnessAt(uv + float2(-texel.x, -texel.y));
    float north_east = brightnessAt(uv + float2(texel.x, -texel.y));
    float south_west = brightnessAt(uv + float2(-texel.x, texel.y));
    float south_east = brightnessAt(uv + float2(texel.x, texel.y));
    float across_rows = abs(north_west + south_west - 2.0 * west) + 2.0 * abs(north + south - 2.0 * middle) + abs(north_east + south_east - 2.0 * east);
    float across_columns = abs(north_west + north_east - 2.0 * north) + 2.0 * abs(west + east - 2.0 * middle) + abs(south_west + south_east - 2.0 * south);
    bool level = across_rows >= across_columns;

    float before = level ? north : west;
    float after = level ? south : east;
    bool toward_before = abs(before - middle) >= abs(after - middle);
    float steepness = 0.25 * max(abs(before - middle), abs(after - middle));
    float across = level ? texel.y : texel.x;
    if (toward_before) across = -across;
    float edge_brightness = 0.5 * ((toward_before ? before : after) + middle);

    float2 on_edge = uv;
    if (level) on_edge.y += across * 0.5; else on_edge.x += across * 0.5;
    float2 along = level ? float2(texel.x, 0.0) : float2(0.0, texel.y);
    float2 back = on_edge - along;
    float2 ahead = on_edge + along;
    float back_change = brightnessAt(back) - edge_brightness;
    float ahead_change = brightnessAt(ahead) - edge_brightness;
    bool back_found = abs(back_change) >= steepness;
    bool ahead_found = abs(ahead_change) >= steepness;
    for (int i = 1; i < 8 && !(back_found && ahead_found); i++) {
        if (!back_found) {
            back -= along * strides[i];
            back_change = brightnessAt(back) - edge_brightness;
            back_found = abs(back_change) >= steepness;
        }
        if (!ahead_found) {
            ahead += along * strides[i];
            ahead_change = brightnessAt(ahead) - edge_brightness;
            ahead_found = abs(ahead_change) >= steepness;
        }
    }
    float to_back = level ? uv.x - back.x : uv.y - back.y;
    float to_ahead = level ? ahead.x - uv.x : ahead.y - uv.y;
    float nearer_change = to_back < to_ahead ? back_change : ahead_change;
    float shift = 0.0;
    if ((nearer_change < 0.0) != (middle < edge_brightness)) shift = 0.5 - min(to_back, to_ahead) / (to_back + to_ahead);

    float around = (2.0 * (north + south + west + east) + north_west + north_east + south_west + south_east) / 12.0;
    float standing_out = clamp(abs(around - middle) / range, 0.0, 1.0);
    float speck = (3.0 - 2.0 * standing_out) * standing_out * standing_out;
    shift = max(shift, speck * speck * speck_blend);

    float2 sample_uv = uv;
    if (level) sample_uv.y += shift * across; else sample_uv.x += shift * across;
    return float4(sampleTextureLod(push.source_texture, linear, sample_uv, 0.0).rgb, here.a);
}
