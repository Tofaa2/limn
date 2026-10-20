#include "path_history.slang"
#include "common.slang"

#include "pathtrace_denoise.GatherPush.slang"

[[vk::push_constant]] GatherPush gather_push;

/// The share of this frame in light that needs no filtering while the
/// camera moves, and in what a mirror shows.
static const float moving_steady_weight = 1.0 / 3.0;
static const float moving_mirror_weight = 0.5;

/// A path traced picture gathered over frames, part by part.
struct GatherOutput {
    /// Light that needs no filtering, with the frames gathered in alpha.
    float4 color : SV_Target0;
    float4 guide : SV_Target1;
    /// Bounced light over the surface's color, with its squared brightness in alpha.
    float4 soft : SV_Target2;
    float4 facing : SV_Target3;
    float4 lamp : SV_Target4;
    /// Glossy reflections, with the frames gathered in alpha.
    float4 gloss_gathered : SV_Target5;
    float4 surface : SV_Target6;
};

/// Blends what the tracer found this frame into what was gathered before:
/// at the same pixel while nothing moves, otherwise where the surface was
/// last frame, if that pixel showed the same surface then.
[shader("fragment")]
GatherOutput gatherMain(float4 position : SV_Position) {
    FrameConstants frame = gather_push.frame;
    float2 fragment = position.xy;
    int2 pixel = int2(fragment);
    float4 traced = fetchTexel(gather_push.color, pixel);
    float3 light = traced.rgb;
    bool primary_mirror = traced.a > 0.5;
    float4 guide_now = fetchTexel(gather_push.guide, pixel);
    float3 shown = guide_now.rgb;
    float gloss_reach = guide_now.a;
    float3 grainy = fetchTexel(gather_push.soft, pixel).rgb;
    float4 facing_now = fetchTexel(gather_push.facing, pixel);
    bool first_mirrored = facing_now.a < 0.0;
    float first_distance = abs(facing_now.a);
    float3 lamp_now = fetchTexel(gather_push.lamp, pixel).rgb;
    float3 gloss_now = fetchTexel(gather_push.gloss, pixel).rgb;
    float4 surface_now = fetchTexel(gather_push.surface, pixel);

    float count = 0.0;
    float3 light_before = float3(0.0);
    float4 grainy_before = float4(0.0);
    float3 shown_before = float3(0.0);
    float4 facing_before = float4(0.0);
    float3 lamp_before = float3(0.0);
    if (gather_push.reset == 0u) {
        if (gather_push.moved == 0u) {
            float4 before = fetchTexel(gather_push.history_color, pixel);
            count = before.a;
            light_before = before.rgb;
            grainy_before = fetchTexel(gather_push.history_soft, pixel);
            shown_before = fetchTexel(gather_push.history_guide, pixel).rgb;
            facing_before = fetchTexel(gather_push.history_facing, pixel);
            lamp_before = fetchTexel(gather_push.history_lamp, pixel).rgb;
        } else {
            float2 center = (float2(pixel) + 0.5) * frame.inv_resolution;
            float3 toward = normalize(worldPositionFromDepth(center, 0.5, frame.inv_view_proj) - frame.camera_position);
            float3 spot = frame.camera_position + toward * first_distance;
            float2 was_at;
            if (seenLastFrame(frame, fragment, true, gather_push.depth, gather_push.motion, spot, first_distance, first_mirrored, was_at)) {
                uint linear_sampler = frame.sampler_linear_clamp;
                float4 guide_before = sampleTextureLod(gather_push.history_guide, linear_sampler, was_at, 0.0);
                float4 facing_seen = sampleTextureLod(gather_push.history_facing, linear_sampler, was_at, 0.0);
                float expected = distance(gather_push.previous_camera, spot);
                bool was_mirrored = facing_seen.a < 0.0;
                float3 unlike = abs(guide_before.rgb - shown);
                if (was_mirrored == first_mirrored && abs(abs(facing_seen.a) - expected) <= 0.03 * expected + 0.02 && max(unlike.r, max(unlike.g, unlike.b)) < 0.2) {
                    count = sampleTextureLod(gather_push.history_color, linear_sampler, was_at, 0.0).a;
                    light_before = historySharp(gather_push.history_color, linear_sampler, was_at, frame.resolution);
                    grainy_before = sampleTextureLod(gather_push.history_soft, linear_sampler, was_at, 0.0);
                    shown_before = guide_before.rgb;
                    facing_before = facing_seen;
                    lamp_before = sampleTextureLod(gather_push.history_lamp, linear_sampler, was_at, 0.0).rgb;
                }
            }
            count = min(count, dot(shown, float3(1.0)) > 0.0 && !first_mirrored ? gather_push.history_limit : 6.0);
        }
    }
    if (broken(light_before) || broken(grainy_before) || broken(shown_before) || broken(facing_before) || broken(lamp_before) || isnan(count) || isinf(count)) {
        count = 0.0;
        light_before = float3(0.0);
        lamp_before = float3(0.0);
        grainy_before = float4(0.0);
        shown_before = float3(0.0);
        facing_before = float4(0.0);
    }
    count = min(count, 8192.0);
    float weight = 1.0 / (count + 1.0);
    float steady_weight = gather_push.moved != 0u ? max(weight, primary_mirror ? moving_mirror_weight : moving_steady_weight) : weight;
    GatherOutput result;
    result.color = float4(lerp(light_before, light, steady_weight), count + 1.0);
    float brightness = min(luminance(grainy), 240.0);
    result.soft = lerp(grainy_before, float4(grainy, brightness * brightness), weight);
    float shown_weight = gather_push.moved != 0u ? max(weight, 0.7) : weight;
    result.facing = lerp(facing_before, facing_now, shown_weight);
    float4 surface_before = surface_now;
    if (gather_push.reset == 0u && gather_push.moved == 0u) surface_before = fetchTexel(gather_push.history_surface, pixel);
    if (broken(surface_before)) surface_before = surface_now;
    result.surface = lerp(surface_before, surface_now, weight);
    float4 gloss_before = float4(0.0);
    if (gather_push.reset == 0u && gather_push.moved == 0u) gloss_before = fetchTexel(gather_push.history_gloss, pixel);
    if (broken(gloss_before)) gloss_before = float4(0.0);
    result.gloss_gathered = float4(lerp(gloss_before.rgb, gloss_now, 1.0 / (gloss_before.a + 1.0)), min(gloss_before.a + 1.0, 8192.0));
    result.guide = float4(lerp(shown_before, shown, shown_weight), gloss_reach);
    result.lamp = float4(lerp(lamp_before, lamp_now, max(weight, 1.0 / gather_push.lamp_limit)), 1.0);
    return result;
}

#include "pathtrace_denoise.DenoisePush.slang"

[[vk::push_constant]] DenoisePush denoise_push;

static const float2 gathered_takes_over = float2(128.0, 1024.0);

static const uint mode_first = 0u;
static const uint mode_last = 1u;
static const uint mode_none = 2u;

bool mirroredAt(int2 pixel) {
    return fetchTexel(denoise_push.facing_texture, pixel).a < 0.0;
}

float3 positionAt(FrameConstants frame, int2 pixel, out float reach) {
    reach = abs(fetchTexel(denoise_push.facing_texture, pixel).a);
    float2 uv = (float2(pixel) + 0.5) * frame.inv_resolution;
    float3 through = worldPositionFromDepth(uv, 0.5, frame.inv_view_proj);
    float3 eye = eyePoint(frame, through);
    return eye + normalize(through - eye) * reach;
}

float3 facingAt(int2 pixel) {
    float3 facing = fetchTexel(denoise_push.facing_texture, pixel).rgb;
    float size = length(facing);
    return size > 1e-4 ? facing / size : float3(0.0, 1.0, 0.0);
}

float facingWeight(float3 facing, float3 other) {
    return pow(max(dot(facing, other), 0.0), 48.0);
}

float3 divisor(float3 guide) {
    return max(guide, float3(0.03));
}

float3 lightAt(int2 pixel) {
    return fetchTexel(denoise_push.color_texture, pixel).rgb;
}

float doubtAt(int2 pixel, float frames) {
    float4 texel = fetchTexel(denoise_push.color_texture, pixel);
    if (denoise_push.mode != mode_first) return texel.a;
    float average = luminance(texel.rgb);
    float spread = max(texel.a - average * average, 0.0);
    return sqrt(spread / frames) / (average + 1e-3);
}

[shader("fragment")]
float4 denoiseMain(float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = denoise_push.frame;
    int2 pixel = int2(fragment.xy);
    int2 last_pixel = int2(frame.resolution) - 1;
    float4 guide_texel = fetchTexel(denoise_push.guide_texture, pixel);
    float3 guide = guide_texel.rgb;
    float4 steady_texel = fetchTexel(denoise_push.steady_texture, pixel);
    float frames = max(steady_texel.a, 1.0);
    float3 grainy = fetchTexel(denoise_push.color_texture, pixel).rgb;
    float3 lamp = fetchTexel(denoise_push.lamp_texture, pixel).rgb;
    float3 gloss = float3(0.0);
    if (denoise_push.mode == mode_last || denoise_push.mode == mode_none) {
        float4 gathered = fetchTexel(denoise_push.gloss_gathered_texture, pixel);
        float3 denoised = fetchTexel(denoise_push.gloss_texture, pixel).rgb;
        gloss = denoise_push.mode == mode_none ? gathered.rgb : lerp(denoised, gathered.rgb, smoothstep(gathered_takes_over.x, gathered_takes_over.y, gathered.a));
    }
    bool colored = dot(guide, float3(1.0)) > 0.0;
    if (denoise_push.mode == mode_none) return float4(steady_texel.rgb + (grainy + lamp) * (colored ? divisor(guide) : float3(1.0)) + gloss, 1.0);
    float reach;
    float3 position = positionAt(frame, pixel, reach);
    if (!colored || reach <= 0.0) {
        return denoise_push.mode == mode_last ? float4(steady_texel.rgb + (grainy + lamp) * (colored ? divisor(guide) : float3(1.0)) + gloss, 1.0) : float4(grainy, 0.0);
    }
    float reach_a;
    float reach_b;
    float3 left = positionAt(frame, clamp(pixel - int2(1, 0), int2(0), last_pixel), reach_a);
    float3 right = positionAt(frame, clamp(pixel + int2(1, 0), int2(0), last_pixel), reach_b);
    float3 along_x = abs(reach_a - reach) < abs(reach_b - reach) ? position - left : right - position;
    float3 up = positionAt(frame, clamp(pixel - int2(0, 1), int2(0), last_pixel), reach_a);
    float3 down = positionAt(frame, clamp(pixel + int2(0, 1), int2(0), last_pixel), reach_b);
    float3 along_y = abs(reach_a - reach) < abs(reach_b - reach) ? position - up : down - position;
    float3 normal = normalize(cross(along_x, along_y));
    bool mirrored = mirroredAt(pixel);
    float3 facing = facingAt(pixel);

    float3 own = lightAt(pixel);
    float3 traced = own;
    float3 around = float3(0.0);
    float around_squared = 0.0;
    float around_count = 0.0;
    float brightest_around = 0.0;
    float doubt = doubtAt(pixel, frames);
    float doubt_count = 1.0;
    for (int index = 0; index < 8; index++) {
        int2 offset = int2(index < 3 ? index - 1 : (index < 5 ? (index == 3 ? -1 : 1) : index - 6), index < 3 ? -1 : (index < 5 ? 0 : 1));
        int2 tap = clamp(pixel + offset * denoise_push.step_size, int2(0), last_pixel);
        float4 tap_guide = fetchTexel(denoise_push.guide_texture, tap);
        if (dot(tap_guide.rgb, float3(1.0)) <= 0.0 || mirroredAt(tap) != mirrored) continue;
        if (facingWeight(facing, facingAt(tap)) < 0.5) continue;
        float3 tap_light = lightAt(tap);
        float tap_brightness = luminance(tap_light);
        around += tap_light;
        around_squared += tap_brightness * tap_brightness;
        around_count += 1.0;
        brightest_around = max(brightest_around, tap_brightness);
        doubt += doubtAt(tap, max(fetchTexel(denoise_push.steady_texture, tap).a, 1.0));
        doubt_count += 1.0;
    }
    doubt /= doubt_count;
    float own_brightness = luminance(own);
    float around_brightness = around_count > 0.0 ? luminance(around) / around_count : own_brightness;
    if (denoise_push.mode == mode_first) {
        float most = brightest_around * (1.0 + frames / 256.0);
        if (around_count > 0.0 && own_brightness > most) {
            own *= most / own_brightness;
            own_brightness = most;
        }
        float around_spread = around_count > 1.0 ? sqrt(max(around_squared / around_count - around_brightness * around_brightness, 0.0)) : 0.0;
        float by_neighbours = around_spread / (around_brightness + 1e-3);
        doubt = lerp(by_neighbours, doubt, clamp((frames - 1.0) / 6.0, 0.0, 1.0));
        doubt = min(doubt, 4.0);
    }
    float reference = lerp(own_brightness, around_brightness, clamp(doubt * 2.0, 0.0, 1.0));
    float remaining = doubt / sqrt(float(denoise_push.step_size));
    float allowed = 4.0 * remaining * (reference + 0.02) + 1e-4;

    float3 total = float3(0.0);
    float weight_total = 0.0;
    const float kernel[3] = { 0.375, 0.25, 0.0625 };
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            int2 tap = pixel + int2(x, y) * denoise_push.step_size;
            if (any(tap < int2(0)) || any(tap > last_pixel)) continue;
            float4 tap_guide = fetchTexel(denoise_push.guide_texture, tap);
            if (dot(tap_guide.rgb, float3(1.0)) <= 0.0 || mirroredAt(tap) != mirrored) continue;
            float tap_reach;
            float3 tap_position = positionAt(frame, tap, tap_reach);
            if (tap_reach <= 0.0) continue;
            float3 light = all(tap == pixel) ? own : lightAt(tap);
            float off_plane = abs(dot(normal, tap_position - position));
            float weight = kernel[abs(x)] * kernel[abs(y)];
            weight *= exp(-off_plane / (0.01 * reach + 1e-4));
            weight *= facingWeight(facing, facingAt(tap));
            weight *= exp(-abs(luminance(light) - reference) / allowed);
            if (mirrored) weight *= exp(-abs(tap_reach - reach) / (0.05 * reach + 0.02));
            total += light * weight;
            weight_total += weight;
        }
    }
    float3 smoothed = weight_total > 1e-6 ? total / weight_total : own;
    smoothed = lerp(smoothed, traced, clamp(frames / 4096.0, 0.0, 1.0));
    if (any(isnan(smoothed)) || any(isinf(smoothed))) smoothed = any(isnan(traced)) || any(isinf(traced)) ? float3(0.0) : traced;
    return denoise_push.mode == mode_last ? float4(steady_texel.rgb + (smoothed + lamp) * divisor(guide) + gloss, 1.0) : float4(smoothed, doubt);
}

#include "pathtrace_denoise.NrdPackPush.slang"

[[vk::push_constant]] NrdPackPush nrd_pack_push;

/// View depth given to what the rays missed, beyond any the denoiser treats
/// as a surface.
static const float nrd_sky_depth = -1e6;

/// The tracer's signals as NRD reads them.
struct NrdPackOutput {
    /// World normal of the first surface, and its roughness.
    float4 normal_roughness : SV_Target0;
    /// Where it is along the view's Z axis.
    float view_depth : SV_Target1;
    /// Bounced light over the surface's color, and how far the bounce went.
    float4 diffuse : SV_Target2;
    /// Reflected light, and how far the reflection reached.
    float4 specular : SV_Target3;
};

[shader("fragment")]
NrdPackOutput nrdPackMain(float4 position : SV_Position) {
    FrameConstants frame = nrd_pack_push.frame;
    int2 pixel = int2(position.xy);
    float4 surface = fetchTexel(nrd_pack_push.surface, pixel);
    float3 folded = float3(surface.xy, 1.0 - abs(surface.x) - abs(surface.y));
    float fold = max(-folded.z, 0.0);
    folded.x += folded.x >= 0.0 ? -fold : fold;
    folded.y += folded.y >= 0.0 ? -fold : fold;
    float3 normal = normalize(folded);

    NrdPackOutput result;
    result.normal_roughness = float4(normal / max(abs(normal.x), max(abs(normal.y), abs(normal.z))), surface.z);
    float depth = fetchTexel(nrd_pack_push.depth, pixel).r;
    float3 world = worldPositionFromDepth(position.xy * frame.inv_resolution, depth, frame.inv_view_proj);
    result.view_depth = depth > 0.0 ? mul(frame.view, float4(world, 1.0)).z : nrd_sky_depth;
    float4 bounced = fetchTexel(nrd_pack_push.diffuse, pixel);
    result.diffuse = float4(clamp(bounced.rgb, 0.0, 60000.0), clamp(bounced.a, 0.0, 60000.0));
    float reach = fetchTexel(nrd_pack_push.albedo, pixel).a;
    result.specular = float4(clamp(fetchTexel(nrd_pack_push.specular, pixel).rgb, 0.0, 60000.0), clamp(reach, 0.0, 60000.0));
    return result;
}

#include "pathtrace_denoise.NrdComposePush.slang"

[[vk::push_constant]] NrdComposePush nrd_compose_push;

/// View depth beyond which a pixel shows no surface; see `nrd_sky_depth`.
static const float nrd_sky_threshold = -5e5;

/// Puts a path traced picture together from the light that needs no
/// filtering and what NRD made of the bounced light and the reflections.
/// NRD leaves pixels that show no surface as they were, so those take
/// nothing from it.
[shader("fragment")]
float4 nrdComposeMain(float4 fragment : SV_Position) : SV_Target {
    int2 pixel = int2(fragment.xy);
    float3 steady = fetchTexel(nrd_compose_push.steady_texture, pixel).rgb;
    if (fetchTexel(nrd_compose_push.depth_texture, pixel).r < nrd_sky_threshold) return float4(steady, 1.0);
    float3 albedo = fetchTexel(nrd_compose_push.albedo_texture, pixel).rgb;
    float3 tint = dot(albedo, float3(1.0)) > 0.0 ? max(albedo, float3(0.03)) : float3(1.0);
    float3 lamp = fetchTexel(nrd_compose_push.lamp_texture, pixel).rgb;
    float3 diffuse = fetchTexel(nrd_compose_push.diffuse_texture, pixel).rgb;
    float3 specular = fetchTexel(nrd_compose_push.specular_texture, pixel).rgb;
    return float4(steady + (diffuse + lamp) * tint + specular, 1.0);
}
