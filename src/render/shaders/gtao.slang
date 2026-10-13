#include "common.slang"

struct Push {
    FrameConstants frame;
    uint depth_texture;
    uint color_texture;
    float radius;
    float intensity;
    int slice_count;
    int step_count;
};

[[vk::push_constant]] Push push;

struct Output {
    float2 ao : SV_Target0;
    float4 bounce : SV_Target1;
};

static const float sky_depth = 50000.0;

float3 viewPosition(FrameConstants frame, float2 uv, float mip) {
    float z = sampleTextureLod(push.depth_texture, frame.sampler_nearest_clamp, uv, mip).r;
    float2 ndc = uv * 2.0 - 1.0;
    if (frame.parallel != 0.0) {
        ndc -= float2(frame.proj[0][3], frame.proj[1][3]);
        return float3(ndc.x / frame.proj[0][0], ndc.y / frame.proj[1][1], -z);
    }
    ndc += float2(frame.proj[0][2], frame.proj[1][2]);
    return float3(ndc.x / frame.proj[0][0], ndc.y / frame.proj[1][1], -1.0) * z;
}

[shader("fragment")]
Output fragmentMain([[vk::location(0)]] float2 in_uv, float4 pixel : SV_Position) {
    FrameConstants frame = push.frame;
    Output result;
    float3 position = viewPosition(frame, in_uv, 0.0);
    if (-position.z > sky_depth) {
        result.ao = float2(1.0, -position.z);
        result.bounce = float4(0.0);
        return result;
    }
    float2 depth_size = textureSize(push.depth_texture);
    float2 texel = 1.0 / depth_size;
    float3 left = viewPosition(frame, in_uv - float2(texel.x, 0.0), 0.0);
    float3 right = viewPosition(frame, in_uv + float2(texel.x, 0.0), 0.0);
    float3 up = viewPosition(frame, in_uv - float2(0.0, texel.y), 0.0);
    float3 down = viewPosition(frame, in_uv + float2(0.0, texel.y), 0.0);
    float3 dx = abs(left.z - position.z) < abs(right.z - position.z) ? position - left : right - position;
    float3 dy = abs(up.z - position.z) < abs(down.z - position.z) ? position - up : down - position;
    float3 normal = normalize(cross(dx, dy));
    bool parallel = frame.parallel != 0.0;
    float3 toward = parallel ? float3(0.0, 0.0, 1.0) : -position;
    if (dot(normal, toward) < 0.0) normal = -normal;
    float3 view = normalize(toward);

    float projected = push.radius * 0.5 * abs(frame.proj[1][1]) / (parallel ? 1.0 : -position.z);
    float2 radius_uv = float2(projected * frame.resolution.y / frame.resolution.x, projected);
    radius_uv = min(radius_uv, float2(0.15));
    float pixel_radius = radius_uv.y * depth_size.y;
    if (pixel_radius < 1.5) {
        result.ao = float2(1.0, -position.z);
        result.bounce = float4(0.0);
        return result;
    }

    float noise_direction = interleavedGradientNoise(pixel.xy, frame.frame_index);
    float noise_offset = frac(noise_direction * 7.31 + 0.37);
    float falloff_end = push.radius * push.radius;
    float visibility = 0.0;
    float3 bounce = float3(0.0);
    bool gather = push.color_texture != INVALID_ID;
    float ceiling = gather ? (luminance(sampleTextureLod(push.color_texture, frame.sampler_linear_clamp, in_uv, 0.0).rgb) + 0.05) * 6.0 : 0.0;

    for (int slice = 0; slice < push.slice_count; slice++) {
        float phi = (float(slice) + noise_direction) * PI / float(push.slice_count);
        float2 omega = float2(cos(phi), sin(phi));
        float3 direction = float3(omega.x, -omega.y, 0.0);
        float3 ortho_direction = direction - dot(direction, view) * view;
        float3 axis = normalize(cross(direction, view));
        float3 projected_normal = normal - axis * dot(normal, axis);
        float projected_length = length(projected_normal);
        float sign_n = sign(dot(ortho_direction, projected_normal));
        float cos_n = clamp(dot(projected_normal, view) / max(projected_length, 1e-5), 0.0, 1.0);
        float n = sign_n * acos(cos_n);

        float horizon_cos[2] = { -1.0, -1.0 };
        for (int side = 0; side < 2; side++) {
            float direction_sign = side == 0 ? 1.0 : -1.0;
            for (int tap_index = 0; tap_index < push.step_count; tap_index++) {
                float t = (float(tap_index) + noise_offset) / float(push.step_count);
                float reach = t * t + 0.5 / pixel_radius;
                float2 sample_uv = in_uv + direction_sign * omega * radius_uv * reach;
                float mip = clamp(log2(reach * pixel_radius) - 2.5, 0.0, 4.0);
                float3 delta = viewPosition(frame, sample_uv, floor(mip)) - position;
                float distance_squared = dot(delta, delta);
                float cos_horizon = dot(delta, view) * rsqrt(max(distance_squared, 1e-8));
                float falloff = clamp(distance_squared / falloff_end * 2.0 - 1.0, 0.0, 1.0);
                float candidate = lerp(cos_horizon, -1.0, falloff);
                if (candidate > horizon_cos[side]) {
                    if (gather) {
                        float facing = max(dot(normal, delta) * rsqrt(max(distance_squared, 1e-8)), 0.0);
                        float slice_width = candidate - max(horizon_cos[side], -0.2);
                        if (slice_width > 0.0) {
                            float3 seen = sampleTextureLod(push.color_texture, frame.sampler_linear_clamp, sample_uv, 0.0).rgb;
                            bounce += seen * min(1.0, ceiling / max(luminance(seen), 1e-6)) * (facing * slice_width);
                        }
                    }
                    horizon_cos[side] = candidate;
                }
            }
        }
        float h0 = n + clamp(-acos(horizon_cos[1]) - n, -PI * 0.5, PI * 0.5);
        float h1 = n + clamp(acos(horizon_cos[0]) - n, -PI * 0.5, PI * 0.5);
        float arc0 = (cos_n + 2.0 * h0 * sin(n) - cos(2.0 * h0 - n)) * 0.25;
        float arc1 = (cos_n + 2.0 * h1 * sin(n) - cos(2.0 * h1 - n)) * 0.25;
        visibility += projected_length * (arc0 + arc1);
    }
    visibility /= float(push.slice_count);
    result.ao = float2(pow(clamp(visibility, 0.0, 1.0), push.intensity), -position.z);
    result.bounce = float4(min(bounce / float(push.slice_count * 2), float3(64.0)), 1.0);
    return result;
}
