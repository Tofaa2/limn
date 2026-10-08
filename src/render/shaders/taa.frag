#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint color_texture;
    uint history_texture;
    uint motion_texture;
    uint depth_texture;
    uint history_valid;
    float settled;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

vec3 toYCoCg(vec3 c) {
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 fromYCoCg(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

vec3 compress(vec3 c) {
    return c / (1.0 + luminance(c));
}

vec3 expand(vec3 c) {
    return c / max(1.0 - luminance(c), 1e-4);
}

vec3 sampleHistory(FrameConstants frame, vec2 uv) {
    vec2 history_size = vec2(textureSize(TEX(push.history_texture, frame.sampler_linear_clamp), 0));
    vec2 position = uv * history_size;
    vec2 center = floor(position - 0.5) + 0.5;
    vec2 f = position - center;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 tc0 = (center - 1.0) / history_size;
    vec2 tc12 = (center + w2 / w12) / history_size;
    vec2 tc3 = (center + 2.0) / history_size;
    uint s = frame.sampler_linear_clamp;
    vec4 result =
        vec4(textureLod(TEX(push.history_texture, s), vec2(tc12.x, tc0.y), 0.0).rgb, 1.0) * (w12.x * w0.y) +
        vec4(textureLod(TEX(push.history_texture, s), vec2(tc0.x, tc12.y), 0.0).rgb, 1.0) * (w0.x * w12.y) +
        vec4(textureLod(TEX(push.history_texture, s), vec2(tc12.x, tc12.y), 0.0).rgb, 1.0) * (w12.x * w12.y) +
        vec4(textureLod(TEX(push.history_texture, s), vec2(tc3.x, tc12.y), 0.0).rgb, 1.0) * (w3.x * w12.y) +
        vec4(textureLod(TEX(push.history_texture, s), vec2(tc12.x, tc3.y), 0.0).rgb, 1.0) * (w12.x * w3.y);
    return max(result.rgb / result.a, vec3(0.0));
}

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 pixel = min(ivec2(in_uv * frame.resolution), ivec2(frame.resolution) - 1);
    ivec2 limit = ivec2(frame.resolution) - 1;

    float carried = texelFetch(TEX(push.color_texture, nearest), pixel, 0).a;
    if (push.history_valid == 0u) {
        out_color = texelFetch(TEX(push.color_texture, nearest), pixel, 0);
        return;
    }

    vec2 jitter_pixels = frame.jitter * frame.resolution;
    vec3 filtered = vec3(0.0);
    float filtered_weight = 0.0;
    float span = frame.resolution.x / float(textureSize(TEX(push.history_texture, frame.sampler_linear_clamp), 0).x);
    bool upscaling = span < 0.999;
    vec3 narrow = vec3(0.0);
    float narrow_weight = 0.0;
    vec3 mean = vec3(0.0);
    vec3 mean_squared = vec3(0.0);
    float closest_depth = 0.0;
    ivec2 closest_pixel = pixel;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            ivec2 tap = clamp(pixel + ivec2(x, y), ivec2(0), limit);
            vec3 c = toYCoCg(compress(texelFetch(TEX(push.color_texture, nearest), tap, 0).rgb));
            vec2 offset_pixels = vec2(pixel + ivec2(x, y)) + 0.5 - jitter_pixels - in_uv * frame.resolution;
            float tap_weight = exp(-2.29 * dot(offset_pixels, offset_pixels));
            filtered += c * tap_weight;
            float narrow_tap = exp(-2.29 * dot(offset_pixels, offset_pixels) / (span * span));
            narrow += c * narrow_tap;
            narrow_weight += narrow_tap;
            filtered_weight += tap_weight;
            mean += c;
            mean_squared += c * c;
            float depth = texelFetch(TEX(push.depth_texture, nearest), tap, 0).r;
            if (depth > closest_depth) {
                closest_depth = depth;
                closest_pixel = tap;
            }
        }
    }
    mean /= 9.0;
    vec3 deviation = sqrt(max(mean_squared / 9.0 - mean * mean, vec3(0.0)));

    vec2 motion = texelFetch(TEX(push.motion_texture, nearest), closest_pixel, 0).rg;
    vec2 history_uv = in_uv - motion;
    if (any(lessThan(history_uv, vec2(0.0))) || any(greaterThan(history_uv, vec2(1.0)))) {
        out_color = vec4(max(expand(fromYCoCg(filtered / filtered_weight)), vec3(0.0)), carried);
        return;
    }

    vec3 history = toYCoCg(compress(sampleHistory(frame, history_uv)));
    vec3 current_ycocg = filtered / filtered_weight;
    float confidence = 1.0;
    if (upscaling) {
        confidence = clamp(narrow_weight, 0.0, 1.0);
        current_ycocg = mix(current_ycocg, narrow / max(narrow_weight, 1e-6), confidence);
    }
    float speed = length(motion * frame.resolution);
    float gamma = mix(1.75, 1.0, clamp(speed * 0.5, 0.0, 1.0));
    vec3 box_min = mean - gamma * deviation;
    vec3 box_max = mean + gamma * deviation;
    vec3 box_center = 0.5 * (box_max + box_min);
    vec3 box_extent = 0.5 * (box_max - box_min) + 1e-5;
    vec3 offset = history - box_center;
    vec3 unit = abs(offset / box_extent);
    float max_unit = max(unit.x, max(unit.y, unit.z));
    if (max_unit > 1.0) history = mix(history, box_center + offset / max_unit, max(clamp(speed * 4.0, 0.0, 1.0), 0.1));

    float blend = mix(0.05, 0.2, clamp(speed / 24.0, 0.0, 1.0)) * max(confidence, 0.15);
    float flicker = abs(current_ycocg.x - history.x) / max(max(current_ycocg.x, history.x), 1e-3);
    blend *= 1.0 - 0.85 * flicker * (1.0 - clamp(speed, 0.0, 1.0));
    vec3 resolved = expand(fromYCoCg(mix(history, current_ycocg, blend)));
    if (!upscaling) resolved = mix(resolved, texelFetch(TEX(push.color_texture, nearest), pixel, 0).rgb, push.settled);
    out_color = vec4(max(resolved, vec3(0.0)), carried);
}
