#include "gi.slang"
#include "media.slang"
#include "common.slang"

#include "fog.FogPush.slang"

[[vk::push_constant]] FogPush fog_push;

/// Light of the clustered local lights scattered toward the eye at
/// `position`, unshadowed; `pixel` is in full-resolution pixels.
float3 fogLocalLights(FrameConstants frame, float3 position, float3 direction, float2 pixel) {
    float view_depth = -(mul(frame.view, float4(position, 1.0))).z;
    uint2 tile = min(uint2(pixel * frame.inv_resolution * float2(CLUSTERS_X, CLUSTERS_Y)), uint2(CLUSTERS_X - 1u, CLUSTERS_Y - 1u));
    float slice = log2(max(view_depth, 1e-4)) * frame.lights.cluster_z_scale + frame.lights.cluster_z_bias;
    uint cluster = tile.x + tile.y * CLUSTERS_X + uint(clamp(slice, 0.0, float(CLUSTERS_Z - 1u))) * CLUSTERS_X * CLUSTERS_Y;
    uint count = frame.lights.clusters.data[cluster].count;
    uint listed = frame.lights.clusters.data[cluster].offset;
    float3 total = float3(0.0);
    for (uint i = 0u; i < count; i++) {
        Light light = frame.lights.lights.data[frame.lights.light_indices[listed + i]];
        if ((light.flags & LIGHT_DIRECTIONAL) != 0u) continue;
        float3 to_light = light.position - position;
        float distance_squared = dot(to_light, to_light);
        float range_squared = light.range * light.range;
        if (distance_squared > range_squared) continue;
        float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
        float3 l = to_light * rsqrt(max(distance_squared, 1e-8));
        float attenuation = window * window / max(distance_squared, max(light.source_radius * light.source_radius, 1e-2));
        if ((light.flags & LIGHT_SPOT) != 0u) {
            float cone = clamp(dot(-l, light.direction) * light.cone_scale + light.cone_offset, 0.0, 1.0);
            attenuation *= cone * cone;
        }
        if ((light.flags & LIGHT_RECTANGLE) != 0u) attenuation *= clamp(dot(-l, light.direction), 0.0, 1.0);
        total += light.color * (attenuation * henyeyGreenstein(dot(direction, l), fog_push.anisotropy));
    }
    return total;
}

[shader("fragment")]
float4 fogMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = fog_push.frame;
    float depth = sampleTextureLod(fog_push.depth_texture, frame.sampler_nearest_clamp, in_uv, 0.0).r;
    float3 end = worldPositionFromDepth(in_uv, max(depth, 1e-6), frame.inv_view_proj);
    float3 ray = end - eyePoint(frame, end);
    float ray_length = length(ray);
    float3 direction = ray / ray_length;
    ray_length = min(ray_length, fog_push.max_distance);

    float3 sky_ambient = float3(0.0);
    if (frame.environment != 0u) {
        uint s = frame.sampler_linear_clamp;
        sky_ambient = 0.5 * (sampleCubeLod(frame.env_irradiance, s, float3(0.0, 1.0, 0.0), 0.0).rgb +
            sampleCubeLod(frame.env_irradiance, s, float3(0.0, -1.0, 0.0), 0.0).rgb) * frame.env_intensity * fog_push.ambient;
    }
    float3 sun = frame.sun_radiance * henyeyGreenstein(dot(direction, frame.sun_direction), fog_push.anisotropy);

    float step_length = ray_length / float(fog_push.step_count);
    float jitter = interleavedGradientNoise(fragment.xy, frame.frame_index);
    float3 scattered = float3(0.0);
    float transmittance = 1.0;
    int ambient_interval = max(fog_push.step_count / 2, 1);
    float3 ambient = sky_ambient;
    for (int i = 0; i < fog_push.step_count; i++) {
        float3 position = end - ray + direction * (float(i) + jitter) * step_length;
        float sigma = fog_push.density * exp(-max(position.y, 0.0) * fog_push.height_falloff);
        if (i % ambient_interval == 0) {
            ambient = sky_ambient;
            if (frame.gi.enabled != 0u) {
                float coverage = giCoverage(frame, position);
                if (coverage > 0.0) ambient = lerp(sky_ambient, giAmbient(frame, position) * frame.gi.gi_intensity * fog_push.ambient, coverage);
            }
        }
        float3 light = sun * sunVisibility(frame, position) + ambient;
        if (fog_push.local_lights != 0u && frame.lights.light_count != 0u) light += fogLocalLights(frame, position, direction, in_uv * frame.resolution);
        float step_transmittance = exp(-sigma * step_length);
        scattered += transmittance * light * (1.0 - step_transmittance);
        transmittance *= step_transmittance;
    }
    return float4(scattered, transmittance);
}

#include "fog.CompositePush.slang"

[[vk::push_constant]] CompositePush composite_push;

[shader("fragment")]
float4 compositeMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = composite_push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    float center = linearDepth(fetchTexel(composite_push.depth_texture, int2(fragment.xy)).r, frame.depth_terms);
    int2 fog_size = int2(textureSize(composite_push.fog_texture));
    float2 position = in_uv * float2(fog_size) - 0.5;
    int2 base = int2(floor(position));
    float2 f = position - float2(base);
    float4 total = float4(0.0);
    float weight_total = 0.0;
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 2; x++) {
            int2 tap = clamp(base + int2(x, y), int2(0), fog_size - 1);
            float2 tap_uv = (float2(tap) + 0.5) / float2(fog_size);
            float depth = linearDepth(sampleTextureLod(composite_push.depth_texture, nearest, tap_uv, 0.0).r, frame.depth_terms);
            float bilinear = (x == 0 ? 1.0 - f.x : f.x) * (y == 0 ? 1.0 - f.y : f.y);
            float weight = bilinear / (1e-3 + abs(depth - center) / max(center, 1e-3) * 20.0);
            total += fetchTexel(composite_push.fog_texture, tap) * weight;
            weight_total += weight;
        }
    }
    float4 fog = total / max(weight_total, 1e-6);
    return float4(fog.rgb, 1.0 - fog.a);
}
