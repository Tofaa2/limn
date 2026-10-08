#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint color_texture;
    uint guide_texture;
    int step_size;
    uint gathered;
    uint mode;
    uint steady_texture;
    uint facing_texture;
    uint gloss_texture;
    uint gloss_gathered_texture;
} push;

const vec2 gathered_takes_over = vec2(128.0, 1024.0);

const uint mode_first = 0u;
const uint mode_last = 1u;
const uint mode_none = 2u;

layout(location = 0) out vec4 out_color;

bool mirroredAt(FrameConstants frame, ivec2 pixel) {
    return texelFetch(TEX(push.facing_texture, frame.sampler_nearest_clamp), pixel, 0).a < 0.0;
}

vec3 positionAt(FrameConstants frame, ivec2 pixel, out float reach) {
    reach = abs(texelFetch(TEX(push.facing_texture, frame.sampler_nearest_clamp), pixel, 0).a);
    vec2 uv = (vec2(pixel) + 0.5) * frame.inv_resolution;
    vec3 toward = normalize(worldPositionFromDepth(uv, 0.5, frame.inv_view_proj) - frame.camera_position);
    return frame.camera_position + toward * reach;
}

vec3 facingAt(FrameConstants frame, ivec2 pixel) {
    vec3 facing = texelFetch(TEX(push.facing_texture, frame.sampler_nearest_clamp), pixel, 0).rgb;
    float size = length(facing);
    return size > 1e-4 ? facing / size : vec3(0.0, 1.0, 0.0);
}

float facingWeight(vec3 facing, vec3 other) {
    return pow(max(dot(facing, other), 0.0), 48.0);
}

vec3 divisor(vec3 guide) {
    return max(guide, vec3(0.03));
}

vec3 lightAt(FrameConstants frame, ivec2 pixel) {
    return texelFetch(TEX(push.color_texture, frame.sampler_nearest_clamp), pixel, 0).rgb;
}

float doubtAt(FrameConstants frame, ivec2 pixel, float frames) {
    vec4 texel = texelFetch(TEX(push.color_texture, frame.sampler_nearest_clamp), pixel, 0);
    if (push.mode != mode_first) return texel.a;
    float average = luminance(texel.rgb);
    float spread = max(texel.a - average * average, 0.0);
    return sqrt(spread / frames) / (average + 1e-3);
}

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    ivec2 last_pixel = ivec2(frame.resolution) - 1;
    vec4 guide_texel = texelFetch(TEX(push.guide_texture, nearest), pixel, 0);
    vec3 guide = guide_texel.rgb;
    vec4 steady_texel = texelFetch(TEX(push.steady_texture, nearest), pixel, 0);
    float frames = max(steady_texel.a, 1.0);
    vec3 grainy = texelFetch(TEX(push.color_texture, nearest), pixel, 0).rgb;
    vec3 gloss = vec3(0.0);
    if (push.mode == mode_last || push.mode == mode_none) {
        vec4 gathered = texelFetch(TEX(push.gloss_gathered_texture, nearest), pixel, 0);
        vec3 denoised = texelFetch(TEX(push.gloss_texture, nearest), pixel, 0).rgb;
        gloss = push.mode == mode_none ? gathered.rgb : mix(denoised, gathered.rgb, smoothstep(gathered_takes_over.x, gathered_takes_over.y, gathered.a));
    }
    bool colored = dot(guide, vec3(1.0)) > 0.0;
    if (push.mode == mode_none) {
        out_color = vec4(steady_texel.rgb + grainy * (colored ? divisor(guide) : vec3(1.0)) + gloss, 1.0);
        return;
    }
    float reach;
    vec3 position = positionAt(frame, pixel, reach);
    if (!colored || reach <= 0.0) {
        out_color = push.mode == mode_last ? vec4(steady_texel.rgb + grainy * (colored ? divisor(guide) : vec3(1.0)) + gloss, 1.0) : vec4(grainy, 0.0);
        return;
    }
    float reach_a;
    float reach_b;
    vec3 left = positionAt(frame, clamp(pixel - ivec2(1, 0), ivec2(0), last_pixel), reach_a);
    vec3 right = positionAt(frame, clamp(pixel + ivec2(1, 0), ivec2(0), last_pixel), reach_b);
    vec3 along_x = abs(reach_a - reach) < abs(reach_b - reach) ? position - left : right - position;
    vec3 up = positionAt(frame, clamp(pixel - ivec2(0, 1), ivec2(0), last_pixel), reach_a);
    vec3 down = positionAt(frame, clamp(pixel + ivec2(0, 1), ivec2(0), last_pixel), reach_b);
    vec3 along_y = abs(reach_a - reach) < abs(reach_b - reach) ? position - up : down - position;
    vec3 normal = normalize(cross(along_x, along_y));
    bool mirrored = mirroredAt(frame, pixel);
    vec3 facing = facingAt(frame, pixel);

    vec3 own = lightAt(frame, pixel);
    vec3 traced = own;
    vec3 around = vec3(0.0);
    float around_squared = 0.0;
    float around_count = 0.0;
    float brightest_around = 0.0;
    float doubt = doubtAt(frame, pixel, frames);
    float doubt_count = 1.0;
    for (int index = 0; index < 8; index++) {
        ivec2 offset = ivec2(index < 3 ? index - 1 : (index < 5 ? (index == 3 ? -1 : 1) : index - 6), index < 3 ? -1 : (index < 5 ? 0 : 1));
        ivec2 tap = clamp(pixel + offset * push.step_size, ivec2(0), last_pixel);
        vec4 tap_guide = texelFetch(TEX(push.guide_texture, nearest), tap, 0);
        if (dot(tap_guide.rgb, vec3(1.0)) <= 0.0 || mirroredAt(frame, tap) != mirrored) continue;
        if (facingWeight(facing, facingAt(frame, tap)) < 0.5) continue;
        vec3 tap_light = lightAt(frame, tap);
        float tap_brightness = luminance(tap_light);
        around += tap_light;
        around_squared += tap_brightness * tap_brightness;
        around_count += 1.0;
        brightest_around = max(brightest_around, tap_brightness);
        doubt += doubtAt(frame, tap, max(texelFetch(TEX(push.steady_texture, nearest), tap, 0).a, 1.0));
        doubt_count += 1.0;
    }
    doubt /= doubt_count;
    float own_brightness = luminance(own);
    float around_brightness = around_count > 0.0 ? luminance(around) / around_count : own_brightness;
    if (push.mode == mode_first) {
        float most = brightest_around * (1.0 + frames / 256.0);
        if (around_count > 0.0 && own_brightness > most) {
            own *= most / own_brightness;
            own_brightness = most;
        }
        float around_spread = around_count > 1.0 ? sqrt(max(around_squared / around_count - around_brightness * around_brightness, 0.0)) : 0.0;
        float by_neighbours = around_spread / (around_brightness + 1e-3);
        doubt = mix(by_neighbours, doubt, clamp((frames - 1.0) / 6.0, 0.0, 1.0));
        doubt = min(doubt, 4.0);
    }
    float reference = mix(own_brightness, around_brightness, clamp(doubt * 2.0, 0.0, 1.0));
    float remaining = doubt / sqrt(float(push.step_size));
    float allowed = 4.0 * remaining * (reference + 0.02) + 1e-4;

    vec3 total = vec3(0.0);
    float weight_total = 0.0;
    const float kernel[3] = float[](0.375, 0.25, 0.0625);
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            ivec2 tap = pixel + ivec2(x, y) * push.step_size;
            if (any(lessThan(tap, ivec2(0))) || any(greaterThan(tap, last_pixel))) continue;
            vec4 tap_guide = texelFetch(TEX(push.guide_texture, nearest), tap, 0);
            if (dot(tap_guide.rgb, vec3(1.0)) <= 0.0 || mirroredAt(frame, tap) != mirrored) continue;
            float tap_reach;
            vec3 tap_position = positionAt(frame, tap, tap_reach);
            if (tap_reach <= 0.0) continue;
            vec3 light = tap == pixel ? own : lightAt(frame, tap);
            float off_plane = abs(dot(normal, tap_position - position));
            float weight = kernel[abs(x)] * kernel[abs(y)];
            weight *= exp(-off_plane / (0.01 * reach + 1e-4));
            weight *= facingWeight(facing, facingAt(frame, tap));
            weight *= exp(-abs(luminance(light) - reference) / allowed);
            if (mirrored) weight *= exp(-abs(tap_reach - reach) / (0.05 * reach + 0.02));
            total += light * weight;
            weight_total += weight;
        }
    }
    vec3 smoothed = weight_total > 1e-6 ? total / weight_total : own;
    smoothed = mix(smoothed, traced, clamp(frames / 4096.0, 0.0, 1.0));
    if (any(isnan(smoothed)) || any(isinf(smoothed))) smoothed = any(isnan(traced)) || any(isinf(traced)) ? vec3(0.0) : traced;
    out_color = push.mode == mode_last ? vec4(steady_texel.rgb + smoothed * divisor(guide) + gloss, 1.0) : vec4(smoothed, doubt);
}
